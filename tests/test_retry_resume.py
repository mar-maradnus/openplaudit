"""Integration-style tests for retry/resume semantics across sync phases.

These tests exercise the state machine transitions that occur when
sessions fail at different phases and are retried on a subsequent sync.
"""

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


class TestRetryAfterDownloadFailure:
    """Session fails during download — should retry from scratch."""

    def test_failed_download_still_needs_download(self):
        state = mark_failed({}, 1000, "Transfer stalled at 500 bytes")
        assert needs_download(state, 1000) is True
        assert needs_decode(state, 1000) is False

    def test_retry_clears_failure(self):
        state = mark_failed({}, 1000, "stall")
        mark_downloaded(state, 1000)
        assert "failed_at" not in state["1000"]
        assert "failure_reason" not in state["1000"]
        assert needs_download(state, 1000) is False
        assert needs_decode(state, 1000) is True


class TestRetryAfterDecodeFailure:
    """Session downloaded but decode failed — should retry decode, not re-download."""

    def test_downloaded_but_failed_needs_decode(self):
        state = mark_downloaded({}, 1000)
        mark_failed(state, 1000, "OpusError: corrupted frame")
        # downloaded_at is still set, so needs_download is False
        assert needs_download(state, 1000) is False
        # decoded_at was never set, so needs_decode is True
        assert needs_decode(state, 1000) is True

    def test_decode_succeeds_on_retry(self):
        state = mark_downloaded({}, 1000)
        mark_failed(state, 1000, "OpusError")
        # Simulate retry: decode succeeds
        mark_decoded(state, 1000)
        assert needs_decode(state, 1000) is False
        assert needs_transcription(state, 1000) is True


class TestRetryAfterTranscriptionFailure:
    """Session downloaded and decoded but transcription failed."""

    def test_decoded_but_failed_needs_transcription(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        mark_failed(state, 1000, "Whisper OOM")
        assert needs_download(state, 1000) is False
        assert needs_decode(state, 1000) is False
        assert needs_transcription(state, 1000) is True
        assert is_complete(state, 1000) is False

    def test_transcription_succeeds_on_retry(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        mark_failed(state, 1000, "Whisper OOM")
        # Retry succeeds
        mark_transcribed(state, 1000)
        assert is_complete(state, 1000) is True


class TestMultiSessionResume:
    """Multiple sessions at different phases — simulate interrupted sync."""

    def test_mixed_phase_sessions(self):
        state = {}
        # Session 1: fully complete
        mark_downloaded(state, 1000)
        mark_decoded(state, 1000)
        mark_transcribed(state, 1000)
        # Session 2: downloaded only
        mark_downloaded(state, 2000)
        # Session 3: never started
        # Session 4: downloaded + decoded, transcription failed
        mark_downloaded(state, 4000)
        mark_decoded(state, 4000)
        mark_failed(state, 4000, "Whisper timeout")

        assert is_complete(state, 1000) is True
        assert needs_decode(state, 2000) is True
        assert needs_download(state, 3000) is True
        assert needs_transcription(state, 4000) is True

    def test_persist_and_resume(self, state_path):
        """State survives save/load cycle — resume picks up where we left off."""
        state = {}
        mark_downloaded(state, 1000)
        mark_decoded(state, 1000)
        mark_downloaded(state, 2000)
        mark_failed(state, 2000, "decode error")
        save_state(state, state_path)

        # Simulate new sync run
        loaded = load_state(state_path)
        assert is_complete(loaded, 1000) is False  # not yet transcribed
        assert needs_transcription(loaded, 1000) is True
        assert needs_decode(loaded, 2000) is True

        # Complete both
        mark_transcribed(loaded, 1000)
        mark_decoded(loaded, 2000)
        mark_transcribed(loaded, 2000)
        save_state(loaded, state_path)

        final = load_state(state_path)
        assert is_complete(final, 1000) is True
        assert is_complete(final, 2000) is True


class TestFailureOverwrite:
    """Multiple failures at different phases — latest failure wins."""

    def test_second_failure_overwrites_first(self):
        state = mark_downloaded({}, 1000)
        mark_failed(state, 1000, "first error")
        assert state["1000"]["failure_reason"] == "first error"
        mark_failed(state, 1000, "second error")
        assert state["1000"]["failure_reason"] == "second error"
        # downloaded_at preserved through failures
        assert "downloaded_at" in state["1000"]


class TestFailureClearingSymmetry:
    """Every successful phase transition should clear stale failure metadata."""

    def test_mark_downloaded_clears_failure(self):
        state = mark_failed({}, 1000, "stall")
        mark_downloaded(state, 1000)
        assert "failed_at" not in state["1000"]
        assert "failure_reason" not in state["1000"]

    def test_mark_decoded_clears_failure(self):
        state = mark_downloaded({}, 1000)
        mark_failed(state, 1000, "OpusError")
        assert "failed_at" in state["1000"]
        mark_decoded(state, 1000)
        assert "failed_at" not in state["1000"]
        assert "failure_reason" not in state["1000"]

    def test_mark_transcribed_clears_failure(self):
        state = mark_downloaded({}, 1000)
        mark_decoded(state, 1000)
        mark_failed(state, 1000, "Whisper OOM")
        assert "failed_at" in state["1000"]
        mark_transcribed(state, 1000)
        assert "failed_at" not in state["1000"]
        assert "failure_reason" not in state["1000"]

    def test_complete_session_has_no_failure_metadata(self):
        state = mark_downloaded({}, 1000)
        mark_failed(state, 1000, "first try failed")
        mark_decoded(state, 1000)
        mark_failed(state, 1000, "second try failed")
        mark_transcribed(state, 1000)
        assert is_complete(state, 1000) is True
        assert "failed_at" not in state["1000"]
        assert "failure_reason" not in state["1000"]
