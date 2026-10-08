# Changelog

## beta-0.0.1 — 2026-10-08

This release provides an early terminal beta for macOS 14.2 or later.

### Features

- praatvol captures microphone audio until Ctrl+C.
- The bundled `praatvol.app` helper adds system audio through Core Audio, without virtual drivers or changes to audio routing.
- The script supports different microphones and headsets, including separate devices for input and output.
- `--mic NAME` selects a microphone, and `--list-devices` lists inputs and defaults.
- ElevenLabs Scribe v2 supplies timestamps and speaker labels through OpenRouter.
- Opus uploads reduce size, while local Free Lossless Audio Codec (FLAC) archives preserve lossless audio.
- The script targets 64 kilobits per second (kbps) through 60 minutes, then 48 kbps through 90 minutes.
- Beyond 90 minutes, the script targets 32 kbps and warns about timeout risk.
- `--lossless` uploads lossless audio instead of Opus.
- Single requests succeeded at 60 minutes with 64 kbps and 90 minutes with 48 kbps.
- The size guard checks the estimated base64 JavaScript Object Notation (JSON) body against a 50,000,000-byte safety limit.
- OpenRouter reports a body limit of 50 mebibytes (MiB), or 52,428,800 bytes.
- The script handles provider errors inside Hypertext Transfer Protocol (HTTP) 200 responses and keeps local audio.
- Each run writes a Markdown transcript and a raw JSON response.
- The observed OpenRouter cost is about 0.11 United States dollars (USD) per audio hour.

### Known limits

- The beta runs from the terminal and lacks a visible app interface.
- The helper build targets Apple Silicon.
- Speaker letters identify voices within one request, not names or persistent identities across recordings.
- Durations beyond 90 minutes remain untested, and provider timeouts can occur.
- The script does not split requests or reliably match speakers across separate requests.
- Lossless uploads reach the size limit sooner than Opus uploads.
- Long recordings can exceed memory during conversion or the mixer stage.
- The helper lacks recovery if the output device changes during capture.
- Real-call quality and headset capture still need manual checks.
- Transcripts contain private speech, and OpenRouter and ElevenLabs receive the audio.
- Capture requires appropriate consent and macOS permissions.
- The existing request client retries some failures, which can duplicate paid requests.
