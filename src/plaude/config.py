"""Configuration management — load/save TOML, defaults, path expansion."""

import logging
import tomllib
from pathlib import Path

import tomli_w

log = logging.getLogger(__name__)

CONFIG_DIR = "~/.config/openplaudit"
CONFIG_FILENAME = "config.toml"
DEFAULT_OUTPUT_DIR = "~/Documents/OpenPlaudit"

DEFAULTS = {
    "device": {
        "address": "",
        "token": "",
    },
    "output": {
        "base_dir": DEFAULT_OUTPUT_DIR,
    },
    "transcription": {
        "model": "medium",
        "language": "en",
    },
    "sync": {
        "auto_delete_local_audio": False,
        "keep_raw": False,
    },
    "notifications": {
        "enabled": True,
        "show_preview": True,
    },
}


def config_path() -> Path:
    """Return the path to the config file."""
    return Path(CONFIG_DIR).expanduser() / CONFIG_FILENAME


def _deep_merge(base: dict, overlay: dict) -> dict:
    """Merge overlay into base, returning a new dict with deep-copied nested structure."""
    import copy
    result = {}
    for key in set(base) | set(overlay):
        base_val = base.get(key)
        over_val = overlay.get(key)
        if key in base and key in overlay:
            if isinstance(base_val, dict) and isinstance(over_val, dict):
                result[key] = _deep_merge(base_val, over_val)
            else:
                result[key] = copy.deepcopy(over_val)
        elif key in overlay:
            result[key] = copy.deepcopy(over_val)
        else:
            result[key] = copy.deepcopy(base_val)
    return result


def load_config(path: Path | None = None) -> dict:
    """Load config from TOML file, merged with defaults.

    Returns defaults on missing file or parse error.
    """
    path = path or config_path()
    if path.exists():
        try:
            with open(path, "rb") as f:
                user_config = tomllib.load(f)
            return _deep_merge(DEFAULTS, user_config)
        except Exception as e:
            backup = path.with_suffix(".corrupt")
            try:
                path.rename(backup)
                log.warning("Failed to parse config %s: %s — quarantined to %s, using defaults",
                            path, e, backup)
            except OSError:
                log.warning("Failed to parse config %s: %s — using defaults", path, e)
    return _deep_merge({}, DEFAULTS)


def save_config(cfg: dict, path: Path | None = None) -> Path:
    """Save config to TOML file. Creates parent directories."""
    path = path or config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        tomli_w.dump(cfg, f)
    return path


def init_config(path: Path | None = None) -> Path:
    """Create a default config file if one doesn't exist."""
    path = path or config_path()
    if path.exists():
        return path
    return save_config(DEFAULTS, path)


def get_output_dirs(cfg: dict) -> dict[str, Path]:
    """Return resolved output directory paths."""
    base = Path(cfg["output"]["base_dir"]).expanduser()
    return {
        "base": base,
        "audio": base / "audio",
        "transcripts": base / "transcripts",
        "raw": base / "raw",
    }


def set_nested(cfg: dict, dotted_key: str, value: str) -> dict:
    """Set a value in the config using dotted key notation (e.g. 'device.address').

    Coerces string values to bool/int where the default is bool/int.
    """
    keys = dotted_key.split(".")
    if len(keys) != 2:
        raise ValueError(f"Key must be section.name, got: {dotted_key}")

    section, name = keys
    if section not in cfg:
        raise ValueError(f"Unknown section: {section}")
    if name not in cfg[section]:
        raise ValueError(f"Unknown key: {dotted_key}")

    current = cfg[section][name]
    if isinstance(current, bool):
        value = value.lower() in ("true", "1", "yes")
    elif isinstance(current, int):
        value = int(value)

    cfg[section][name] = value
    return cfg
