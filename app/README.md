# praatvol 0.1

praatvol is a native macOS app for room recordings, calls, and audio files.
The app uses Apple frameworks and OpenRouter for batch transcription with speaker labels.
The app requires macOS 14.2 or later on Apple Silicon.
The app requires no Python, virtual drivers, or local models.
Version 0.1.0 is an early release.

## Build and install

Install the Apple Command Line Tools:

```bash
xcode-select --install
```

Build the dev app from the repository root:

```bash
app/scripts/build.sh dev
```

Open the dev app:

```bash
open "app/dist/praatvol Dev.app"
```

Build the release app:

```bash
app/scripts/build.sh release
```

Drag `app/dist/praatvol.app` into `/Applications`.
Open `/Applications/praatvol.app` through Finder.
The release script also creates `app/dist/praatvol-0.1.0.dmg` and `app/dist/praatvol-0.1.0.zip`.
The file `app/VERSION` supplies the bundle version.

The scripts use Swift Package Manager (SwiftPM) and Swift 6 from the Command Line Tools.
The scripts generate the icons with AppKit, `sips`, and `iconutil`.
The scripts apply and verify ad-hoc signatures.
The app lacks Developer ID certification and notarization.

If Gatekeeper blocks the app, verify the source of the app.
Open **System Settings > Privacy & Security**.
Select **Open Anyway** for praatvol.
Confirm **Open** at the next prompt.

## First launch and permissions

Use the app bundle rather than the bare SwiftPM executable.
macOS assigns capture permission to the responsible app.
The bundle supplies the required descriptions for capture permissions.

Allow notifications at the prompt.
Open **Settings…** from the sine-wave icon.
Enter your OpenRouter application programming interface (API) key.
Select **Save**.

Select **Record room** for microphone capture.
Select **Record call** for microphone and system audio capture.
Allow microphone access at the prompt.
For a call, allow system audio access at the prompt.

Check these sections under **System Settings > Privacy & Security**:

- **Microphone** permits microphone capture.
- **Screen & System Audio Recording**, or **System Audio Recording**, permits playback capture.
- **Files and Folders** permits access to Documents if macOS requests access.

Allow banners under **System Settings > Notifications > praatvol**.
If notifications lack permission, the app reveals the saved folder in Finder.
A failure also produces an alert if notifications lack permission.

## Menu

The top line shows Idle, the recording timer, upload percent, or the current step.
During recording, filled signal dots indicate recent sound from the microphone and system audio.
Empty signal dots indicate silence or absent callbacks.
The red sine-wave icon and timer identify active recording.
The dev icon also has a D marker.

### Record call

Select **Record call (mic + system audio)**.
Use headphones to prevent duplicate remote voices in the microphone track.
The app captures all system playback, not only Teams.
The app leaves audio routing unchanged.

The app requests microphone permission before capture setup.
The app starts the microphone before the system tap.
Capture setup runs outside the main thread.
**Stop / Cancel setup** appears immediately after the start action.
An eight-second watchdog reports a clear permission error if setup exceeds the limit.

Apple supplies no cancellation API for a blocked capture call.
The watchdog cancels the job without a blocked interface.
The capture queue removes the tap and private device after the blocked call returns.
If the operating system never returns from the call, quit and relaunch the app after permission approval.

### Record room

Select **Record room (mic only)**.
The app uses the microphone from Settings.
The app preserves the microphone track before any conversion.

### Stop recording

Select **Stop recording** to stop capture and request a transcript.
The main window also offers a Stop button.
During setup, select **Stop / Cancel setup** to cancel without a paid request.

The app processes one item at a time.
Other capture and import actions remain unavailable until the current item completes.
Settings and Finder remain available.

### Transcribe file

Select **Transcribe file…**.
Choose an audio file that AVFoundation can read.
The app opens the main window and gives the main window focus after file selection.
The app preserves the original bytes before conversion.
The item date records the import time, not the source capture time.

Examples include these formats:

- MPEG-4 Audio (M4A).
- MPEG Audio Layer III (MP3).
- Waveform Audio File Format (WAV).
- Core Audio Format (CAF).
- Free Lossless Audio Codec (FLAC).
- Advanced Audio Coding (AAC).

A lossless archive preserves decoded samples but cannot restore detail from a lossy source.

### Open praatvol

