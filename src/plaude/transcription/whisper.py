"""Whisper transcription wrapper — local model, JSON output with timestamps."""

import json
import os
import re
import urllib.request
import wave

DEFAULT_CHUNK_SECONDS = 540

_LOOP_RE = re.compile(
    r"((?:\b[\w']+\b[ ,.]*){1,4}?)(?:\1){12,}", re.IGNORECASE)
_RETRY_LADDER = (0.2, 0.4, 0.6, 0.8)
_LOOP_REPETITION_PENALTY = 1.1

def loop_chars(text: str) -> int:
    """Characters sitting inside a repetition loop (same phrase repeated >=13x)."""
    return sum(len(m.group(0)) for m in _LOOP_RE.finditer(text or ""))

def loop_ratio(text: str) -> float:
    """Fraction of the transcript trapped in repetition loops (0.0 to 1.0)."""
    t = text or ""
    return loop_chars(t) / len(t) if t else 0.0

def _iter_wav_chunks(wav_path: str, chunk_seconds: int):
    """Yield (index, start_seconds, duration_seconds, wav_bytes) per piece.

    Chunks are emitted as complete, self-contained WAV files (header + PCM) so
    each can be POSTed on its own.
    """
    with wave.open(wav_path, "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames_per_chunk = max(1, rate * chunk_seconds)
        total = w.getnframes()
        index = 0
        start = 0
        while start < total:
            w.setpos(start)
            n = min(frames_per_chunk, total - start)
            data = w.readframes(n)
            if not data:
                break
            yield (index, start / rate, n / rate,
                   _wrap_pcm_as_wav(data, channels, width, rate))
            index += 1
            start += frames_per_chunk

def _wrap_pcm_as_wav(pcm: bytes, channels: int, width: int, rate: int) -> bytes:
    """Wrap raw PCM bytes in a WAV header."""
    import io

    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(width)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()

def _post_audio(url: str, key: str, model: str, wav_bytes: bytes,
                timeout: int = 300, extra: dict | None = None) -> dict:
    """POST one WAV to an OpenAI-compatible /audio/transcriptions endpoint.

    `extra` adds form fields the endpoint accepts (temperature,
    repetition_penalty, prompt, ...). vLLM honours these on the transcription
    route; OpenAI's condition_on_previous_text is NOT available there.
    """
    boundary = "----plaude"
    body = bytearray()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\""
             f"\r\n\r\n{model}\r\n").encode()
    for k, v in (extra or {}).items():
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\""
                 f"\r\n\r\n{v}\r\n").encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
             f"filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n").encode()
    body += wav_bytes
    body += f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(url, data=bytes(body), headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)

def _transcribe_chunk(url: str, key: str, model: str, wav_bytes: bytes,
                      verbose: bool = False) -> dict:
    """Transcribe one WAV, retrying up the temperature ladder on a loop.

    Greedy (temperature 0.0) is the best output when it behaves, so it is tried
    first. Whisper's degenerate loops are a decoding pathology, not a model
    limit: raising temperature and penalising repetition reliably breaks them
    (measured 25% -> 0% on a real chunk). If every rung still loops, the result
    with the least looping text wins rather than failing the whole recording.
    """
    result = _post_audio(url, key, model, wav_bytes)
    text = (result.get("text") or "").strip()
    if loop_ratio(text) == 0.0:
        return result

    best = result
    best_ratio = loop_ratio(text)
    for temp in _RETRY_LADDER:
        if verbose:
            print(f"    [retry] loop {best_ratio*100:.1f}% -> temp {temp} "
                  f"+ repetition_penalty {_LOOP_REPETITION_PENALTY}")
        cand = _post_audio(url, key, model, wav_bytes, extra={
            "temperature": temp,
            "repetition_penalty": _LOOP_REPETITION_PENALTY,
        })
        ratio = loop_ratio((cand.get("text") or "").strip())
        if ratio < best_ratio:
            best, best_ratio = cand, ratio
        if ratio == 0.0:
            return cand
    return best

