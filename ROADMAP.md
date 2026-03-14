# OpenPlaudit Product Roadmap

## Vision

A privacy-first audio intelligence app for macOS. Record, transcribe, diarize, and summarise — entirely on-device, with no cloud dependency. Audio can come from any source: meetings, microphone, file import, or hardware devices like PLAUD Note.

The product began as a PLAUD Note sync tool but the core value is the local processing pipeline. PLAUD support is one input source among several; the app is useful to anyone who records and transcribes audio.

### Input Sources

| Source | Status | Description |
|--------|--------|-------------|
| **PLAUD BLE sync** | Shipped (v0.1) | Download recordings from PLAUD Note over Bluetooth |
| **Meeting capture** | Shipped (v0.4) | Record system audio + mic from Teams, Zoom, Webex, FaceTime, Slack |
| **Microphone recording** | Planned (v0.5) | Direct dictation or in-person meeting capture, no hardware needed |
| **File import** | Planned (v0.5) | Drag-and-drop or menu import of any audio/video file |
| **System audio** | Planned (v0.6) | Standalone system audio capture, not tied to a specific app |
| **Other hardware** | Future | USB mass storage recorders, other BLE devices |

### Processing Pipeline

All sources feed into the same pipeline:

```
Audio → Transcription (whisper.cpp) → Diarization (speaker ID) → Summarisation (local LLM) → Output
```

Every stage runs locally. Models download on first use. No accounts, no API keys, no data leaving the machine.

---

## Current: v0.4.0

Released 2026-03-13. PLAUD BLE sync, meeting recording, local whisper.cpp transcription, macOS menubar app. Signed with Developer ID and notarised by Apple.

---

## v0.5.0 — New Input Sources + Speaker Diarization + Summarisation

The core intelligence upgrade and the shift from "PLAUD tool" to "privacy-first audio app."

### New Input Sources

**Microphone Recording:**
- Record directly from any connected microphone — built-in, USB, or Bluetooth
- One-click start/stop from the menubar, with optional global keyboard shortcut
- Useful for in-person meetings, dictation, interviews, lectures
- No PLAUD device or meeting app required

**File Import:**
- Drag-and-drop audio/video files onto the menubar icon, or use File → Import
- Supports any format whisper.cpp/FFmpeg handles: WAV, MP3, M4A, FLAC, MP4, MOV, etc.
- Imported files go through the same transcribe → diarize → summarise pipeline
- Useful for processing existing recordings, podcast episodes, voice memos

### Speaker Diarization

Identify who said what in every recording. Speaker labels are embedded in transcript segments.

**Approach:** Native C/C++ diarization using ONNX Runtime with pyannote segmentation model (cf. loud.cpp). Bundled as an SPM C dependency alongside COpus. Models auto-download on first use to `~/.local/share/openplaudit/models/`.

**Pipeline change:**
```
WAV → whisper.cpp (transcription) → diarization (speaker segmentation) → merge → labelled transcript JSON
```

**Transcript format extension:**
```json
{
  "segments": [
    { "start": 0.0, "end": 5.2, "text": "Let's review the numbers.", "speaker": "Speaker 1" },
    { "start": 5.2, "end": 12.0, "text": "Revenue is up 15%.", "speaker": "Speaker 2" }
  ],
  "speakers": ["Speaker 1", "Speaker 2"]
}
```

**Applies to:** All input sources — PLAUD recordings, meetings, microphone, and imported files.

### Local Summarisation

LLM-powered summaries using bundled llama.cpp — no Ollama, MLX, or external runtime required.

**Architecture:** New `SummarisationKit` SPM target. llama.cpp compiled as a C library dependency. Small quantised model (~2GB, e.g. Qwen2.5-3B-Q4 or Phi-3-mini-Q4) downloaded on first use.

**Built-in Templates:**

| Template | Output | Use Case |
|----------|--------|----------|
| **Key Points** | 5-7 bullet points | Quick overview of any recording |
| **Meeting Minutes** | Attendees, agenda, discussion, decisions | Formal meeting records |
| **Action Items** | Task, owner, due date table | Project follow-up |
| **Cornell Notes** | Cues, notes, summary columns | Study and review |
| **SOAP Notes** | Subjective, Objective, Assessment, Plan | Medical consultations |

**Custom Templates:** User-defined prompt templates stored in `~/.config/openplaudit/templates/`. Each template is a text file with a system prompt. The transcript (with speaker labels) is injected as context.

