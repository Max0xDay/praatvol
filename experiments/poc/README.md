# PoC: record and transcribe (praatvol phase 0)

A single proof-of-concept script that:

1. Records the Mac's microphone until you press Ctrl+C.
2. Saves the audio as a 16 kHz mono FLAC in `recordings/`.
3. Sends the audio to OpenRouter's speech-to-text endpoint with `elevenlabs/scribe-v2`, with speaker diarization on.
4. Writes a timestamped, speaker-labelled transcript to `transcripts/`, plus the raw API JSON.

No ffmpeg required. macOS only. This is a throwaway experiment, not the product.

## Files

| File | Purpose |
|---|---|
| `record_and_transcribe.py` | The whole PoC: record, send, transcribe, write output |
| `requirements.txt` | Pinned Python dependencies |
| `.env.example` | Template for the OpenRouter API key |

Recording and transcript output (`recordings/`, `transcripts/`, `.env`) are gitignored.

## Setup

Requires Python 3.14 (the system Python works; verified on macOS 14 with Python 3.14.8).

```bash
cd experiments/poc
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### API key

Copy the template and paste your OpenRouter key into it:

```bash
cp .env.example .env
# then edit .env: OPENROUTER_API_KEY=your_key_here
```

You can also skip the `.env` file and export the key in your shell instead:

```bash
export OPENROUTER_API_KEY=your_key_here
```

Create a key in your OpenRouter account at https://openrouter.ai. The key is never stored anywhere else.

### Microphone permission (macOS)

macOS only lets apps record audio after you grant permission:

1. Open **System Settings > Privacy & Security > Microphone**.
2. Enable the toggle for your terminal app (Terminal, iTerm, VS Code, ...).
3. Quit and reopen the terminal — the permission only applies to new terminal sessions.

If recording fails or produces a silent file, this is almost always the cause.

## Usage

Record until Ctrl+C, then transcribe:

```bash
python record_and_transcribe.py
```

```
Recording... press Ctrl+C to stop
^C
Stopped. Saved 2026-10-08_14-03-22.flac (2 min 10 s)
Sending 2026-10-08_14-03-22.flac to OpenRouter (elevenlabs/scribe-v2)...
Transcription complete.
Wrote transcript: .../transcripts/2026-10-08_14-03-22.md
Wrote raw API JSON: .../transcripts/2026-10-08_14-03-22.json
```

### Audio devices and microphone selection

By default, recording uses the current macOS default input. It does not change
that input or the default output. List input devices and both defaults without
recording or needing an API key:

```bash
python record_and_transcribe.py --list-devices
```

Choose a microphone by a case-insensitive substring of its name:

```bash
python record_and_transcribe.py --mic "MacBook Pro Microphone"
python record_and_transcribe.py --system-audio --mic "MacBook"
```

The name must match exactly one input device. Missing or ambiguous matches fail
with a list of available inputs; use a longer substring to disambiguate. `--mic`
works with mic-only and dual capture, but not with `--file`.

The script first opens the selected mic at 16 kHz mono. If that fails, it retries
at the device's default sample rate, streams that rate to disk, and converts to
16 kHz after stopping. The five-second stall watchdog remains active during
startup and recording. Conversion uses numpy only and loads the fallback-rate
recording into memory. At startup it prints the mic name and actual capture rate;
with system audio it also prints the default output name, then reports the tap's
actual rate and channel count from the WAV header after stopping.

### Microphone + system audio (calls)

Build the native helper once from the repository root:

```bash
./experiments/system-audio/build.sh
```

Then, from `experiments/poc/` with the virtual environment active:

```bash
python record_and_transcribe.py --system-audio
```

The script launches `experiments/system-audio/praatvol.app` via `open -n -W`,
starts the microphone, and prints `Recording mic + system audio... press Ctrl+C to stop`.
Allow the macOS system-audio permission prompt for **praatvol**. Renaming the
bundle to `com.praatvol.app` triggers that prompt once more, even if you allowed
system capture for the previous helper. See [the helper README](../system-audio/README.md)
for permission troubleshooting. If its PID file does not appear within about
five seconds, recording fails with a pointer to the helper log; grant permission
and retry if necessary.

Ctrl+C stops both captures. Each run keeps:

- `<timestamp>_mic.flac`: separate 16 kHz mono microphone track (converted after
  stop if capture required the mic's default rate).
- `<timestamp>_system.wav`: raw system track at the tap's actual rate and channel count.
- `<timestamp>.flac`: aligned, mixed 16 kHz mono PCM_16 audio, sent to OpenRouter.
- `<timestamp>_system.wav.log` and `.start`: diagnostics and first-sample Unix time.
  The temporary `.pid` sidecar is removed when the helper exits.

Mixing accepts any system sample rate and channel count using only numpy:
average all channels to mono, apply a centered moving-average low-pass filter
whose length scales with the downsampling ratio, then interpolate onto the
16 kHz time grid. A 16 kHz track passes through; rates below 16 kHz use interpolation
without filtering. The same resampler converts fallback-rate microphone tracks.
Start timestamps align the tracks by padding the later-starting track; the shorter
track is padded at the end. The
sum is normalised only when needed to keep its encoded peak at or below 0.95.
The first-system-sample timestamp estimates buffer timing, so alignment is
approximate; device latency and clock drift are not corrected. Mixing loads the
raw tracks into memory, unlike 16 kHz mic-only capture, which streams to disk.
The existing 25 MB guard applies to the mixed FLAC. Transcripts include
a `- Sources:` line naming the mic and its capture rate, plus the startup default
output and the tap's actual rate/channels, for example:
`- Sources: mic: MacBook Pro Microphone (16000 Hz); system: USB Headset (24000 Hz, 1 channels)`.
The output name is a startup snapshot, not a routing history: the tap is global
and may include other outputs. Mic-only transcripts also show the mic name/rate;
existing-file transcripts do not infer device names. This mode cannot be combined
with `--file`.

**Use headphones for calls.** With speakers, the mic also picks up the remote
voices, so they appear twice with a small delay, which can confuse speaker labels.
Bluetooth headphones, USB headsets and the built-in mic can be combined freely;
there is no 48 kHz, stereo or wired-headphone requirement. For example, keep a
headset as the output while selecting the MacBook mic with `--mic "MacBook"`.
The helper captures all system playback, not just Teams. No drivers or audio
routing changes are required. If playback was idle or permission was denied,
the log's silence check triggers a warning; the microphone can still be transcribed.

Transcribe an existing audio file without recording again (useful for re-testing). Accepted formats are wav, flac, mp3, m4a and ogg:

```bash
python record_and_transcribe.py --file recordings/2026-10-08_14-03-22.flac
```

Set the maximum number of speakers (sent to ElevenLabs as `num_speakers`, an upper bound and not an exact count):

```bash
python record_and_transcribe.py --speakers 2
```

Try another OpenRouter speech-to-text model. Only `elevenlabs/scribe-v2` has its diarization option wired up; other models run without speaker labels and print a note:

```bash
python record_and_transcribe.py --model openai/whisper-large-v3 --file recordings/example.flac
```

Show all options:

```bash
python record_and_transcribe.py --help
```

## Size limit

OpenRouter accepts at most 25 MB per request. The script rejects a longer file before upload, with the message "recording too long for a single request — chunking not supported yet". Chunking is not implemented.

On speech recorded at 16 kHz mono FLAC, that is about 1.15 MB per minute, so **about 21 minutes per request**. Measured on a 2.3-minute synthetic speech sample; real recordings will vary. The cap is checked against the file size. OpenRouter might count the base64-encoded body, which is about 33% larger, in which case the limit is closer to 16 minutes. This is not confirmed yet.

## Cost

Each run's header shows the cost OpenRouter reports for that request (`- Cost: $X (OpenRouter)`). Costs are per second of audio, so a 2-minute recording costs about $0.004 at the listed ElevenLabs Scribe v2 rate. Check current prices on the model page: https://openrouter.ai/elevenlabs/scribe-v2

## Output format

Each run writes two files into `transcripts/`, named with the run timestamp
(`YYYY-MM-DD_HH-MM-SS.md` and `YYYY-MM-DD_HH-MM-SS.json`).

The Markdown file has a header and one line per speaker turn:

```markdown
# Transcript: 2026-10-08 14:03:22

