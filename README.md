# praatvol

praatvol is a native macOS menu bar app for room and call transcripts.
The app records your microphone and optional system audio, then transcribes the audio through OpenRouter.
Each transcript includes timestamps, speaker turns, source details, and the reported cost.
The app also imports audio files from other devices.

## Status

Version **0.1.0** is an early release and targets macOS 14.2 or later on Apple Silicon.
The app builds with Swift 6 and the Apple Command Line Tools, without Xcode or external packages.
Capture permissions and real-call quality still require manual checks.

## Install

1. Download `praatvol-0.1.0.dmg` from the [releases page](https://github.com/Max0xDay/praatvol/releases).
2. Open the disk image and drag `praatvol.app` onto the **Applications** shortcut.
3. Control-click `praatvol.app` and select **Open** on the first launch, because the app has no notarization.
   On macOS 15 or later, select **Open Anyway** in **System Settings > Privacy & Security** instead.
4. Open **Settings…** from the sine-wave icon and enter your OpenRouter key.

## Quick start

Build the dev app from the repository root:

```bash
app/scripts/build.sh dev
```

Open the dev app:

```bash
open "app/dist/praatvol Dev.app"
```

Open **Settings…** from the sine-wave icon.
Enter your OpenRouter application programming interface (API) key.
Select **Save**.
Select **Record room** or **Record call**.
Allow the requested macOS permissions.
Select **Stop recording** to save the audio and request a transcript.
Select **Open praatvol…** to open the two-pane main window.
Select **Now** in the sidebar to inspect a live job.
Select an item in the sidebar to open the detail view.
For a key failure, save the key again in Settings.
Select **Transcribe Again…** for the failed item.
Confirm the new paid request before retry.

Build the release app:

```bash
app/scripts/build.sh release
```

Drag `app/dist/praatvol.app` into `/Applications`.
The script also creates `app/dist/praatvol-0.1.0.dmg` and `app/dist/praatvol-0.1.0.zip` for distribution.
The app uses an ad-hoc signature, not notarization.
See [the app guide](app/README.md) for Gatekeeper steps, permissions, settings, storage, and tests.

## Features

- A sine-wave icon, status line, signal dots, and elapsed timer identify active capture.
- The two-pane main window places the sidebar on the left and the detail view on the right.
- The toolbar offers Record Call, Record Room, Import Audio, and Settings.
- A red Cancel or Stop button replaces the capture and import buttons during setup or recording.
- The live view shows level bars, file size, upload tiers, preparation progress, upload percent, and transcription estimates.
- The sidebar groups transcribed items and failed items by day, newest first.
- Unfinished attempts without a transcript or failure stay on disk and remain accessible through Finder.
- The detail view shows transcript statistics, a preview with speaker labels, or a failure summary with a fix.
- Calls and rooms show their kind and start time; imported files show the file name without the extension.
- Rename stores a custom title without a folder name change, and Recent shows titles and dates.
- Copy Transcript copies the complete Markdown text to the clipboard.
- Move to Trash asks for confirmation and moves the whole item folder to the macOS Trash for restoration.
- The app protects the item of the active job from Move to Trash.
- Item menus offer transcript access, rename, Finder access, and confirmed manual retry for failed items with usable audio.
- The start watchdog reports permission errors without a blocked interface.
- Cancel remains available throughout capture setup.
- A call uses the microphone and an in-process tap through Core Audio.
- A room uses only the microphone.
- The app supports separate devices for input and output without virtual drivers.
- The app keeps separate raw tracks and a lossless archive.
- Advanced Audio Coding (AAC) uploads use duration-based target bitrates in an MPEG-4 Audio (M4A) file.
- Small files can use lossless uploads instead.
- The app sends one paid request through OpenRouter and never retries automatically.
- Settings store the key in macOS Keychain and offer a model field and a microphone picker.
- If a rebuild blocks Keychain access, the app asks you to save the key again in Settings.
- Settings replaces an inaccessible Keychain item from an earlier build when you save the key again.
- A completion notification opens the transcript when you click the notification.
- Each dated folder contains Markdown transcripts and raw JavaScript Object Notation (JSON) responses.
- The app saves failed response bodies and per-item metadata for the library.
- Dev and release apps use separate identities, settings, keys, data, and logs.

The release app stores items under `~/Documents/praatvol/YYYY/MM/DD/HH-mm-ss <kind>/`.
The dev app uses `~/Documents/praatvol-dev/` instead.
Select **Open transcripts in Finder** to browse the folders.

## Limits and privacy

Obtain appropriate consent before capture.
OpenRouter and the selected provider receive your audio.
Keep recordings and transcripts out of Git.
Speaker letters identify voices within one request, not real names or persistent identities.

The default model is `elevenlabs/scribe-v2`.
Other transcription models can omit speaker labels.
The public models API lacks reliable transcription identifiers, so the model field remains editable.

The app keeps a Free Lossless Audio Codec (FLAC) archive if Apple's encoder supports FLAC.
Otherwise, the app keeps a lossless Waveform Audio File Format (WAV) archive and reports the reason.
Raw tracks start in Core Audio Format (CAF) at their native formats.
After Stop, the app compresses raw tracks to FLAC and verifies every sample before CAF removal.
If encoding or exact verification fails, the app retains the CAF rather than lose sample detail.
Apple capture calls can defer cleanup until a blocked permission flow returns.

The AAC targets are 64 kilobits per second (kbps) through 60 minutes and 48 kbps through 90 minutes.
Beyond 90 minutes, the app targets 32 kbps and asks you to review the timeout warning.
Earlier duration trials used Opus; long AAC requests and AAC quality still require checks.
The app guards the full base64 request body at 50,000,000 bytes.
The app preserves local audio after a failure.

Stop capture before you change audio devices.
The app lacks automatic recovery for output changes and drift correction between device clocks.
See [the app guide](app/README.md#manual-test-checklist) for the manual checklist.
See [the limits experiment](experiments/limits-test/README.md) for the earlier request trials.

## Legacy CLI (experiments)

The command-line interface (CLI) from **beta-0.0.1** remains under `experiments/poc/`.
The Python beta uses a separate app helper and Opus uploads.
See [the legacy guide](experiments/poc/README.md) for setup and commands.
The native app requires no Python environment.

## Contributing and CI

Continuous integration (CI) checks each pull request into `main`.
The workflow file is `.github/workflows/ci.yml`.

### Branch flow

1. Create a branch named `task/<name>` from `main`.
2. Commit your changes to that branch.
3. Open a pull request from the branch into `main`.
4. Fix any failed check and push again.

### Checks

The workflow runs three checks.
Each check name matches a job name:

- `branch-name` fails if the branch name does not start with `task/`.
- `lint` fails on any Swift format warning in `app/Sources` and `app/Tests`.
- `build-test` fails on a build error, a test failure, a core line coverage below 70%, or an app build error.

The `branch-name` check checks the name only on pull requests.
On pushes to `main`, the check reports success without checking the name.

### Run the checks locally

Run these commands from the repository root.

Check the Swift format rules:

```bash
swift format lint --strict --recursive app/Sources app/Tests
```

Fix the format warnings:

```bash
swift format format --in-place --recursive app/Sources app/Tests
```

Run the tests and the coverage gate:

```bash
app/scripts/coverage.sh
```

The script prints the `PraatvolCore` line coverage and fails below 70%.

Build the package:

```bash
cd app && swift build
```

Build the dev and release apps:

```bash
app/scripts/build.sh dev
app/scripts/build.sh release
```

The file `app/.swift-format` sets the indentation and line length for all format commands.

## Repo layout

- `app/` contains the production Swift package, tests, scripts, and app guide.
- `app/Sources/PraatvolCore/` contains job states, progress math, meters, the library, upload rules, transcripts, and audio conversion.
- `app/Sources/Praatvol/` contains the main window, menu bar, capture, progress callbacks, settings, Keychain, and notifications.
- `experiments/poc/` contains the legacy beta and its offline tests.
- `experiments/system-audio/` contains the proven Swift helper for the legacy beta.
- `experiments/compression-quality/` compares upload codecs against a lossless reference.
- `experiments/limits-test/` tests request sizes and durations through OpenRouter.
- `experiments/speaker-continuity/` tests speaker labels across separate requests.

## Roadmap ideas

These ideas are unordered and are not commitments.

- Add a transcript viewer with speaker names and export to Word, plain text (TXT), and Portable Document Format (PDF).
- Browse transcripts by date and time range.
- Recognise the same people across recordings.
- Add web uploads for files from other devices.
- Search and summarise meetings with retrieval-augmented generation (RAG).
- Export transcripts to Teams and SharePoint.
