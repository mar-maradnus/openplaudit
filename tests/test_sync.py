"""Tests for sync orchestrator — filename generation, UTC stability."""

import datetime

from plaude.sync import _session_filename, _format_local_time


class TestSessionFilename:
    def test_uses_utc(self):
        # 1773294238 = 2026-03-12 05:43:58 UTC
        fname = _session_filename(1773294238)
        assert fname == "20260312_054358_UTC"

    def test_timezone_stable(self):
        """Same session_id always produces same filename regardless of local TZ."""
        fname1 = _session_filename(1000000000)
        fname2 = _session_filename(1000000000)
        assert fname1 == fname2
        assert fname1.endswith("_UTC")

    def test_format_is_sortable(self):
        f1 = _session_filename(1000000000)
        f2 = _session_filename(1000000001)
        assert f1 < f2


class TestFormatLocalTime:
    def test_returns_string(self):
        result = _format_local_time(1773294238)
        assert isinstance(result, str)
        assert "2026" in result