**Settings:**
- Enable/disable summarisation
- Select default template
- Choose summarisation model (small/medium trade-off)
- Manage custom templates

**Output:** Summary appended to the transcript JSON as a `summary` field:
```json
{
  "summary": {
    "template": "action_items",
    "model": "qwen2.5-3b-q4",
    "content": "## Action Items\n| Task | Owner | Due |\n|------|-------|-----|\n| ... |"
  }
}
```

### UI Changes

- Unified "Recent Recordings" list merging all sources (PLAUD, meetings, mic, imports), sorted by date
- Source icon indicator per recording (device, meeting app, microphone, file)
- Transcript preview in menubar shows speaker-labelled text
- Summary preview shown alongside transcript preview
- Settings: new "AI" tab for diarization, summarisation, template management
- Settings: new "Recording" tab for microphone selection and import preferences

---

## v0.6.0 — Mind Maps + Ask AI

### Mind Maps

LLM generates a structured hierarchical outline from the transcript/summary. Exported as:
- Mermaid diagram (rendered in transcript viewer)
- OPML (importable into mind map tools)
- Markdown outline

Stored in transcript JSON as a `mindmap` field.

### Ask AI — Chat With Your Transcript

Local conversational interface for querying recording content.

- Small chat window opened from the menubar or by clicking a recording
- Full transcript + summary loaded as LLM context
- Example queries: "What did Speaker 2 say about the budget?", "Summarise the first 10 minutes", "List all questions that were asked"
- Uses the same bundled llama.cpp model as summarisation
- Context window: 8K tokens minimum (limits apply for very long recordings)

---

## v0.7.0 — Voice Learning

### Persistent Speaker Identification

Name a speaker once; OpenPlaudit recognises them in future recordings across all input sources.

**Approach:**
- Generate speaker embeddings (d-vectors) during diarization
- Store named embeddings in `~/.local/share/openplaudit/speakers/`
- On new recordings, match diarized segments against stored embeddings
- Auto-label matched speakers; prompt for unknown speakers

**UI:**
- After diarization, a "Name Speakers" prompt in the menubar
- Speaker management in Settings (view, rename, delete stored voices)
- Confidence threshold to avoid misidentification

---

## v0.8.0 — Direct Device Binding

### Bind PLAUD Note Without iPhone

Eliminate the token extraction process entirely. OpenPlaudit handles device binding directly over BLE.

**Approach:** Capture the factory-reset BLE binding protocol using an nRF52840 sniffer dongle (Raytac MDBT50Q-CX, on order, expected ~2026-04-03). Reverse-engineer the pairing handshake and replicate it in `BLEKit`.

**User flow:**
1. Factory reset the PLAUD Note
2. Click "Bind Device" in OpenPlaudit Settings
3. OpenPlaudit scans, pairs, and sets a binding token
4. Done — no iPhone backup, no manual token entry

**Trade-off:** Factory reset loses unsynced recordings and breaks the official PLAUD app binding. OpenPlaudit will warn clearly before proceeding.

---

## Backlog

- **Export formats** — PDF, DOCX, SRT subtitle export from transcripts
- **Batch re-summarise** — apply a new template to existing transcripts
- **Keyboard shortcuts** — global hotkeys for recording start/stop
- **Auto-update** — Sparkle framework for in-app update checks
- **iOS companion** — share transcripts via iCloud or local network
- **System audio standalone** — capture system audio without targeting a specific app
- **Other hardware** — USB mass storage voice recorders, other BLE devices
- **Rename** — consider renaming the project to reflect broader scope beyond PLAUD

---

## Technical Principles

- **Zero cloud dependency.** All processing — transcription, diarization, summarisation — runs locally on the user's Mac.
- **No external runtime.** Models and inference engines are bundled. No Ollama, MLX, or Python required.
- **Download on first use.** Large model files are downloaded to `~/.local/share/openplaudit/models/` on first use, not shipped in the app bundle.
- **Shared pipeline.** All input sources feed into the same transcription → diarization → summarisation pipeline.
- **Source-agnostic.** The processing pipeline does not know or care where the audio came from. PLAUD sync, meeting capture, microphone recording, and file import all produce WAV files that enter the same pipeline.
- **Backward-compatible JSON.** New fields (speaker, summary, mindmap) are additive. Older transcripts remain valid.
