# System audio helper

The helper captures system playback through a global Core Audio process tap. The helper leaves playback audible and uses no virtual drivers. The helper leaves the default device unchanged and creates private, temporary capture objects.

The helper writes uncompressed pulse-code modulation (PCM) in Waveform Audio File Format (WAV). The helper does not capture microphone audio or transcribe speech. The Python proof of concept (PoC) adds those features.

The helper requires macOS 14.2 or later and the Apple Command Line Tools. The build targets Apple Silicon through `swiftc`, without an Xcode project or Swift package.

## Build

Run the build from the repository root:

```bash
experiments/system-audio/build.sh
```

The script treats compiler warnings as errors, creates `praatvol.app`, and signs the app with an ad-hoc signature. The build script resolves paths relative to the script. Git ignores the standalone `tap` binary and `praatvol.app`.

The app bundle gives macOS a separate identity for system-audio permission. A bare executable can inherit the terminal's identity, which can cause silent capture despite successful Core Audio calls.

## Run and permissions

Run commands below from `experiments/system-audio/`.

Capture 20 seconds of system audio:

```bash
open -n -W praatvol.app --args --seconds 20 /tmp/system-audio.wav
```

`-n` starts a new app instance. `-W` waits for the app to exit. The helper has no window or Dock icon.

`--seconds N` requires a finite positive number. The helper stops after the capture interval and performs cleanup. Launch time and permission prompts add time before capture. The WAV duration can include a small amount of setup and stop buffering.

Use an absolute output path with `open`. The app's current directory differs from the terminal's current directory. The helper resolves relative paths against the app's current directory and reports the absolute path in the log.

Create the destination directory before capture. Use a fresh output path for each run to avoid stale sidecar files. If the WAV or log already exists, the helper overwrites that file.

On first use, macOS asks for system-audio access for **praatvol**. Allow access at the prompt. The bundle identity is `com.praatvol.app`; the new identity requires permission even if the previous helper had permission.

If you denied access, enable **praatvol** in **System Settings > Privacy & Security > Screen & System Audio Recording**. Some macOS versions name the panel **System Audio Recording**. Relaunch the helper after the change.

A rebuild and a new ad-hoc signature can trigger another permission prompt. The helper leaves permission databases and terminal bundles unchanged.

### Stop an indefinite capture

Omit `--seconds` to capture until an interrupt signal (SIGINT):

```bash
open -n -W praatvol.app --args /tmp/system-audio.wav
```

Ctrl+C in the terminal does not reliably reach the app through `open`. From another terminal, send SIGINT to the process identifier (PID):

```bash
kill -INT "$(< /tmp/system-audio.wav.pid)"
```

The helper writes `<output>.pid` at startup. The helper removes the file after normal shutdown or a reported setup failure.

At the first audio buffer, the helper writes `<output>.start` with an estimate of the first sample's Unix timestamp. The estimate subtracts buffer duration from callback time. If the helper receives no samples, the helper creates no `.start` file.

### Logs and direct use

Inspect the log beside the WAV:

```bash
less /tmp/system-audio.wav.log
```

The log reports capture times, errors, the output path, size, frame count, normalized peak, and silence. The helper marks a peak at or below 0.00001 as `silent=true`. Zero frames also count as silence. Silence alone cannot distinguish idle playback from denied permission.

A direct run accepts Ctrl+C but can inherit terminal permissions:

```bash
./tap /tmp/system-audio.wav
```

A direct run also accepts a duration:

```bash
./tap --seconds 20 /tmp/system-audio.wav
```

Normal timed shutdown and SIGINT exit with status zero. Reported setup, file, log, or cleanup failures exit with status one. The `open -W` exit status does not report the helper's exit status. Inspect the log for capture errors.

## Manual audio test

1. Inspect the default output:

   ```bash
   system_profiler SPAudioDataType
   ```

2. Play music through the default output.
3. Start the timed capture:

   ```bash
   open -n -W praatvol.app --args --seconds 20 /tmp/system-audio.wav
   ```