Select **Open praatvol…** to open the main window with focus.
The app also opens the main window when a recording starts, without a focus change.
Close the main window to keep the app in the menu bar.

### Recent

Open **Recent** to see the five newest transcribed items.
Select an item to open its transcript in the default editor.
If the submenu has no items, complete a transcription first.

### Open transcripts in Finder

Select **Open transcripts in Finder** to open the data root.
Each item has a separate dated folder.
Open `transcript.md` with a Markdown editor or a text editor.

### Settings

Select **Settings…**.
The settings affect the next item, not an active item.

- The masked key field stores the OpenRouter key in macOS Keychain.
- The model field accepts a transcription model identifier.
- The default model is `elevenlabs/scribe-v2`.
- The microphone picker lists the system default and available inputs.
- **Send lossless** sends the archive instead of the AAC copy.
- **Launch at login** uses Service Management for an installed app.

The public OpenRouter models API lacks a reliable list of transcription models.
The editable model field therefore offers Scribe as a suggestion.
The app requests ElevenLabs diarization only for model identifiers under `elevenlabs/`.
Other models can return transcripts without speaker labels.

The app keeps the key out of preferences, logs, transcripts, and audio files.
The app keeps the key only in Keychain and transient memory.
Text fields support Command-X, Command-C, Command-V, and Command-A.
If macOS requires login approval, allow the app under **System Settings > General > Login Items**.
The app unregisters login access only if a registration exists.

### Quit

Select **Quit** to close the app.
During recording, confirm **Save and quit** to save audio without a paid request.
During setup, Quit cancels setup.
Select Quit again after cancellation to close the app.
During audio preparation or transcription, wait for the current job before Quit.

## Main window

The main window uses native controls and materials in dark and light modes.
The sine-wave brand identifies the app.
The **Now** panel shows the current item and its steps.

### Starting

The app requests permissions and starts capture.
The panel offers **Cancel setup** throughout this step.
A timeout appears in the panel without a blocked interface.

### Recording

The panel shows these details:

- A large elapsed timer.
- Separate microphone and system meters for calls.
- Root mean square (RMS) levels, peaks, and decibels relative to full scale (dBFS).
- A per-track warning after three seconds without signal.
- The current file size on disk.
- The duration tier for the default AAC upload.
- A Stop button.

The app updates the meters about ten times per second.
The signal threshold identifies sound, not speech.
Room noise can therefore produce a signal indication.
Idle system playback can produce a silence warning without a permission fault.

### Preparing audio

The panel identifies conversion, the mix, normalization, archive creation, raw compression, and AAC encoding.
A progress bar shows the fraction for the current measurable operation.
The progress bar restarts for each operation, rather than a false estimate for the entire stage.
The original copy and some file checks have no measurable fraction.

The app averages channels and converts the transcript audio to mono at 16 kilohertz (kHz).
The app aligns call tracks with their first sample timestamps.
The app limits the mixed peak to 0.95 before the archive stage.

### Uploading

The panel shows the audio format, audio size, request size, sent bytes, and percent.
The upload bar uses `URLSessionTaskDelegate` callbacks from the real request.
The request size includes base64 expansion and JavaScript Object Notation (JSON) metadata.

### Transcribing

The panel shows an indeterminate indicator, elapsed seconds, and an estimate for the total time.
Earlier trials measured about 68 seconds for 60 minutes and 88 seconds for 90 minutes.
The estimate interpolates those trials, which used Opus rather than AAC.
The estimate does not guarantee provider latency.

### Saved or Failed

A saved item shows its duration, speaker count, word count, reported cost in United States dollars (USD), and model.
Select **Open transcript** to open the Markdown file.
Select **Show in Finder** to reveal the saved folder.

A failed item shows the error message.
The app preserves the local audio.
The panel offers **Retry…** if the saved item has usable audio.
The Retry action uses the same confirmation as **Transcribe again…** in the library.

## Library and retry

The library scans the data root at launch, after a job, and when you open the main window.
The library lists the newest items first.
Each row shows the date, Call/Room/File kind, source name for files, duration, speakers, cost, and status.

The library uses these statuses:

- **Transcribed** means the transcript exists and the metadata has no failure status.
- **Failed** means the item metadata records a failure.
- **Not transcribed** means the item lacks a transcript and has no failure status.

Select **Open transcript** to open a completed transcript.
Select **Show in Finder** to reveal an item folder.
For failed or untranscribed audio, select **Transcribe again…** to request another transcription.
Confirm **Transcribe again** before the app sends a paid request.

