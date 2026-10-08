# praatvol beta: record and transcribe

The proof of concept (PoC) provides the terminal interface for `beta-0.0.1` on macOS 14.2 or later. The script captures microphone audio and optional system audio, then sends one request through OpenRouter to `elevenlabs/scribe-v2`.

The script keeps a lossless Free Lossless Audio Codec (FLAC) archive and creates an Opus upload copy. Each transcript includes timestamps, speaker letters, device details for live capture, and the reported cost. Output includes Markdown and raw JavaScript Object Notation (JSON).

## Files and setup

| File | Purpose |
|---|---|
| `record_and_transcribe.py` | The script captures audio, sends the request, and writes transcripts. |
| `test_record_and_transcribe.py` | The offline suite checks devices, audio conversion, uploads, and responses. |
| `requirements.txt` | The file lists pinned Python dependencies. |
| `.env.example` | The template contains the OpenRouter application programming interface (API) key variable. |

Use Python 3.14. The development machine runs Python 3.14.8. The script needs no ffmpeg or local machine-learning model.

From the repository root, create a virtual environment:

```bash
python3 -m venv experiments/poc/.venv
```

Activate the virtual environment:

```bash
source experiments/poc/.venv/bin/activate
```

Install the dependencies:

```bash
pip install -r experiments/poc/requirements.txt
```

Copy the key template:

```bash
cp experiments/poc/.env.example experiments/poc/.env
```

Open `experiments/poc/.env` in a text editor. Set `OPENROUTER_API_KEY` to your key from https://openrouter.ai.

```dotenv
OPENROUTER_API_KEY=your_key_here
```

Alternatively, export the key in your shell:

```bash
export OPENROUTER_API_KEY=your_key_here
```

Git ignores `.env`, `recordings/`, and `transcripts/`. The script places output under `experiments/poc/`, regardless of your current directory.

### Microphone permission

1. Open **System Settings > Privacy & Security > Microphone**.
2. Enable access for your terminal app.
3. Restart your terminal.
4. Activate the virtual environment again.

If microphone capture stalls, check permission and the input device. The script stops if the microphone supplies no audio for five seconds.

## Usage and flags

All commands below run from the repository root with the virtual environment active.

Record microphone audio:

```bash
python experiments/poc/record_and_transcribe.py
```

Press Ctrl+C to stop capture and start transcription.

List input devices and the default input and output:

```bash
python experiments/poc/record_and_transcribe.py --list-devices
```

`--list-devices` requires no API key and captures no audio.

Select a microphone:

```bash
python experiments/poc/record_and_transcribe.py --mic "MacBook"
```

`--mic NAME` matches a case-insensitive substring of an input device name. The name must match exactly one input. Use a longer substring if the script reports multiple matches.

Transcribe an existing file:

```bash
python experiments/poc/record_and_transcribe.py --file /absolute/path/to/audio.flac
```

`--file PATH` accepts Waveform Audio File Format (WAV), FLAC, MPEG Audio Layer III (MP3), MPEG-4 Audio (M4A), and Ogg files. WAV and FLAC use Opus by default. MP3, M4A, and Ogg pass through unchanged.

Upload lossless audio:

```bash
python experiments/poc/record_and_transcribe.py --lossless --file /absolute/path/to/audio.flac
```

`--lossless` sends WAV or FLAC without Opus conversion. The flag also applies to live capture. Already compressed files still pass through unchanged.

Set the maximum speaker count:

```bash
python experiments/poc/record_and_transcribe.py --speakers 2
```

`--speakers N` requires a positive integer. ElevenLabs treats `num_speakers` as an upper bound, not an exact count.

Select another OpenRouter model:

```bash
python experiments/poc/record_and_transcribe.py --model openai/whisper-large-v3 --file /absolute/path/to/audio.flac
```

Only `elevenlabs/scribe-v2` uses the configured diarization option. Other models omit that option and `--speakers`; the script prints a note.

Show every option:

```bash
python experiments/poc/record_and_transcribe.py --help
```

### Devices and capture rates

The default microphone uses the current macOS input. The script leaves the default input and output unchanged. You can combine a headset output with a different microphone.

The script first opens the microphone at 16 kilohertz (kHz), mono. If that rate fails, the script retries at the default rate for the device. The script stores that audio on disk and converts the audio after capture.

