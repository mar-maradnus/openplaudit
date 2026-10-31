"""Tests for Markdown transcript rendering (Obsidian-friendly output)."""

from plaude.markdown import render_markdown, _hhmm, _human_duration

STEM = "20261019_004855_UTC"

def _result(**kw):
    base = {"duration_seconds": 11670.2, "model": "vllm/whisper-large-v3",
            "chunks": 22, "text": "hello world",
            "segments": [{"start": 0.0, "end": 540.0, "text": "first chunk"},
                         {"start": 540.0, "end": 1080.0, "text": "second chunk"}]}
    base.update(kw)
    return base

def test_frontmatter_matches_vault_convention():
    md = render_markdown(_result(), STEM)
    assert md.startswith("---\n")
    head = md.split("---")[1]
    assert "tags: [" in head
    assert "created: 2026-10-19" in head      # derived from the session stem
    assert "updated: 2026-10-19" in head
    assert "duration: 3h 14m" in head
    body = md.split("---", 2)[2]
    assert body.lstrip().startswith("# 2026-10-19 00:48 UTC")

def test_one_section_per_segment():
    md = render_markdown(_result(), STEM)
    assert "## 0:00 – 9:00" in md
    assert "## 9:00 – 18:00" in md
    assert md.count("\n## ") == 2

def test_long_recording_heading_uses_hours():
    md = render_markdown(_result(), STEM)
    assert "## 1:03:00 – 1:12:00" in md or md.count("## ") == 2

def test_empty_segments_fall_back_to_text():
    md = render_markdown(_result(segments=[], text="plain body"), STEM)
    assert "## Transcript" in md
    assert "plain body" in md

def test_hhmm():
    assert _hhmm(0) == "0:00"
    assert _hhmm(540) == "9:00"
    assert _hhmm(3723) == "1:02:03"

def test_human_duration():
    assert _human_duration(45) == "45s"
    assert _human_duration(600) == "10m 00s"
    assert _human_duration(11670) == "3h 14m"

def test_title_falls_back_for_non_timestamp_stem():
    md = render_markdown(_result(), "not-a-timestamp")
    assert "# not-a-timestamp" in md
