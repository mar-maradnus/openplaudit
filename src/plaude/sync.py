"""Sync orchestrator — download, decode, transcribe, cleanup.

State transitions per session:
  (new) -> downloaded_at -> decoded_at -> transcribed_at

Each phase is marked only after it succeeds. A failure at any phase
records failed_at + failure_reason, and the session is retried on the
next sync run from the last successful phase.

State truth model (dual-source):
  Phase completion is recorded in state.json (downloaded_at, decoded_at,
  transcribed_at). This is the primary authority — is_complete() consults
  only JSON state, never the filesystem.

  However, the *resume* path uses filesystem presence as a secondary signal:
    - If WAV exists but decoded_at is missing, we trust the file and mark decoded.
    - If raw .opus and WAV are both missing after download, we re-download.
  This means state can be inferred from the filesystem when JSON and disk
  diverge (e.g. after a crash between save_wav and save_state). The
  filesystem is a recovery heuristic, not a source of truth for completion.
"""

import datetime
import json
from pathlib import Path

from .config import get_output_dirs
from .notify import notify
from .state import (
    load_state, save_state,
    mark_downloaded, mark_decoded, mark_transcribed, mark_failed,
    is_complete, needs_download,
)


def _session_filename(session_id: int) -> str:
    """Convert session_id (unix timestamp) to a timezone-stable filename stem."""
    ts = datetime.datetime.fromtimestamp(session_id, tz=datetime.timezone.utc)
    return ts.strftime("%Y%m%d_%H%M%S_UTC")


def _format_local_time(session_id: int) -> str:
    """Format session_id as local time for display only."""
    return datetime.datetime.fromtimestamp(session_id).strftime("%Y-%m-%d %H:%M:%S")


