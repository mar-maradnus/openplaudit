"""Render a transcript JSON result as an Obsidian-friendly Markdown note."""

import datetime
import re
from pathlib import Path

_TAG_BASE = ["plaud", "recording"]

def _hhmm(seconds: float) -> str:
    """Format seconds as a clock offset: 0:00, 9:03, 1:02:03."""
    s = int(max(0, seconds))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"

def _human_duration(seconds: float) -> str:
    s = int(max(0, seconds))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {sec:02d}s"
    return f"{sec}s"

def _title(stem: str, result: dict) -> str:
    """Human title: the local start time, with a note-identifying stem."""
    try:
        ts = datetime.datetime.strptime(stem, "%Y%m%d_%H%M%S_UTC")
        return ts.strftime("%Y-%m-%d %H:%M UTC")
    except ValueError:
        return stem.replace("_", " ")

def _slug(text: str, limit: int = 60) -> str:
    """A short, filename-safe fragment of the opening words."""
    text = re.sub(r"[^A-Za-z0-9 \-']", " ", text or "")
    words = " ".join(text.split())[:limit].strip()
    return words.rstrip(" -")

def render_markdown(result: dict, stem: str, *, updated: str | None = None,
                    audio_name: str | None = None,
                    raw_name: str | None = None) -> str:
    """Render a transcript dict (the JSON we write) as Markdown.

    Structure:
      frontmatter -> H1 title -> metadata line -> one ## section per chunk.
    Chunk sections give Obsidian a navigable outline, which matters for a
    multi-hour recording where the single `text` blob is 70k+ characters.
    """
    duration = float(result.get("duration_seconds") or 0.0)
    segments = result.get("segments") or []
    text = (result.get("text") or "").strip()

    try:
        created = datetime.datetime.strptime(stem, "%Y%m%d_%H%M%S_UTC").strftime("%Y-%m-%d")
    except ValueError:
        created = datetime.date.today().isoformat()
    updated = updated or created

    tags = list(_TAG_BASE)
    if result.get("chunks"):
        tags.append("long-recording")

    lines: list[str] = []
    lines.append("---")
    lines.append(f"tags: [{', '.join(tags)}]")
    lines.append(f"created: {created}")
    lines.append(f"updated: {updated}")
    lines.append(f"duration_seconds: {int(duration)}")
    lines.append(f"duration: {_human_duration(duration)}")
    if result.get("model"):
        lines.append(f"model: {result['model']}")
    if result.get("chunks"):
        lines.append(f"chunks: {result['chunks']}")
    lines.append(f"source: {stem}")
    lines.append("---")
    lines.append("")

    lines.append(f"# {_title(stem, result)}")
    lines.append("")

    opening = _slug(text)
    if opening:
        lines.append(f"> {opening}…")
        lines.append("")

    meta = [f"**Duration:** {_human_duration(duration)}"]
    if result.get("chunks"):
        meta.append(f"**Chunks:** {result['chunks']}")
    if result.get("model"):
        meta.append(f"**Model:** {result['model']}")
    lines.append(" · ".join(meta))
    lines.append("")
    if audio_name:
        lines.append(f"**Audio:** `{audio_name}`")
        if raw_name:
            lines.append(f"**Raw:** `{raw_name}`")
        lines.append("")

    if segments:
        for seg in segments:
            start = float(seg.get("start") or 0.0)
            end = float(seg.get("end") or 0.0)
            seg_text = (seg.get("text") or "").strip()
            if not seg_text:
                continue
            lines.append(f"## {_hhmm(start)} – {_hhmm(end)}")
            lines.append("")
            lines.append(seg_text)
            lines.append("")
    elif text:
        lines.append("## Transcript")
        lines.append("")
        lines.append(text)
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"

def write_markdown(result: dict, stem: str, out_dir: str | Path, *,
                   audio_name: str | None = None,
                   raw_name: str | None = None) -> Path:
    """Write `<stem>.md` into `out_dir` and return the path."""
    out = Path(out_dir).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{stem}.md"
    path.write_text(render_markdown(result, stem, audio_name=audio_name,
                                    raw_name=raw_name), encoding="utf-8")
    return path
