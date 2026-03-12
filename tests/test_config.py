"""Tests for config load/save/defaults."""

import pytest
from pathlib import Path

from plaude.config import (
    load_config, save_config, init_config, set_nested,
    get_output_dirs, DEFAULTS, _deep_merge,
)


@pytest.fixture
def tmp_config(tmp_path):
    return tmp_path / "plaude.toml"


class TestLoadConfig:
    def test_returns_defaults_when_no_file(self, tmp_path):
        cfg = load_config(tmp_path / "nonexistent.toml")
        assert cfg["device"]["address"] == ""
        assert cfg["transcription"]["model"] == "medium"

    def test_loads_and_merges_with_defaults(self, tmp_config):
        save_config({"device": {"address": "AA:BB:CC", "token": "tok123"}}, tmp_config)
        cfg = load_config(tmp_config)
        assert cfg["device"]["address"] == "AA:BB:CC"
        assert cfg["device"]["token"] == "tok123"
        assert cfg["transcription"]["model"] == "medium"
        assert cfg["notifications"]["enabled"] is True


class TestCorruptConfigRecovery:
    def test_corrupt_toml_returns_defaults(self, tmp_config):
        tmp_config.write_text("this is not [valid toml")
        cfg = load_config(tmp_config)
        assert cfg["device"]["address"] == ""
        assert cfg["transcription"]["model"] == "medium"

    def test_binary_garbage_returns_defaults(self, tmp_config):
        tmp_config.write_bytes(b"\x00\xff\xfe\xfd")
        cfg = load_config(tmp_config)
        assert cfg["device"]["address"] == ""

    def test_corrupt_config_quarantined(self, tmp_config):
        """Corrupt config file should be renamed to .corrupt, not deleted."""
        tmp_config.write_text("this is not [valid toml")
        load_config(tmp_config)
        corrupt_path = tmp_config.with_suffix(".corrupt")
        assert corrupt_path.exists()
        assert not tmp_config.exists()


class TestSaveConfig:
    def test_creates_parent_dirs(self, tmp_path):
        path = tmp_path / "deep" / "nested" / "plaude.toml"
        save_config(DEFAULTS, path)
        assert path.exists()

    def test_roundtrip(self, tmp_config):
        save_config(DEFAULTS, tmp_config)
        cfg = load_config(tmp_config)
        assert cfg == DEFAULTS


class TestInitConfig:
    def test_creates_file_with_defaults(self, tmp_config):
        path = init_config(tmp_config)
        assert path.exists()
        cfg = load_config(path)
        assert cfg == DEFAULTS

    def test_does_not_overwrite_existing(self, tmp_config):
        custom = {"device": {"address": "MY_DEVICE", "token": "my_token"}}
        save_config(custom, tmp_config)
        init_config(tmp_config)
        cfg = load_config(tmp_config)
        assert cfg["device"]["address"] == "MY_DEVICE"


class TestSetNested:
    def test_sets_string_value(self):
        cfg = _deep_merge({}, DEFAULTS)
        set_nested(cfg, "device.address", "NEW_ADDR")
        assert cfg["device"]["address"] == "NEW_ADDR"

    def test_coerces_bool(self):
        cfg = _deep_merge({}, DEFAULTS)
        set_nested(cfg, "sync.keep_raw", "true")
        assert cfg["sync"]["keep_raw"] is True

    def test_rejects_unknown_section(self):
        cfg = _deep_merge({}, DEFAULTS)
        with pytest.raises(ValueError, match="Unknown section"):
            set_nested(cfg, "bogus.key", "val")

    def test_rejects_unknown_key(self):
        cfg = _deep_merge({}, DEFAULTS)
        with pytest.raises(ValueError, match="Unknown key"):
            set_nested(cfg, "device.bogus", "val")

    def test_rejects_bad_format(self):
        cfg = _deep_merge({}, DEFAULTS)
        with pytest.raises(ValueError, match="section.name"):
            set_nested(cfg, "just_one_part", "val")


class TestGetOutputDirs:
    def test_returns_expected_subdirs(self):
        cfg = {"output": {"base_dir": "/tmp/plaude_test"}}
        dirs = get_output_dirs(cfg)
        assert dirs["base"] == Path("/tmp/plaude_test")
        assert dirs["audio"] == Path("/tmp/plaude_test/audio")
        assert dirs["transcripts"] == Path("/tmp/plaude_test/transcripts")
        assert dirs["raw"] == Path("/tmp/plaude_test/raw")


class TestDeepMerge:
    def test_overlay_overrides_base(self):
        base = {"a": {"x": 1, "y": 2}, "b": 3}
        overlay = {"a": {"x": 99}}
        result = _deep_merge(base, overlay)
        assert result["a"]["x"] == 99
        assert result["a"]["y"] == 2
        assert result["b"] == 3

    def test_overlay_adds_new_keys(self):
        result = _deep_merge({"a": 1}, {"b": 2})
        assert result == {"a": 1, "b": 2}


class TestDeadConfigFieldsRemoved:
    """Verify that removed config fields are not present in defaults."""

    def test_no_json_timestamps(self):
        assert "json_timestamps" not in DEFAULTS.get("transcription", {})

    def test_no_auto_delete_device(self):
        assert "auto_delete_device" not in DEFAULTS.get("sync", {})
