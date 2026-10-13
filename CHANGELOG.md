# Changelog

## Unreleased

### Features

- The native two-pane main window adds a sidebar, a detail view, and a window toolbar.
- The toolbar offers Record Call, Record Room, Import Audio, and Settings, with a red Cancel or Stop button during capture.
- Command-period cancels setup or stops capture.
- The sidebar groups transcribed items and failed items by day, with kind icons, titles, duration, and speaker count.
- Calls and rooms show their kind and start time; imported files show the file name without the extension.
- The detail view adds transcript statistics and a preview of up to 40 speaker lines with timestamps and colour-coded labels.
- Failed items show plain-language summaries and fixes, including timeout guidance.
- The live view adds level bars, a step bar, upload percent, and estimated transcription progress.
- Rename stores a custom title in `item.json` without a folder name change, and Recent shows titles and dates.
- Copy Transcript copies the complete Markdown text to the clipboard.
- Move to Trash asks for confirmation and moves the whole item folder to the macOS Trash for restoration.
- The Delete key requests the same confirmed action, except for the item of the active job.

### Fixes

- The sidebar excludes unfinished attempts without transcripts or failures; Finder still provides access to those folders.
- Settings replaces an inaccessible Keychain item from an earlier build when you save the key again.
- Keychain read failures explain the access problem and ask you to save the key again in Settings.

## 0.1.0 — 2026-10-09

This version adds a native menu bar app for macOS 14.2 or later on Apple Silicon.
The Python beta remains unchanged under `experiments/`.

### Features

- The sine-wave icon shows capture state and an elapsed timer.
- The main window adds a Now panel with steps, live meters, file size, duration tiers, progress, and saved summaries.
- The library lists past items with dates, kinds, duration, speakers, cost, status, and transcript or Finder actions.
- Confirmed manual retry transcribes failed or untranscribed audio with the current settings.
- The richer menu adds a status line, signal dots, immediate Stop, Open praatvol, and five recent transcripts.
- Real upload callbacks report sent bytes, request size, and percent.
- Transcription progress shows elapsed seconds and an estimate from earlier trials.
- The native window supports dark and light modes without a focus change at recording start.
- Call capture combines a microphone with an in-process tap through Core Audio.
- Room capture uses only the selected microphone.
- File import preserves the original audio before conversion.
- The app saves separate raw tracks in Core Audio Format (CAF) before conversion.
- Raw Free Lossless Audio Codec (FLAC) compression preserves the native rate and channels, with exact sample verification before CAF removal.
- If encoding or exact verification fails, the app retains the CAF and reports the reason.
- The app saves a FLAC archive if Apple's encoder supports FLAC.
- A Waveform Audio File Format (WAV) archive supplies the lossless fallback.
- Advanced Audio Coding (AAC) copies use 64, 48, or 32 kilobits per second (kbps), based on duration.
- The request guard checks the estimate and the complete serialized body against 50,000,000 bytes.
- The app handles provider errors inside successful Hypertext Transfer Protocol (HTTP) responses.
- The app never retries a paid request automatically.
- Settings keep the OpenRouter key in Keychain and offer a model field, microphone picker, and lossless option.
- Service Management supports launch at login for an installed app.
- Dated folders contain Markdown transcripts, raw JavaScript Object Notation (JSON) responses, and saved audio.
- Each item stores library metadata and failures in `item.json`.
- The app preserves failed raw responses in `transcript-error.json`, including errors inside HTTP 200.
- Notifications open completed transcripts; Finder supplies the fallback if notifications lack permission.
- Separate dev and release bundles isolate keys, settings, permissions, storage, and logs.
- Swift Package Manager (SwiftPM) builds, Apple-only icon tools, and ad-hoc signatures require no Xcode project.
- Offline Swift tests cover core rules, parsing, transcripts, paths, codecs, channel averages, and alignment.
- New core tests cover job transitions, progress, estimates, duration hints, meters, library metadata, status, retry, and raw verification.
- GitHub Actions runs lint, build, tests with a 70% coverage gate, and a `task/` branch-name check on each pull request into `main`.

### Fixes

- Capture setup runs outside the main thread with an eight-second watchdog and immediate cancellation controls.
- The app requests microphone permission before setup and starts the microphone before the system tap.
- The capture queue removes resources after a cancelled operating-system call returns.
- The Edit menu preserves Command-V and other text shortcuts in settings.
- The login option unregisters only an existing Service Management registration.
- Missing keys preserve audio for a confirmed manual retry.

### Validation and limits

- Microphone capture, system audio prompts, notifications, and login behavior require manual checks on a desktop session.
- The public models application programming interface (API) lacks reliable transcription identifiers, so the model field remains editable.
- Earlier duration trials used Opus, not AAC; AAC quality and long AAC requests still require checks.
- Raw tracks retain CAF if FLAC cannot preserve the samples exactly.
- Apple supplies no cancellation API for blocked capture calls, so those calls can defer resource cleanup.
- The 19 offline tests pass, and core line coverage exceeds the 70% target.
- The app guide includes a full checklist for permissions, progress, retries, and both bundle identities.
- If the FLAC encoder is unavailable, the app reports the WAV fallback in the transcript header.
- Capture lacks automatic recovery for device changes and drift correction between device clocks.
- Speaker labels identify voices within one request, not persistent people across recordings.
- The release app uses an ad-hoc signature and lacks notarization.

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