async def run_sync(cfg: dict, verbose: bool = False, quiet: bool = False) -> int:
    """Full sync pipeline. Returns count of newly completed recordings."""
    from .audio.decoder import decode_opus_raw, save_wav
    from .ble.client import PlaudClient
    from .ble.transfer import download_file, DownloadError

    address = cfg["device"]["address"]
    token = cfg["device"]["token"]
    if not address or not token:
        raise ValueError("Device address and token must be configured. Run: plaude config init")

    dirs = get_output_dirs(cfg)
    for d in dirs.values():
        d.mkdir(parents=True, exist_ok=True)

    state = load_state()
    client = PlaudClient(address, token, verbose=verbose)
    completed_count = 0
    whisper_model = None

    try:
        if not quiet:
            print("Connecting to PLAUD device...")
        await client.connect()

        if not await client.handshake():
            raise ConnectionError("Handshake failed — check token or ensure device is not recording")
        await client.time_sync()

        sessions = await client.get_sessions()
        if not sessions:
            if not quiet:
                print("No recordings on device.")
            return 0

        # Filter to sessions that are not fully complete
        pending = [s for s in sessions if not is_complete(state, s["session_id"])]
        if not pending:
            if not quiet:
                print(f"All {len(sessions)} recording(s) already synced.")
            return 0

        if not quiet:
            print(f"{len(pending)} recording(s) to process (of {len(sessions)} total).")

        for s in pending:
            sid = s["session_id"]
            fname = _session_filename(sid)
            display_time = _format_local_time(sid)

            try:
                # Phase 1: Download
                raw_path = dirs["raw"] / f"{fname}.opus" if cfg["sync"]["keep_raw"] else None
                wav_path = dirs["audio"] / f"{fname}.wav"

                if needs_download(state, sid):
                    if not quiet:
                        print(f"\nDownloading {display_time} ({s['file_size'] / 1024:.1f} KB)...")

                    raw_data = await download_file(client, sid, s["file_size"], verbose=verbose)

                    if raw_path:
                        raw_path.write_bytes(raw_data)

                    mark_downloaded(state, sid)
                    save_state(state)
                else:
                    # Already downloaded — reload raw data for decode
                    if raw_path and raw_path.exists():
                        raw_data = raw_path.read_bytes()
                    elif wav_path.exists():
                        # Already decoded, skip to transcription
                        raw_data = None
                    else:
                        # Raw data lost and no WAV — re-download
                        if not quiet:
                            print(f"\nRe-downloading {display_time} (raw data not retained)...")
                        raw_data = await download_file(client, sid, s["file_size"], verbose=verbose)
                        mark_downloaded(state, sid)
                        save_state(state)

                # Phase 2: Decode
                if not wav_path.exists() and raw_data is not None:
                    if not quiet:
                        print(f"  Decoding Opus...")
                    pcm = decode_opus_raw(raw_data)
                    save_wav(pcm, str(wav_path))
                    duration = len(pcm) / (16000 * 2)
                    if not quiet:
                        print(f"  Audio: {wav_path.name} ({duration:.1f}s)")

                if wav_path.exists():
                    mark_decoded(state, sid)
                    save_state(state)
                else:
                    raise RuntimeError(f"WAV file not produced: {wav_path}")

                # Phase 3: Transcribe
                if not quiet:
                    print(f"  Transcribing with Whisper ({cfg['transcription']['model']})...")

                if whisper_model is None:
                    from .transcription.whisper import load_model
                    whisper_model = load_model(cfg["transcription"]["model"])

                from .transcription.whisper import transcribe_with_model
                result = transcribe_with_model(
                    whisper_model,
                    str(wav_path),
                    model_name=cfg["transcription"]["model"],
                    language=cfg["transcription"]["language"] or None,
                )
                result["file"] = fname

                transcript_path = dirs["transcripts"] / f"{fname}.json"
                transcript_path.write_text(json.dumps(result, indent=2, ensure_ascii=False))

                mark_transcribed(state, sid)
                save_state(state)

                if not quiet:
                    preview = result["text"][:100]
                    print(f"  Transcript: {transcript_path.name}")
                    print(f"  Preview: {preview}...")

                if cfg["notifications"]["enabled"]:
                    duration = result["duration_seconds"]
                    msg = result["text"][:100] if cfg["notifications"]["show_preview"] else f"{duration:.0f}s recording"
                    notify("Plaude Sync", msg, subtitle=display_time)

                # Cleanup
                if cfg["sync"]["auto_delete_local_audio"]:
                    wav_path.unlink(missing_ok=True)

                completed_count += 1

            except DownloadError as e:
                mark_failed(state, sid, str(e))
                save_state(state)
                if not quiet:
                    print(f"  Download failed: {e}")
                continue
            except Exception as e:
                mark_failed(state, sid, f"{type(e).__name__}: {e}")
                save_state(state)
                if not quiet:
                    print(f"  Failed: {e}")
                continue

    finally:
        await client.disconnect()

    if not quiet:
        print(f"\nDone — {completed_count} recording(s) synced.")
    return completed_count


def transcribe_local(file_path: str, cfg: dict, output_dir: str | None = None, quiet: bool = False) -> dict:
    """Transcribe a local audio file (WAV, MP3, etc.) using Whisper."""
    from .transcription.whisper import load_model, transcribe_with_model

    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"File not found: {file_path}")

    if not quiet:
        print(f"Transcribing {path.name} with Whisper ({cfg['transcription']['model']})...")

    model = load_model(cfg["transcription"]["model"])
    result = transcribe_with_model(
        model,
        str(path),
        model_name=cfg["transcription"]["model"],
        language=cfg["transcription"]["language"] or None,
    )
    result["file"] = path.stem

    if output_dir:
        out = Path(output_dir)
    else:
        out = get_output_dirs(cfg)["transcripts"]
    out.mkdir(parents=True, exist_ok=True)

    transcript_path = out / f"{path.stem}.json"
    transcript_path.write_text(json.dumps(result, indent=2, ensure_ascii=False))

    if not quiet:
        print(f"Saved: {transcript_path}")
        print(f"Duration: {result['duration_seconds']}s")
        preview = result["text"][:200]
        print(f"Preview: {preview}")

    return result
