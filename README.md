# praatvol

praatvol records conversations through a microphone, transcribes speech, and assigns speaker labels. Optional system audio adds call participants to the transcript. Each transcript includes timestamps, speaker turns, and the reported cost. OpenRouter sends the audio to ElevenLabs Scribe v2 for transcription.

## Status

**beta-0.0.1** is an early beta that runs from the terminal. praatvol requires macOS 14.2 or later. The system-audio helper currently targets Apple Silicon.

## Features

- praatvol records microphone audio until you press Ctrl+C.
- The bundled `praatvol.app` helper captures optional system audio without virtual drivers or changes to audio routing.
- praatvol supports different microphones and headsets, including separate devices for input and output.
- `--mic NAME` selects a microphone; `--list-devices` lists devices and defaults.
- Transcripts use speaker letters and timestamps.
- praatvol uploads Opus audio and keeps a lossless Free Lossless Audio Codec (FLAC) archive locally.
- A single request supports recordings up to about 90 minutes, with a bitrate that depends on duration.
- praatvol writes Markdown transcripts and raw JavaScript Object Notation (JSON) responses.
- OpenRouter reports a cost of about 0.11 United States dollars (USD) per audio hour for `elevenlabs/scribe-v2`.

## Quick start

Install Python 3.14 before setup. Install the Apple Command Line Tools if you need system audio.

Clone the repository:

```bash
git clone https://github.com/Max0xDay/praatvol.git
cd praatvol
```

Create a virtual environment:

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

Copy the template for the application programming interface (API) key:

```bash
cp experiments/poc/.env.example experiments/poc/.env
```

Open `experiments/poc/.env` in a text editor. Set the key from your OpenRouter account:

```dotenv
OPENROUTER_API_KEY=your_key_here
```

Grant microphone access to your terminal in **System Settings > Privacy & Security > Microphone**. Restart your terminal after the permission change. Activate the virtual environment again after the restart.

Record microphone audio:

```bash
python experiments/poc/record_and_transcribe.py
```

Press Ctrl+C to stop capture and start transcription.

For system audio, build the helper from the repository root:

```bash
experiments/system-audio/build.sh
```

Record microphone audio and system audio:

```bash
python experiments/poc/record_and_transcribe.py --system-audio
```

Allow system-audio access for **praatvol** at the macOS prompt. Use headphones for calls to avoid duplicate remote voices in the microphone track.

List devices:

```bash
python experiments/poc/record_and_transcribe.py --list-devices
```

Select a microphone:

```bash
python experiments/poc/record_and_transcribe.py --mic "MacBook"
```

Transcribe an existing file:

```bash
python experiments/poc/record_and_transcribe.py --file /absolute/path/to/audio.flac
```

The script saves audio under `experiments/poc/recordings/` and transcripts under `experiments/poc/transcripts/`.

See [the PoC guide](experiments/poc/README.md) for every flag, upload limits, and troubleshooting. See [the system-audio guide](experiments/system-audio/README.md) for helper permissions and tests.

## Known limits and privacy

- The beta runs from the terminal; the helper has no visible interface.
- Speaker letters identify voices within one request, not real names or persistent identities across recordings.
- Recordings beyond 90 minutes remain untested; provider timeouts can occur.
- The size guard limits the estimated request body, including base64 audio and JSON metadata.
- Transcripts contain private speech. Keep transcripts and audio out of Git.
- OpenRouter and ElevenLabs receive the audio; praatvol does not provide local transcription.
- Obtain appropriate consent before capture.
- Stop capture before you change the output device; the helper lacks recovery for device changes.

See [the limits experiment](experiments/limits-test/README.md) for verified requests and [the compression experiment](experiments/compression-quality/README.md) for quality measurements.

## Repo layout

- `experiments/poc/` contains the beta script, dependencies, and offline tests.
- `experiments/system-audio/` contains the Swift helper and the script that builds `praatvol.app`.
- `experiments/compression-quality/` compares upload codecs against a lossless transcript reference.
- `experiments/limits-test/` tests the request size and duration limits through OpenRouter.
- `experiments/speaker-continuity/` tests speaker labels across separate requests.

## Roadmap ideas

These ideas are unordered and are not commitments.

- Organised storage: browse transcripts by date and time range.
- Recognise the same people across recordings automatically.
- Web upload: process recordings from other devices, such as iPhone Voice Memos.
- Teams call capture: transcribe Teams calls.
- Search and summaries across meetings with retrieval-augmented generation (RAG).
- Export transcripts to Teams and SharePoint.
