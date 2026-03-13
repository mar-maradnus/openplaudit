"""macOS notifications via osascript — no extra dependencies."""

import subprocess


def notify(title: str, message: str, subtitle: str = "") -> None:
    """Send a macOS notification. Fails silently on non-macOS."""
    script = f'display notification "{_escape(message)}"'
    script += f' with title "{_escape(title)}"'
    if subtitle:
        script += f' subtitle "{_escape(subtitle)}"'
    try:
        subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


def _escape(s: str) -> str:
    """Escape double quotes and backslashes for AppleScript."""
    return s.replace("\\", "\\\\").replace('"', '\\"')