Check your OpenRouter account after an ambiguous timeout before another request.
A failed request can still incur a charge.
The app sends exactly one paid request per confirmed attempt.
The app never retries a paid request automatically.

Retry prefers the saved archive, then the upload copy, then the raw microphone or original file.
If retry uses raw call tracks, the app mixes both tracks with the saved offset.
The app keeps retries in the same item folder and uses the current settings.
The library reads `item.json` rather than Markdown.
Older folders remain visible with limited metadata and no invented cost.
A malformed metadata file produces a visible library error.

## Storage

The release root is `~/Documents/praatvol/`.
The dev root is `~/Documents/praatvol-dev/`.
Folder names use the local date and time.

```text
praatvol/
  YYYY/MM/DD/HH-mm-ss Call/
    item.json
    transcript.md
    transcript.json
    transcript-error.json  # only after an API failure with a response body
    audio.flac
    upload.m4a
    mic.flac
    system.flac
  YYYY/MM/DD/HH-mm-ss Room/
    item.json
    audio.flac
    upload.m4a
    mic.flac
  YYYY/MM/DD/HH-mm-ss File: original-name.m4a/
    item.json
    audio.flac
    upload.m4a
    original.m4a
```

`item.json` stores the date, kind, sources, duration, status, error, model, cost, speakers, words, and track offset.
`transcript.json` contains the successful raw response.
`transcript-error.json` contains a failed raw response, including malformed JSON or an error inside a successful protocol response.
A network failure without a response body cannot produce a raw response file.
The app records that failure in `item.json` instead.

The Markdown header includes source details, upload details, timestamps, speakers, model, and cost.
The app groups consecutive words from one speaker into a turn.
If the provider omits speaker labels, the transcript uses Speaker ?.

The archive uses FLAC at 16 kHz mono.
If the Apple FLAC encoder fails, the archive uses lossless WAV.
The transcript header reports the fallback.

Raw tracks start as CAF files at the native sample rate and channel count.
After Stop, the app attempts FLAC compression at the native format with 24-bit samples.
The app verifies the format, frame count, and every decoded sample before CAF removal.
If encoding or exact verification fails, the app keeps the CAF and reports the reason before upload.
Some floating-point tracks cannot fit losslessly into integer FLAC samples.
Those tracks retain CAF rather than lose sample detail.

The app keeps partial audio after failures.
Hidden CAF files can remain after an incomplete conversion.
Keep those files until you inspect the saved audio.

Logs contain fixed event names and numeric codes, without keys or transcript content.
The release log is `~/Library/Logs/praatvol/app.log`.
The dev log is `~/Library/Logs/praatvol-dev/app.log`.

## Upload limits and privacy

The default upload uses mono AAC at 22.05 kHz in `upload.m4a`.
The encoder uses a constant bitrate strategy with these targets:

| Duration | Target |
|---|---:|
| Up to 60 minutes | 64 kilobits per second (kbps) |
| Over 60 minutes, up to 90 minutes | 48 kbps |
| Over 90 minutes | 32 kbps |

If the duration exceeds 90 minutes, review the timeout warning before approval.
Earlier duration trials used Opus, not AAC.
Long AAC uploads and AAC quality still require real checks.

The app rejects estimated and complete base64 request bodies above 50,000,000 bytes.
Lossless uploads reach the limit sooner than AAC uploads.
The app keeps the local audio after a size rejection.
The client allows 180 seconds for the request.
The app treats an error key inside Hypertext Transfer Protocol (HTTP) 200 as failure.

Obtain appropriate consent before capture.
Keep audio and transcripts private.
OpenRouter and the selected provider receive your audio.
Speaker letters identify voices within one request, not real names or identities across items.

## Dev and release separation

| Property | Dev | Release |
|---|---|---|
| App name | praatvol Dev | praatvol |
| Bundle identifier | `com.praatvol.app.dev` | `com.praatvol.app` |
| Data root | `~/Documents/praatvol-dev/` | `~/Documents/praatvol/` |
| Keychain service | `com.praatvol.app.dev` | `com.praatvol.app` |
| Preferences | Dev bundle domain | Release bundle domain |
| Icon | Purple wave and D marker | Green wave |

The apps use separate permissions, keys, preferences, logs, and data.
A repository build does not replace the installed release app.
Copy the new release bundle into Applications only if you want an installed update.