- Source audio: 2026-10-08_14-03-22.flac
- Sources: mic: MacBook Pro Microphone (16000 Hz)
- Date/time: 2026-10-08 14:03:22
- Duration: 2 min 10 s
- Speakers: 2
- Cost: $0.002186 (OpenRouter)

[00:00] Speaker A: Good morning everyone, let's get started.
[00:07] Speaker B: Sounds good, I have two items on my list.
[00:15] Speaker A: Go ahead, I'll take notes.
```

Timestamps are `[mm:ss]` from the start of the audio (minutes keep counting past 59 on long
recordings). Speaker letters (`A`, `B`, ...) come from the diarization index and are per-recording,
not persistent identities. Consecutive words from the same speaker are joined into one line.
If no speaker labels come back, lines show `Speaker ?` and the script prints a warning.

The `.json` file next to it is the raw OpenRouter response, kept for debugging.

## Notes and limits

- Mic audio is streamed to disk in small blocks and saved as 16 kHz mono 16-bit FLAC;
  fallback-rate conversion and dual-track mixing require memory proportional to recording length.
  Long recordings are limited by memory and the upload size above. If no audio
  arrives for 5 seconds (for example when macOS blocks microphone access), the
  script stops with a clear message instead of hanging.
- Output changes during recording are not recovered: the Swift tap reads its format
  once, has no device-change listener, and does not specifically log output changes.
  Plugging in headphones or changing Bluetooth call mode may stop callbacks or cause
  a write error. Python warns on tap errors, missing finalization, silence, or a system
  track ending more than five seconds before the mic; idle playback can also trigger
  these warnings. A readable captured WAV is retained and mixed with end padding,
  even if the tap reported an error. A missing/unreadable WAV still fails clearly,
  keeping the raw files. Stop and restart recording after changing output devices.
  This is expected behaviour from code inspection, not a live device-switch test.
- The moving-average filter is speech-oriented, not a high-fidelity antialiasing filter;
  timestamps provide approximate alignment without latency or clock-drift correction.
- The diarization option is `provider.options.elevenlabs.diarize = true`. OpenRouter's docs show
  the `provider.options.<endpoint tag>` shape, and the endpoint tag for Scribe v2 is `elevenlabs`.
  The `diarize` field name comes from the ElevenLabs API reference, not from OpenRouter's docs.
  A live two-speaker test through OpenRouter confirmed it on 2026-10-08. Speaker labels come back
  on `words`, not on `segments`.
- The request timeout is 120 seconds. OpenRouter has a 60-second upstream timeout, so very long
  files may fail.
- With `--file`, the header date/time is the time you ran the script, not the time the audio
  was originally recorded.
- Recording people may require their consent. Unresolved — flagged for later phases.

## Dual-capture verification

Run the offline suite from the repository root with the existing virtual environment:

```bash
experiments/poc/.venv/bin/python -m unittest discover -s experiments/poc
```

- Synthetic system WAVs at 16 kHz mono, 24 kHz mono, 44.1 kHz stereo,
  48 kHz stereo, 8 kHz mono and 32 kHz/six channels mixed successfully with a
  16 kHz mic. Tests cover positive/negative/zero offsets, length within one frame,
  channel averaging, encoded peaks at or below 0.95, and 1 kHz FFT peaks within
  10 Hz (including 24 and 44.1 kHz). Mocked native-rate mic capture verifies both
  mic-only and dual-capture paths; missing/ambiguous selection, listing without
  an API key, partial-capture warnings and device/rate headers are checked offline.
- Live `--list-devices` reported MacBook Pro Microphone and Microsoft Teams Audio
  inputs (both default rates 48 kHz), with MacBook Pro Microphone as default input
  and MacBook Pro Speakers as default output (48 kHz). Live name lookup selected
  the MacBook input using `mAcBoOk`; `mic` was rejected as ambiguous and a missing
  name was rejected, both with input lists. This change was not tested with live
  headset capture, transcription, or mid-recording device switching.

Earlier dual-capture checks:

- Synthetic 48 kHz stereo WAV + 16 kHz mono FLAC tests verified positive,
  negative and zero start offsets, impulse alignment, end padding, mono PCM_16
  output, and encoded peaks no higher than 0.95. Idle zero-frame system capture,
  missing-helper/startup errors, silence warnings and source headers were checked offline.
- Two roughly ten-second live captures ran through the `--system-audio` parsing
  and recording path, without API calls. Ctrl+C finalized all three audio files,
  removed the helper PID sidecar and left no running app helper. Idle playback
  yielded zero frames and correctly warned about silence. With a generated tone
  playing, the mic captured 9.216 s and the system captured 9.568 s of non-silent
  audio; the aligned mixed FLAC was 9.673 s, 16 kHz mono PCM_16, peak 0.218.
  The system start-time sidecar was written. Real-call quality and diarization
  remain to be checked by the user; no live transcription was attempted.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Error: OPENROUTER_API_KEY is not set.` | Put the key in `experiments/poc/.env` or export it |
| `OpenRouter rejected the API key (HTTP 401)` | Check the key value |
| `recording too long for a single request` | Record less than about 21 minutes per request (see Size limit) |
| "Could not record from the microphone" or "No audio arrived ..." | Grant mic permission (see above), restart the terminal |
| "No usable microphone was found" | Pick an input device in System Settings > Sound |
| `praatvol.app is missing` | Run `experiments/system-audio/build.sh` from the repository root |
| `System audio tap failed to start` | Inspect the indicated `.log`, allow praatvol system-audio permission, then retry |
| `system audio was silent` | Play audio and check system-audio permission; silence can also mean idle playback |
| Every line says `Speaker ?` | OpenRouter did not return speaker labels, so the diarization option may not be forwarded |
