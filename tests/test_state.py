"""Tests for phase-aware session state tracking."""

import json
import pytest
from pathlib import Path

from plaude.state import (
    load_state, save_state,
    mark_downloaded, mark_decoded, mark_transcribed, mark_failed,
    needs_download, needs_decode, needs_transcription, is_complete,
)


@pytest.fixture
def state_path(tmp_path):
    return tmp_path / "state.json"


class TestStateRoundtrip:
    def test_empty_state_when_no_file(self, state_path):
        assert load_state(state_path) == {}

    def test_save_and_load(self, state_path):
        state = {"12345": {"downloaded_at": "2026-03-12T00:00:00+00:00"}}
        save_state(state, state_path)
        loaded = load_state(state_path)
        assert loaded == state

    def test_creates_parent_dirs(self, tmp_path):
        path = tmp_path / "deep" / "state.json"
        save_state({"k": "v"}, path)
        assert path.exists()

    def test_atomic_write_survives_crash(self, state_path):
        """save_state writes to .tmp then renames — no partial writes."""
        save_state({"a": 1}, state_path)
        tmp = state_path.with_suffix(".tmp")
        assert not tmp.exists()
        assert load_state(state_path) == {"a": 1}


class TestCorruptStateRecovery:
    def test_corrupt_json_returns_empty(self, state_path):
        state_path.write_text("{invalid json")
        assert load_state(state_path) == {}

    def test_empty_file_returns_empty(self, state_path):
        state_path.write_text("")
        assert load_state(state_path) == {}

    def test_binary_garbage_returns_empty(self, state_path):
        state_path.write_bytes(b"\x00\xff\xfe")
        assert load_state(state_path) == {}

    def test_corrupt_file_quarantined(self, state_path):
        """Corrupt state file should be renamed to .corrupt, not deleted."""
        state_path.write_text("{invalid json")
        load_state(state_path)
        corrupt_path = state_path.with_suffix(".corrupt")
        assert corrupt_path.exists()
        assert corrupt_path.read_text() == "{invalid json"
        assert not state_path.exists()


class TestPhaseMarking:
    def test_mark_downloaded(self):
        state = mark_downloaded({}, 1000)
        assert "downloaded_at" in state["1000"]

    def test_mark_decoded(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        assert "decoded_at" in state["1000"]
        assert "downloaded_at" in state["1000"]

    def test_mark_transcribed(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        mark_transcribed(state, 1000)
        assert "transcribed_at" in state["1000"]

    def test_mark_failed_records_reason(self):
        state = mark_downloaded({}, 1000)
        mark_failed(state, 1000, "Whisper OOM")
        assert state["1000"]["failure_reason"] == "Whisper OOM"
        assert "failed_at" in state["1000"]

    def test_mark_downloaded_clears_failure(self):
        state = mark_failed({}, 1000, "stall")
        mark_downloaded(state, 1000)
        assert "failed_at" not in state["1000"]
        assert "failure_reason" not in state["1000"]


class TestPhaseQueries:
    def test_needs_download_for_unknown(self):
        assert needs_download({}, 9999) is True

    def test_needs_download_false_after_marking(self):
        state = mark_downloaded({}, 1000)
        assert needs_download(state, 1000) is False

    def test_needs_decode_after_download(self):
        state = mark_downloaded({}, 1000)
        assert needs_decode(state, 1000) is True

    def test_needs_decode_false_after_marking(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        assert needs_decode(state, 1000) is False

    def test_needs_transcription_after_decode(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        assert needs_transcription(state, 1000) is True

    def test_needs_transcription_false_after_marking(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        mark_transcribed(state, 1000)
        assert needs_transcription(state, 1000) is False

    def test_is_complete_requires_all_phases(self):
        state = mark_downloaded({}, 1000)
        assert is_complete(state, 1000) is False
        mark_decoded(state, 1000)
        assert is_complete(state, 1000) is False
        mark_transcribed(state, 1000)
        assert is_complete(state, 1000) is True


class TestFullLifecycle:
    def test_persist_and_reload(self, state_path):
        state = {}
        mark_downloaded(state, 1000)
        mark_decoded(state, 1000)
        mark_transcribed(state, 1000)
        save_state(state, state_path)

        loaded = load_state(state_path)
        assert is_complete(loaded, 1000)
        assert not needs_download(loaded, 1000)
        assert not needs_decode(loaded, 1000)
        assert not needs_transcription(loaded, 1000)

    def test_failed_session_retryable(self):
        state = mark_downloaded({}, 1000)
        mark_failed(state, 1000, "decode error")
        # Session has downloaded_at but not decoded_at, so needs_decode is True
        assert needs_decode(state, 1000) is True
        assert is_complete(state, 1000) is False
