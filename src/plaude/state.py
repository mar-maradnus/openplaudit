"""Session state tracker — phase-aware tracking of download/decode/transcribe.

State file: ~/.local/share/openplaudit/state.json
Kept separate from config so cloud sync (iCloud, Dropbox) doesn't cause conflicts.

Each session progresses through phases:
  downloaded_at -> decoded_at -> transcribed_at

A session is only considered complete when transcribed_at is set.
Failures at any phase are recorded with failed_at + failure_reason,
and the session will be retried on the next sync run.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger(__name__)

DEFAULT_STATE_PATH = Path("~/.local/share/openplaudit/state.json").expanduser()


def _load_raw(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        text = path.read_text()
        if not text.strip():
            return {}
        return json.loads(text)
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        # Quarantine the corrupt file so it can be inspected later
        backup = path.with_suffix(".corrupt")
        try:
            path.rename(backup)
            log.warning("Corrupt state file %s: %s — quarantined to %s, starting fresh",
                        path, e, backup)
        except OSError:
            log.warning("Corrupt state file %s: %s — starting fresh", path, e)
        return {}


def _save_raw(state: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(path)


def load_state(path: Path | None = None) -> dict:
    """Load the sync state. Keys are string session_ids."""
    return _load_raw(path or DEFAULT_STATE_PATH)


def save_state(state: dict, path: Path | None = None) -> None:
    """Persist the sync state atomically."""
    _save_raw(state, path or DEFAULT_STATE_PATH)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _get_entry(state: dict, session_id: int) -> dict:
    key = str(session_id)
    if key not in state:
        state[key] = {}
    return state[key]


def _clear_failure(entry: dict) -> None:
    """Remove stale failure metadata after a successful phase transition."""
    entry.pop("failed_at", None)
    entry.pop("failure_reason", None)


def mark_downloaded(state: dict, session_id: int) -> dict:
    """Mark a session as successfully downloaded from device."""
    entry = _get_entry(state, session_id)
    entry["downloaded_at"] = _now_iso()
    _clear_failure(entry)
    return state


def mark_decoded(state: dict, session_id: int) -> dict:
    """Mark a session as successfully decoded to WAV."""
    entry = _get_entry(state, session_id)
    entry["decoded_at"] = _now_iso()
    _clear_failure(entry)
    return state


def mark_transcribed(state: dict, session_id: int) -> dict:
    """Mark a session as successfully transcribed."""
    entry = _get_entry(state, session_id)
    entry["transcribed_at"] = _now_iso()
    _clear_failure(entry)
    return state


def mark_failed(state: dict, session_id: int, reason: str) -> dict:
    """Record a failure for a session. Session will be retried on next sync."""
    entry = _get_entry(state, session_id)
    entry["failed_at"] = _now_iso()
    entry["failure_reason"] = reason
    return state


def needs_download(state: dict, session_id: int) -> bool:
    """True if session has not been downloaded, or last attempt failed before decode."""
    entry = state.get(str(session_id), {})
    return "downloaded_at" not in entry


def needs_decode(state: dict, session_id: int) -> bool:
    """True if session was downloaded but not yet decoded."""
    entry = state.get(str(session_id), {})
    return "downloaded_at" in entry and "decoded_at" not in entry


def needs_transcription(state: dict, session_id: int) -> bool:
    """True if session was decoded but not yet transcribed."""
    entry = state.get(str(session_id), {})
    return "decoded_at" in entry and "transcribed_at" not in entry


def is_complete(state: dict, session_id: int) -> bool:
    """True if session has been fully processed (transcribed)."""
    return "transcribed_at" in state.get(str(session_id), {})
