# System audio tap experiment

Minimal macOS recorder using a global stereo Core Audio process tap. It captures
system playback, not the microphone, and writes an uncompressed PCM WAV. Playback
remains audible. No virtual driver is installed, no default device is changed,
and the tap and aggregate device are private and temporary.

Requires macOS 14.2 or later and Swift Command Line Tools. This build targets
Apple Silicon; no Xcode project or Swift Package is needed.

## Build

From the repository root:

```bash
cd experiments/system-audio
./build.sh
```

The script compiles with warnings treated as errors, assembles `praatvol.app`, and
ad-hoc signs it. Paths are relative to the script, so it can run from any working
directory. Both the standalone `tap` binary and `praatvol.app/` are ignored by Git.

The app bundle makes macOS attribute system-audio permission to the tool rather
than the launching terminal; an embedded plist in a bare binary is insufficient.

## Run and permissions

From `experiments/system-audio/`:

```bash
open -n -W praatvol.app --args --seconds 20 /tmp/system-audio.wav
```

`-n` launches a new instance; `-W` waits until it exits. `--seconds N` takes a finite positive number and
stops automatically after that recording interval, using the same cleanup path
as Ctrl+C. Launch and permission-prompt time are additional; WAV duration may
include a small amount of setup/stop buffering. There is no window or Dock icon.

Use an **absolute output path with `open`**: the app's working directory is not
the terminal's. Relative paths are resolved against the recorder's working
directory, and the final absolute path is logged. Existing WAV and log files
are overwritten. The destination directory must already exist.

On first use, macOS asks for system-audio recording permission for
**praatvol**. Allow it. The renamed bundle uses `com.praatvol.app`, so the
system-audio permission prompt appears once more for the new identity. If denied, enable the app in
**System Settings > Privacy & Security > Screen & System Audio Recording**
(or **System Audio Recording**, depending on macOS), then relaunch it.
Ad-hoc signing after a rebuild can cause macOS to request permission again.
No permission-reset command is documented because the `tccutil` service name
has not been verified. This experiment does not edit permission databases or
terminal bundles.

Omit `--seconds` to record until SIGINT:

```bash
open -n -W praatvol.app --args /tmp/system-audio.wav
```

Ctrl+C in the launching terminal does not reliably reach an app launched by
`open`; send SIGINT to the app's PID (or use the Python PoC, which does this):

```bash
kill -INT "$(< /tmp/system-audio.wav.pid)"
```

At startup the app writes `<out>.pid` with its own PID; it removes that file
on clean shutdown or reported setup failure. On the first captured buffer it
writes `<out>.start`, a Unix wall-clock float estimating the first sample time
(callback time minus buffer duration). No `.start` file is written if there
are no samples. Use a fresh output path for each run to avoid stale sidecars.

Because app stdout is not visible through `open`, inspect the sibling log:

```bash
less /tmp/system-audio.wav.log
```

It reports start, stop, errors, final path and file size, frame count, normalized
peak, whether all samples were zero, and whether the peak was near-zero
(`silent=true` for peak <= 0.00001). Zero frames are also reported as silent.
Silence alone cannot distinguish idle playback from permission denial.

Direct runs retain Ctrl+C handling, but may still inherit terminal permissions:

```bash
./tap /tmp/system-audio.wav
# Or stop automatically:
./tap --seconds 20 /tmp/system-audio.wav
```

Normal timed/SIGINT shutdown exits 0; setup, writing, inspection, logging, or
cleanup failures exit 1. `open -W` waits for termination but its exit status is
not the recorder's exit status; use the log to diagnose recording errors.

## Manual audio test

1. Run `system_profiler SPAudioDataType` and note the default output.
2. Play music through that device and leave it playing.
3. Run `open -n -W praatvol.app --args --seconds 20 /tmp/system-audio.wav` and allow the
   one-time system-audio permission prompt if shown.
4. After the command returns, inspect the log and listen:

   ```bash
   less /tmp/system-audio.wav.log
   afinfo /tmp/system-audio.wav
   afplay /tmp/system-audio.wav
   ```

5. Confirm audible music and `all-zero=false, silent=false` in the log.
6. Run `system_profiler SPAudioDataType` again: the default output should be
   unchanged and no `praatvol private capture` aggregate device should remain.

