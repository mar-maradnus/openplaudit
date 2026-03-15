# Privacy Policy

**OpenPlaudit** — Last updated: 15 March 2026

## Summary

OpenPlaudit processes all audio, transcription, speaker identification, and AI summarisation **entirely on your devices**. No audio, transcripts, or personal data are transmitted to any external server.

## Data Collection

OpenPlaudit does **not** collect, transmit, or store any personal data on external servers. Specifically:

- **No analytics or telemetry.** The app does not phone home.
- **No accounts or sign-up.** There are no user accounts.
- **No cloud processing.** All AI processing (transcription, diarization, summarisation, mind maps) runs locally on your Mac using on-device models.
- **No advertising.** There are no ads or ad-tracking SDKs.

## Data Stored on Your Devices

The following data is created and stored **locally** on your devices:

| Data | Location | Purpose |
|------|----------|---------|
| Audio recordings (WAV) | Mac: `~/Documents/OpenPlaudit/` · iPhone: app sandbox | Source audio for transcription |
| Transcripts (JSON) | Same directories | Whisper-generated text with timestamps |
| Speaker labels | Embedded in transcript JSON | Speaker diarization results |
| AI summaries and mind maps | Embedded in transcript JSON | LLM-generated content from local models |
| Pairing key | macOS/iOS Keychain | Authenticates the iPhone–Mac sync connection |
| App preferences | UserDefaults | Audio quality, sync settings, UI preferences |
| Whisper model files | App container / `~/.cache/openplaudit/` | On-device speech recognition model |

## Local Network Sync

When paired, the iPhone companion app syncs recordings to your Mac over your **local Wi-Fi network** using a direct TCP connection. This traffic never leaves your local network. The connection is authenticated using HMAC-SHA256 with a shared key established during one-time pairing.

No data is sent to Apple, Anthropic, OpenAI, or any other third party during sync.

## Bluetooth (macOS only)

If you connect a PLAUD Note device, the Mac app communicates with it over Bluetooth Low Energy to download recordings. This is a direct device-to-device connection.

## Microphone Access

The app requests microphone access to record audio. Microphone data is written directly to local storage and is never transmitted externally.

## Third-Party Services

OpenPlaudit uses **no** third-party services, SDKs, or APIs. All dependencies are open-source libraries compiled into the app binary:

- **whisper.cpp** — speech recognition (MIT licence)
- **llama.cpp** — local LLM inference (MIT licence)

## Children's Privacy

OpenPlaudit does not knowingly collect any information from children under 13.

## Data Deletion

All data is stored on your devices. To delete it:

- **Mac:** Delete recordings from `~/Documents/OpenPlaudit/` or use Settings → Storage → Clear Cache
- **iPhone:** Use Settings → Storage → Clear Cache, or delete the app (removes all app data)
- **Pairing key:** Unpairing in Settings removes the key from both devices' Keychains

## Changes to This Policy

If this policy changes, the updated version will be published at this URL. Material changes will be noted in the app's release notes.

## Contact

For privacy questions: [mar.maradnus@pm.me](mailto:mar.maradnus@pm.me)
