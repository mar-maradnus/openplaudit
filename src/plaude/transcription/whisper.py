"""Whisper transcription wrapper — local model, JSON output with timestamps."""

import wave

def load_model(model_name: str = "medium"):
    """Load a Whisper model. Call once and reuse across transcriptions.

    Whisper is imported lazily so the module stays importable (and patchable)
    without the heavy torch/whisper stack being present.
    """
    import whisper
    return whisper.load_model(model_name)


def _get_wav_duration(wav_path: str) -> float | None:
    """Read actual audio duration from a WAV file header. Returns None for non-WAV."""
    try:
        with wave.open(wav_path, "rb") as wf:
            return wf.getnframes() / wf.getframerate()
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
