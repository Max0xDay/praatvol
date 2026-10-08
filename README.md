# praatvol

praatvol records a room with the laptop microphone, transcribes the speech, and labels each speaker. The output is a timestamped transcript.

## Why

Microsoft Teams can transcribe calls. Many meetings are not recorded, and conversations in a room have no transcript at all. praatvol covers these gaps.

## Status

praatvol is an early proof of concept (PoC). There is no installable product yet. praatvol runs on macOS only.

The current PoC lives in `experiments/poc/`. It records the microphone to FLAC (Free Lossless Audio Codec) and sends the audio to OpenRouter. The request uses the model `elevenlabs/scribe-v2` with speaker diarization, which separates speakers by voice. The PoC writes a Markdown transcript and a JSON (JavaScript Object Notation) file with the raw response.

The PoC was tested live with two speakers. The measured cost is about 0.11 United States dollars (USD) per hour of audio. Each recording is limited to about 21 minutes, because each request is limited to 25 megabytes (MB).

## Quick start

The setup steps, API key configuration, and usage commands are in [experiments/poc/README.md](experiments/poc/README.md).

## Repo layout

- `experiments/`: throwaway prototypes and tests.
  - `experiments/poc/`: the PoC script and its setup files.

Product code will go outside `experiments/`. That folder does not exist yet.

Work happens on `task/<name>` branches. A branch merges into `main` when it is production ready. Releases will be published on GitHub.

## Roadmap ideas

These ideas are for later. They are unordered and not commitments.

- Organised storage: browse transcripts by date and time range.
- Recognise the same people across recordings automatically.
- Web upload: process recordings from other devices, such as iPhone Voice Memos.
- Teams call capture: transcribe Teams calls.
- Search and summaries across meetings with retrieval-augmented generation (RAG).
- Export transcripts to Teams and SharePoint.

## Privacy

Recording people may require their consent. This question is not resolved yet.

Audio is sent to OpenRouter and to the model provider for transcription.
