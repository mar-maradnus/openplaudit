"""CLI-level tests using Click's CliRunner.

Tests command behaviour, exit codes, error messages, and flag handling
without requiring BLE hardware or Whisper models.
"""

import json
import pytest
from pathlib import Path
from unittest.mock import patch, AsyncMock, MagicMock
from click.testing import CliRunner

from plaude.cli import main
from plaude.config import DEFAULTS, _deep_merge, save_config


@pytest.fixture
def runner():
    return CliRunner()


@pytest.fixture
def tmp_config(tmp_path):
    """Create a temp config file and patch config_path to use it."""
    path = tmp_path / "plaude.toml"
    return path


# --- config commands ---

class TestConfigInit:
    def test_creates_config_file(self, runner, tmp_config):
        with patch("plaude.cli.init_config", return_value=tmp_config):
            result = runner.invoke(main, ["config", "init"])
        assert result.exit_code == 0
        assert str(tmp_config) in result.output


class TestConfigShow:
    def test_shows_defaults(self, runner, tmp_path):
        cfg_path = tmp_path / "plaude.toml"
        with patch("plaude.cli.load_config", return_value=DEFAULTS), \
             patch("plaude.cli.config_path", return_value=cfg_path):
            result = runner.invoke(main, ["config", "show"])
        assert result.exit_code == 0
        assert "medium" in result.output  # transcription model default


class TestConfigSet:
    def test_sets_valid_key(self, runner, tmp_path):
        cfg_path = tmp_path / "plaude.toml"
        with patch("plaude.cli.load_config", return_value=_deep_merge({}, DEFAULTS)), \
             patch("plaude.cli.save_config", return_value=cfg_path):
            result = runner.invoke(main, ["config", "set", "device.address", "NEW_ADDR"])
        assert result.exit_code == 0
        assert "Set device.address" in result.output

    def test_rejects_unknown_key(self, runner):
        with patch("plaude.cli.load_config", return_value=_deep_merge({}, DEFAULTS)):
            result = runner.invoke(main, ["config", "set", "bogus.key", "val"])
        assert result.exit_code != 0
        assert "Error" in result.output


# --- sync command ---

class TestSyncCommand:
    def test_fails_on_missing_device_config(self, runner):
        cfg = _deep_merge({}, DEFAULTS)
        cfg["device"] = {"address": "", "token": ""}
        with patch("plaude.cli.load_config", return_value=cfg):
            result = runner.invoke(main, ["sync"])
        assert result.exit_code != 0
        assert "Error" in result.output

    def test_quiet_flag_suppresses_output(self, runner):
        cfg = _deep_merge({}, DEFAULTS)
        cfg["device"] = {"address": "", "token": ""}
        with patch("plaude.cli.load_config", return_value=cfg):
            result = runner.invoke(main, ["-q", "sync"])
        assert result.exit_code != 0
        # Error still shown on stderr even in quiet mode
        assert "Error" in result.output


# --- list command ---

class TestListCommand:
    def test_fails_on_missing_device_config(self, runner):
        cfg = _deep_merge({}, DEFAULTS)
        cfg["device"] = {"address": "", "token": ""}
        with patch("plaude.cli.load_config", return_value=cfg):
            result = runner.invoke(main, ["list"])
        assert result.exit_code != 0
        assert "Device address and token" in result.output


# --- scan command ---

class TestScanCommand:
    def test_scan_no_devices_found(self, runner):
        mock_scan = AsyncMock(return_value=[])
        with patch("plaude.ble.client.PlaudClient.scan", mock_scan):
            result = runner.invoke(main, ["scan"])
        assert result.exit_code == 0
        assert "No PLAUD devices found" in result.output

    def test_scan_finds_device(self, runner):
        devices = [{"name": "PLAUD", "address": "AA:BB:CC", "rssi": -50}]
        mock_scan = AsyncMock(return_value=devices)
        with patch("plaude.ble.client.PlaudClient.scan", mock_scan):
            result = runner.invoke(main, ["scan"])
        assert result.exit_code == 0
        assert "PLAUD" in result.output
        assert "AA:BB:CC" in result.output


# --- transcribe command ---

class TestTranscribeCommand:
    def test_fails_on_nonexistent_file(self, runner):
        result = runner.invoke(main, ["transcribe", "/nonexistent/file.wav"])
        assert result.exit_code != 0

    def test_transcribes_existing_file(self, runner, tmp_path):
        wav = tmp_path / "test.wav"
        wav.write_bytes(b"\x00" * 100)
        transcript_dir = tmp_path / "transcripts"

        fake_result = {
            "duration_seconds": 1.0, "model": "tiny", "language": "en",
            "segments": [], "text": "hello",
        }

        cfg = _deep_merge({}, DEFAULTS)
        cfg["output"] = {"base_dir": str(tmp_path)}
        cfg["transcription"] = {"model": "tiny", "language": "en"}

        with patch("plaude.cli.load_config", return_value=cfg), \
             patch("plaude.transcription.whisper.load_model", return_value=MagicMock()), \
             patch("plaude.transcription.whisper.transcribe_with_model", return_value=fake_result):
            result = runner.invoke(main, ["transcribe", str(wav), "-o", str(transcript_dir)])

        assert result.exit_code == 0
        assert "Saved" in result.output


# --- verbose/quiet flags ---

class TestGlobalFlags:
    def test_verbose_flag_accepted(self, runner):
        cfg = _deep_merge({}, DEFAULTS)
        cfg["device"] = {"address": "", "token": ""}
        with patch("plaude.cli.load_config", return_value=cfg):
            result = runner.invoke(main, ["-v", "sync"])
        # Should fail on config, not on flag parsing
        assert result.exit_code != 0
        assert "Error" in result.output

    def test_quiet_flag_accepted(self, runner):
        cfg = _deep_merge({}, DEFAULTS)
        cfg["device"] = {"address": "", "token": ""}
        with patch("plaude.cli.load_config", return_value=cfg):
            result = runner.invoke(main, ["-q", "sync"])
        assert result.exit_code != 0
