"""Orchestration-level tests for run_sync() with mocked BLE, decoder, and Whisper.

These tests exercise the full sync pipeline logic without requiring
real BLE hardware, Opus codec, or Whisper model.
"""

import asyncio
import json
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from plaude.state import (
    load_state, save_state,
    mark_downloaded, mark_decoded, mark_failed,
    is_complete, needs_download, needs_decode, needs_transcription,
)
from plaude.state import mark_transcribed


# --- Fixtures ---

@pytest.fixture
def sync_dirs(tmp_path):
    dirs = {
        "base": tmp_path,
        "audio": tmp_path / "audio",
        "transcripts": tmp_path / "transcripts",
        "raw": tmp_path / "raw",
    }
    for d in dirs.values():
        d.mkdir(parents=True, exist_ok=True)
    return dirs


@pytest.fixture
def state_path(tmp_path):
    return tmp_path / "state.json"


@pytest.fixture
def cfg(tmp_path):
    return {
        "device": {"address": "AA:BB:CC", "token": "deadbeef" * 4},
        "output": {"base_dir": str(tmp_path)},
        "transcription": {"model": "tiny", "language": "en"},
        "sync": {"auto_delete_local_audio": False, "keep_raw": False},
        "notifications": {"enabled": False, "show_preview": False},
    }


# --- Helpers ---

def _fake_whisper_result():
    return {
        "duration_seconds": 5.0,
        "model": "tiny",
        "language": "en",
        "segments": [{"start": 0.0, "end": 5.0, "text": "Hello world"}],
        "text": "Hello world",
    }


# --- Tests ---

class TestRunSyncNoDeviceConfig:
    """Missing device config should fail fast — no BLE imports needed."""

    @pytest.mark.asyncio
    async def test_raises_on_missing_address(self, cfg):
        cfg["device"]["address"] = ""
        from plaude.sync import run_sync
        with pytest.raises(ValueError, match="Device address"):
            await run_sync(cfg)

    @pytest.mark.asyncio
    async def test_raises_on_missing_token(self, cfg):
        cfg["device"]["token"] = ""
        from plaude.sync import run_sync
        with pytest.raises(ValueError, match="Device address"):
            await run_sync(cfg)


class TestRunSyncAlreadyComplete:
    """Sessions with transcribed_at should not be re-processed."""

    @pytest.mark.asyncio
    async def test_skips_complete_sessions(self, cfg):
        sessions = [{"session_id": 1000, "file_size": 890, "scene": 1}]
        state = {}
        mark_downloaded(state, 1000)
        mark_decoded(state, 1000)
        mark_transcribed(state, 1000)

        mock_client = AsyncMock()
        mock_client.handshake.return_value = True
        mock_client.get_sessions.return_value = sessions

        with patch("plaude.ble.client.PlaudClient", return_value=mock_client), \
             patch("plaude.sync.load_state", return_value=state), \
             patch("plaude.sync.save_state"):

            from plaude.sync import run_sync
            count = await run_sync(cfg, quiet=True)

        assert count == 0


class TestRunSyncDownloadFailure:
    """Download fails — session marked failed, pipeline continues."""

    @pytest.mark.asyncio
    async def test_download_error_records_failure(self, cfg):
        from plaude.ble.transfer import DownloadError

        sessions = [{"session_id": 1000, "file_size": 890, "scene": 1}]
        state = {}

        mock_client = AsyncMock()
        mock_client.handshake.return_value = True
        mock_client.get_sessions.return_value = sessions

        with patch("plaude.ble.client.PlaudClient", return_value=mock_client), \
             patch("plaude.ble.transfer.download_file", new_callable=AsyncMock,
                   side_effect=DownloadError("stall")), \
             patch("plaude.sync.load_state", return_value=state), \
             patch("plaude.sync.save_state"):

            from plaude.sync import run_sync
            count = await run_sync(cfg, quiet=True)

        assert count == 0
        assert "failed_at" in state.get("1000", {})
        assert "stall" in state["1000"]["failure_reason"]


class TestPhaseStateClearingInPipeline:
    """Verify the state machine clears failure metadata symmetrically."""

    def test_all_phases_clear_failure(self):
        state = {}
        # Fail at download phase
        mark_failed(state, 1000, "download error")
        assert "failed_at" in state["1000"]

        # Download succeeds on retry
        mark_downloaded(state, 1000)
        assert "failed_at" not in state["1000"]

        # Fail at decode phase
        mark_failed(state, 1000, "decode error")
        assert "failed_at" in state["1000"]

        # Decode succeeds on retry
        mark_decoded(state, 1000)
        assert "failed_at" not in state["1000"]

        # Fail at transcription phase
        mark_failed(state, 1000, "whisper error")
        assert "failed_at" in state["1000"]

        # Transcription succeeds on retry
        mark_transcribed(state, 1000)
        assert "failed_at" not in state["1000"]
        assert is_complete(state, 1000) is True

    def test_state_never_has_stale_failure_after_completion(self):
        """End-to-end: a session that failed at every phase and eventually
        completed should have no failure metadata."""
        state = {}
        for phase_fn in [mark_downloaded, mark_decoded, mark_transcribed]:
            mark_failed(state, 1000, f"failed before {phase_fn.__name__}")
            phase_fn(state, 1000)
            assert "failed_at" not in state["1000"]
            assert "failure_reason" not in state["1000"]