## Python PoC integration

Build this helper, then run `python record_and_transcribe.py --system-audio`
from `experiments/poc/`. The PoC launches `praatvol.app` via `open`, captures the
mic separately, stops both on Ctrl+C, aligns and mixes with numpy, and sends the
mixed FLAC to OpenRouter. Both separate tracks are kept. The Python mixer accepts
any tap sample rate/channel count; the mic uses the current default input unless
selected with `--mic NAME`, and `--list-devices` lists inputs and defaults without
recording. See [the PoC README](../poc/README.md).

**Use headphones for calls.** With speakers, the mic also picks up the remote
voices, so they appear twice with a small delay, which can confuse speaker labels.

## Verification on the development machine

The renamed app rebuilt with zero warnings; shell syntax, plist validation and
strict signature verification passed. Two roughly ten-second live Python
dual-capture runs stopped via SIGINT, kept both raw tracks plus the mono mixed
FLAC, removed the PID sidecar and left no helper process. Idle playback produced
zero frames and correctly warned about silence. With a generated tone playing,
the system track captured 9.568 s of 48 kHz stereo Float32 audio (peak 0.153),
the microphone captured 9.216 s, and the mixed 16 kHz mono PCM_16 FLAC was
9.673 s (peak 0.218). The system start-time sidecar was written. No live
transcription was attempted; real-call quality remains unverified. Synthetic
tests verified alignment for both start-offset directions, padding and no clipping.

The following non-silent standalone results predate the bundle rename:

- `./build.sh` compiled with zero warnings; plist validation, shell syntax
  validation, and `codesign --verify --strict` passed.
- The previous helper's five-second `open -W` test returned automatically while
  a generated 440 Hz tone played through `afplay`.
  TCC logs confirmed a prompt for the previous bundle ID, followed by
  `Allowed (User Consent)`. The command runner cannot view or click that prompt.
- The WAV was **2,015,232 bytes**. `afinfo` reported **5.237333 seconds**, **48 kHz,
  stereo, Float32 interleaved PCM**, 251,392 frames and 2,011,136 audio bytes.
  The log reported `peak=0.25000393, all-zero=false, silent=false`.
  Independent sample inspection found RMS 0.17676071: **non-silent system audio
  was captured**. The final rebuilt app passed the same five-second test.
- Direct-run SIGINT exited 0 and finalized an idle, zero-frame WAV; relative
  output paths were logged as absolute. Invalid arguments were rejected.
  Initial path assertions confused `/tmp` with its `/private/tmp` alias; after
  comparing resolved paths, the runtime checks passed.
- Audio-device reports before and after all runs were identical: MacBook Pro
  Speakers remained the default output and default system output, no aggregate
  device remained, and cleanup reported no errors.
- No project lint/test commands were detected; compiler warning checks, plist
  and shell validation, signature verification, and runtime checks were used.

## Known limits

- Global stereo mix only: no per-app selection, separate tracks, or speaker labels.
- The helper itself has no microphone, transcription or compression; the Python
  PoC provides these through the optional dual-capture mode.
- Permission denial can yield silence even when every Core Audio call succeeds.
- Without playback, the tap may deliver no frames; start playback before judging
  capture success.
- WAV grows quickly (about 1.4 GB/hour at the tested format); no splitting or
  large-file support is implemented. Stop before approaching WAV's 4 GB limit.
- Synchronous file writing on the serial audio callback queue is suitable for a
  small experiment, not a drop-out-resistant production recorder.
- Stop before switching output devices; device-change recovery is not implemented.
  The tap reads its format once at startup, has no device-change listener and does
  not log routing changes explicitly. A change (including a Bluetooth call-mode
  transition) may stop callbacks or cause a logged write error; this expectation
  comes from code inspection, not a live switching test. The Python PoC warns on
  errors, silence or a system track ending over five seconds before the mic,
  retains readable audio and pads the remainder when mixing. Idle playback can
  also produce that warning; a missing/unreadable WAV cannot be mixed.
- Clean shutdown is implemented for Ctrl+C, timed completion, and reported
  errors, not SIGKILL, crashes, or termination during setup. Private objects are
  process-scoped and nonpersistent, but forced termination may leave an
  unfinalized WAV.
- Record other people's audio only with appropriate consent.