At startup, the script prints the microphone name and actual rate. For system audio, the script also prints the default output name. After capture, the script reads the actual system rate and channel count from the WAV header.

## Microphone and system audio

Build the helper from the repository root:

```bash
experiments/system-audio/build.sh
```

The helper requires the Apple Command Line Tools. The build currently targets Apple Silicon.

Capture microphone audio and system audio:

```bash
python experiments/poc/record_and_transcribe.py --system-audio --mic "MacBook"
```

`--mic` is optional. `--system-audio` launches `experiments/system-audio/praatvol.app` through `open -n -W`. The helper uses a global Core Audio tap without virtual drivers or changes to audio routing.

Allow system-audio access for **praatvol** at the macOS prompt. If access fails, follow [the helper guide](../system-audio/README.md#run-and-permissions). A helper startup failure after about five seconds points to the helper log.

Press Ctrl+C to stop both captures. The script keeps these files under `recordings/`:

- `<timestamp>_mic.flac` contains the separate microphone track at 16 kHz, mono.
- `<timestamp>_system.wav` contains the raw system track at the actual rate and channel count.
- `<timestamp>.flac` contains the aligned mix at 16 kHz, mono, with 16-bit pulse-code modulation (PCM).
- `<timestamp>_system.wav.log` contains helper diagnostics and a silence check.
- `<timestamp>_system.wav.start` contains the Unix timestamp for the first system sample.

The helper removes the temporary `.pid` file on normal exit. The file contains the process identifier (PID).

The Python mixer accepts different rates and channel counts. The mixer averages channels, filters higher rates, and interpolates samples onto the 16 kHz grid. The mixer aligns tracks with start timestamps and adds silence to the shorter track. The mixer reduces the peak only if necessary to keep the encoded peak at or below 0.95.

Alignment remains approximate because the mixer lacks correction for device latency or clock drift. The filter targets speech, not high-fidelity audio. Conversion and the mixer load audio into memory; long recordings can exceed available memory.

Use headphones for calls. Speakers also send remote voices into the microphone track, which duplicates voices and can confuse speaker labels.

The helper captures all system playback, not only Teams. Silence can indicate idle playback or denied permission. The script warns about silence and retains microphone audio for transcription.

Use `--mic` only for live capture. Use `--system-audio` only for live capture. Both flags conflict with `--file`.

Stop capture before you change the output device. The helper lacks recovery for device changes and reads the format only at startup. A change can stop callbacks or cause a write error.

The script warns about helper errors, silence, absent finalization, or a system track that ends over five seconds before the microphone. Idle playback can also produce the early-stop warning. The mixer retains readable system audio and adds silence at the end. If the WAV is absent or unreadable, the script fails and keeps the raw files.

## Upload format and duration

The script keeps the original FLAC archive locally. The script converts WAV and FLAC to mono Opus in an Ogg container for upload.

| Audio duration | Opus target | Guidance |
|---|---:|---|
| Up to 60 minutes | About 64 kilobits per second (kbps) | A 60-minute request succeeded. |
| Over 60 minutes, up to 90 minutes | About 48 kbps | A 90-minute request succeeded. |
| Over 90 minutes | About 32 kbps | The duration remains untested and can cause a timeout. |

Above 90 minutes, the script prints one warning line about timeout risk and the local archive. The script still attempts the request if the size guard accepts the upload.

The encoder calibrates the target on the first 30 seconds. The script reports the actual bitrate and size. Actual bitrate can vary with the audio; the script warns if the target differs by more than 10%.

Opus at about 64 kbps matched lossless quality within run-to-run noise on the reference sample. Opus at about 48 kbps was near-equivalent. See [the compression experiment](../compression-quality/README.md) for the measurements and the original strict criterion.

If Opus conversion fails, the script prints a warning and uploads lossless audio instead. `--lossless` also uploads the original WAV or FLAC. Lossless audio reaches the size limit sooner, and the same size guard applies.

Already compressed inputs pass through unchanged, regardless of duration. If libsndfile cannot read a duration, as with M4A, the script prints a note and skips the duration warning.

## Request size and timeout limits

OpenRouter limits the complete base64 JSON body to 50 mebibytes (MiB), or 52,428,800 bytes. The limit applies to the request body, not the raw audio file.

The script estimates the body before upload:

```text
estimated_body_bytes = ceil(file_bytes / 3) * 4 + 1024
```

The extra 1,024 bytes reserve space for JSON metadata. The script rejects estimates above 50,000,000 bytes to leave a safety margin below the server limit. The size guard checks the actual upload file: Opus by default, lossless with `--lossless`, or a compressed input without conversion.

If the guard rejects the upload, the error reports the estimate, safety limit, server limit, and local upload path. The full archive remains local. The script does not split audio into chunks.

Verified requests through `elevenlabs/scribe-v2` include:

- A 60-minute request at about 64 kbps succeeded in 68 seconds.
- A 90-minute request at about 48 kbps succeeded in 88 seconds.
- A three-hour request at about 24 kbps returned provider error 524 after 148 seconds, without a transcript.

Speaker labels stay consistent throughout a single request. Separate requests lack reliable speaker matching. The successful trials used repeated audio; the trials do not guarantee success for every conversation or provider load.

The Python request timeout remains 120 seconds. The experiments do not establish a fixed provider timeout. If a Hypertext Transfer Protocol (HTTP) 200 response contains an `error` key, the script reports a provider failure and keeps local audio.

See [the limits experiment](../limits-test/README.md) for exact sizes, timings, and costs.

## Cost and output

The observed cost for `elevenlabs/scribe-v2` is about 0.11 United States dollars (USD) per audio hour. Each transcript shows the cost from `usage.cost`. Check current prices at https://openrouter.ai/elevenlabs/scribe-v2.

The script writes two files under `transcripts/` with the timestamp `YYYY-MM-DD_HH-MM-SS`:

- The `.md` file contains the transcript and metadata.
- The `.json` file contains the raw OpenRouter response.

The Markdown header shows the source file, date, duration, speaker count, cost, and upload details. Live capture also includes device names and capture rates. The upload line shows the codec, file size, and request duration.

For example, a synthetic speaker turn looks like:

```markdown
[00:00] Speaker A: Hello.
```

Timestamps count minutes beyond 59. Speaker letters represent diarization labels within one request, not names or identities across recordings. The script joins consecutive words from the same speaker into one turn. If the response lacks speaker labels, the transcript uses `Speaker ?` and the script prints a warning.

ElevenLabs returns speaker labels on words, not segments. The request uses `provider.options.elevenlabs.diarize = true`. A live two-speaker test confirmed that option through OpenRouter on 2026-10-08.

With `--file`, the header date reflects the transcription run, not the original capture time.

## Offline verification

Run the whole suite from the repository root:

```bash
experiments/poc/.venv/bin/python -m unittest discover -s experiments/poc
```

The suite checks:

- Different rates and channel counts, including mono, stereo, and six channels.
- Alignment, channel averages, end padding, peak limits, and tone frequency.
- Microphone selection, native-rate fallback, and device names in transcript headers.
- Opus calibration, duration-based targets, lossless uploads, and conversion failures.
- The body estimate, size guard, duration warning, and HTTP 200 provider errors.

Earlier live checks confirmed non-silent system capture and clean shutdown of both tracks. Real-call quality, headset capture, and changes to devices during capture still need manual checks. See [the helper guide](../system-audio/README.md#verification-on-the-development-machine) for prior results.

## Troubleshooting and privacy

- If `OPENROUTER_API_KEY` is absent, set the key in `experiments/poc/.env` or export the key.
- If OpenRouter returns HTTP 401, check the key value.
- If the size guard rejects the body, use default Opus conversion or a shorter recording.
- If a provider failure occurs, keep the local archive for a later manual attempt.
- If microphone capture fails or stalls, grant permission and restart the terminal.
- If microphone selection fails, use `--list-devices` and select a unique input name.
- If `praatvol.app` is absent, run `experiments/system-audio/build.sh`.
- If the helper fails to start, inspect the log and grant system-audio permission.
- If system audio is silent, play audio and check permission.
- If the transcript uses `Speaker ?`, check the model and the returned speaker labels.

Keep audio and transcripts private. OpenRouter and ElevenLabs receive the audio. Obtain appropriate consent before capture. The existing request client retries some network failures and server errors; those retries can duplicate paid requests.