def transcribe_via_openai(wav_path: str, model: str = "whisper-1",
                          api_key: str | None = None,
                          chunk_seconds: int = DEFAULT_CHUNK_SECONDS,
                          verbose: bool = False) -> dict:
    """Transcribe a WAV via any OpenAI-compatible /v1/audio/transcriptions endpoint.

    Uses OPENAI_API_KEY and OPENAI_BASE_URL from the environment (standard
    OpenAI-style config) so no internal endpoint or key is hardcoded. Falls
    back to api.openai.com if OPENAI_BASE_URL is unset.

    Audio longer than `chunk_seconds` is split, transcribed piecewise, and the
    texts are concatenated with segment offsets rebased onto the original
    timeline. Endpoints that enforce a maximum audio duration (vLLM defaults to
    600s) would otherwise reject a long recording outright.

    Returns the same shape as transcribe_with_model: {text, segments, ...}.
    """
    key = api_key or os.environ.get("OPENAI_API_KEY")
    base = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")
    if not key:
        raise RuntimeError("No OPENAI_API_KEY in environment for transcription")

    url = f"{base.rstrip('/')}/audio/transcriptions"
    duration = _get_wav_duration(wav_path)

    if duration and duration <= chunk_seconds:
        with open(wav_path, "rb") as f:
            data = _transcribe_chunk(url, key, model, f.read(), verbose=verbose)
        text = (data.get("text") or "").strip()
        return {
            "duration_seconds": round(duration, 1),
            "model": model,
            "language": data.get("language") or "unknown",
            "segments": [{"start": 0.0, "end": round(duration, 2),
                          "text": text}],
            "text": text,
        }

    texts: list[str] = []
    segments: list[dict] = []
    chunk_index = -1
    for chunk_index, start, chunk_dur, wav_bytes in _iter_wav_chunks(
            wav_path, chunk_seconds):
        data = _transcribe_chunk(url, key, model, wav_bytes, verbose=verbose)
        piece = (data.get("text") or "").strip()
        if piece:
            texts.append(piece)
        if data.get("segments"):
            for seg in data["segments"]:
                segments.append({
                    "start": round(start + float(seg.get("start", 0.0)), 2),
                    "end": round(start + float(seg.get("end", 0.0)), 2),
                    "text": (seg.get("text") or "").strip(),
                })
        elif piece:
            segments.append({
                "start": round(start, 2),
                "end": round(start + chunk_dur, 2),
                "text": piece,
            })

    return {
        "duration_seconds": round(duration, 1) if duration else 0.0,
        "model": model,
        "language": "unknown",
        "segments": segments,
        "chunks": chunk_index + 1,
        "text": " ".join(texts),
    }

def _get_wav_duration(path: str) -> float | None:
    """Duration of a WAV file in seconds, or None if unreadable."""
    try:
        with wave.open(path, "rb") as w:
            rate = w.getframerate()
            return w.getnframes() / rate if rate else None
    except Exception:
        return None

def transcribe_with_model(
    model,
    wav_path: str,
    model_name: str = "medium",
    language: str | None = "en",
) -> dict:
    """Transcribe a WAV file using a pre-loaded Whisper model.

    Returns a dict with file metadata, full text, and timestamped segments.
    Duration is derived from the audio file when possible, falling back to
    Whisper's last segment end time.
    """
    options = {}
    if language:
        options["language"] = language

    result = model.transcribe(wav_path, **options)

    segments = [
        {"start": round(s["start"], 2), "end": round(s["end"], 2), "text": s["text"].strip()}
        for s in result.get("segments", [])
    ]

    # Prefer actual audio duration from file header; fall back to segment end
    duration = _get_wav_duration(wav_path)
    if duration is None:
        duration = segments[-1]["end"] if segments else 0.0

    return {
        "duration_seconds": round(duration, 1),
        "model": model_name,
        "language": result.get("language", language or "unknown"),
        "segments": segments,
        "text": result.get("text", "").strip(),
    }

def load_model(model_name: str = "medium"):
    """Load a Whisper model. Call once and reuse across transcriptions.

    Whisper is imported lazily so the module stays importable (and patchable)
    without the heavy torch/whisper stack being present.
    """
    try:
        import whisper
    except ImportError as e:  # pragma: no cover - depends on optional dep
        raise RuntimeError(
            "openai-whisper is not installed. Install it or set "
            "transcription.api_key to use an OpenAI-compatible endpoint."
        ) from e
    return whisper.load_model(model_name)