4. Allow access if macOS displays the prompt.
5. After capture ends, inspect the log:

   ```bash
   less /tmp/system-audio.wav.log
   ```

6. Inspect the WAV format:

   ```bash
   afinfo /tmp/system-audio.wav
   ```

7. Listen to the WAV:

   ```bash
   afplay /tmp/system-audio.wav
   ```

8. Confirm audible music and `all-zero=false, silent=false` in the log.
9. Inspect the devices again:

   ```bash
   system_profiler SPAudioDataType
   ```

10. Confirm that the default output remains unchanged.
11. Confirm that no `praatvol private capture` aggregate device remains.

## Python PoC integration

Build the helper before the first system-audio capture. From the repository root, activate the PoC virtual environment:

```bash
source experiments/poc/.venv/bin/activate
```

Capture microphone audio and system audio:

```bash
python experiments/poc/record_and_transcribe.py --system-audio
```

The PoC launches `praatvol.app` through `open` and captures the microphone separately. Ctrl+C stops both tracks. The Python mixer aligns the tracks and keeps both separate tracks.

The mixer also writes a lossless Free Lossless Audio Codec (FLAC) archive. The default upload uses Opus at a bitrate that depends on duration. `--lossless` sends FLAC instead. Both formats use the guard for the estimated request body.

The mixer accepts different tap rates and channel counts. The microphone uses the default input unless you select `--mic NAME`. `--list-devices` lists inputs and defaults without capture.

Use headphones for calls. Speakers also send remote voices into the microphone track, which duplicates voices and can confuse speaker labels.

See [the PoC guide](../poc/README.md) for setup, upload limits, and every flag.

## Verification on the development machine

The renamed app compiled with zero warnings. Shell syntax checks, property-list validation, and strict signature verification passed.

Two live captures through Python lasted about ten seconds each. Both captures stopped through SIGINT, retained all three audio files, removed the PID file, and left no helper process.

Idle playback produced zero frames and a silence warning. With a generated tone, the system track captured 9.568 seconds at 48 kilohertz (kHz), stereo, with peak 0.153. The microphone captured 9.216 seconds. The mixed FLAC contained 9.673 seconds at 16 kHz, mono, with peak 0.218.

The helper wrote the start timestamp. Synthetic tests confirmed alignment for both offset directions, end padding, and peak limits. Those checks used no paid transcription request. Real-call quality still needs a manual check.

Earlier standalone tests confirmed these results before the bundle rename:

- A five-second capture produced non-silent audio with peak 0.25000393.
- The WAV contained 5.237333 seconds at 48 kHz, stereo, with 32-bit floating-point samples.
- Direct SIGINT shutdown finalized an idle WAV and returned status zero.
- The helper rejected invalid arguments and reported absolute output paths.
- Reports of devices before and after capture matched, and cleanup reported no errors.

## Known limits

- The helper captures global playback and lacks selection of individual apps.
- The helper lacks microphone capture, compression, and speaker labels; the PoC supplies those features.
- Denied permission can produce silence despite successful Core Audio calls.
- If playback is idle, the tap can supply no frames.
- WAV grows quickly: about 1.4 gigabytes (GB) per hour at the tested format.
- Stop before the WAV approaches 4 GB; the helper lacks file splitting and explicit support for larger files.
- The helper writes synchronously on the audio callback queue; the helper does not guarantee capture without dropped audio.
- Stop capture before you change output devices; the helper lacks recovery for device changes.
- The helper reads the format once at startup and lacks a listener for device changes.
- A device change can stop callbacks or produce a write error; no live test verifies that behavior.
- Python warns about helper errors, silence, and a system track that ends over five seconds before the microphone.
- The mixer retains readable audio and adds silence at the end; an absent or unreadable WAV causes failure.
- Normal cleanup covers timed shutdown, SIGINT, and reported errors, but excludes crashes and forced termination.
- Forced termination can leave an unfinished WAV, although capture objects remain private and process-scoped.
- Obtain appropriate consent before capture.