## Troubleshooting

### Start timeout

If setup exceeds eight seconds, inspect the permission named in the Now panel.
Approve the pending macOS prompt.
Check **System Settings > Privacy & Security**.
Relaunch the app after a permission change.
Retry **Record room** before **Record call** to isolate microphone access.
If setup remains blocked, quit and relaunch the app.
Apple capture calls can defer cleanup until the permission flow returns.

### Silent or absent tracks

If microphone callbacks stop for five seconds, the app stops capture and preserves audio.
Check microphone permission.
Check **System Settings > Sound > Input**.
Select an available microphone in Settings.

If the system track stays silent, start playback.
Check system audio permission.
Inspect both raw tracks before another call.
Select **Keep audio only** at the warning to inspect audio without a paid request.

Stop capture before you change audio devices.
The app lacks automatic recovery after an output change.
Alignment uses host timestamps but lacks drift correction between device clocks.
Hardware without host timestamps requires an approximate callback-time fallback.

### Reset permissions

Quit the affected app before a reset.
Reset microphone permission for the release app:

```bash
tccutil reset Microphone com.praatvol.app
```

Reset microphone permission for the dev app:

```bash
tccutil reset Microphone com.praatvol.app.dev
```

If system audio access remains denied, reset all privacy grants for the affected bundle:

```bash
tccutil reset All com.praatvol.app
```

Use `com.praatvol.app.dev` instead for the dev app.
The All reset clears other privacy grants for that bundle too.
Relaunch the app.
Approve the prompts again.
Transparency, Consent, and Control (TCC) service names for system audio vary across macOS versions.

### Transcription failures

If OpenRouter rejects the key, save the correct key in Settings.
Select **Transcribe again…** for the failed item.
If the size guard rejects the request, turn off **Send lossless** or select a shorter file.
If a provider failure occurs, inspect `transcript-error.json` locally.
Keep the response file private because the response can contain transcript content.
If the provider omits labels, select Scribe for the next item.

## Offline validation

Run the tests with coverage:

```bash
cd app
swift test --enable-code-coverage
```

Report coverage for the core library:

```bash
xcrun llvm-cov report \
  .build/arm64-apple-macosx/debug/PraatvolPackageTests.xctest/Contents/MacOS/PraatvolPackageTests \
  -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata \
  Sources/PraatvolCore/*.swift
```

Check compiler warnings:

```bash
swift build -Xswiftc -warnings-as-errors
```

The suite uses Swift Testing and synthetic audio without network requests.
The suite covers state transitions, progress, estimates, meters, library metadata, retry rules, request bodies, codecs, and raw verification.
The current suite has 19 tests with 36 cases, including parameter sets.
The `app/scripts/coverage.sh` script reports the core line coverage and fails below 70%.
The job and meter tests preceded the corresponding core code.
The raw compression tests followed the encoder implementation.
Capture, permissions, notifications, and login access require a real desktop session.

## Manual test checklist

- Start a room recording with microphone permission unset.
- Confirm immediate Stop and a responsive menu during the prompt.
- Leave the prompt pending for eight seconds.
- Confirm the timeout names the required permission.
- Approve the prompt and confirm cleanup before another capture.
- Cancel setup and confirm no paid request occurs.
- Record a call with headphones and a separate microphone.
- Confirm both meters, silence warnings, timer, and file size.
- Confirm the main window opens without a focus change during recording.
- Stop capture and confirm each preparation operation appears.
- Confirm the upload bar shows actual bytes and percent.
- Confirm elapsed seconds and the estimate during transcription.
- Confirm the saved summary matches the transcript header.
- Inspect raw FLAC files or the stated CAF fallback.
- Import an M4A file and a WAV file.
- Confirm the original bytes and each progress step.
- Record without a saved key and confirm a failed library item.
- Save the key and confirm a successful manual retry.
- Test an invalid key and inspect the saved raw error response.
- Restart the app and confirm library order, statuses, Recent, Open, and Finder actions.
- Check dark mode and light mode.
- Paste a key into Settings and confirm Command-V works.
- Save Settings with launch at login disabled for a repository build.
- Quit during capture and confirm local audio without a paid request.
- Launch dev and release together and confirm separate keys, settings, data, and permissions.
- Assess AAC quality and speaker accuracy before a long real meeting.
