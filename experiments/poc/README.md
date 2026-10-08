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

- Audio is captured as 16 kHz mono 16-bit FLAC and streamed to disk in small blocks, so long
  recordings are fine up to the size limit above. If no audio arrives for 5 seconds (for example
  when macOS blocks microphone access), the script stops with a clear message instead of hanging.
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

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Error: OPENROUTER_API_KEY is not set.` | Put the key in `experiments/poc/.env` or export it |
| `OpenRouter rejected the API key (HTTP 401)` | Check the key value |
| `recording too long for a single request` | Record less than about 21 minutes per request (see Size limit) |
| "Could not record from the microphone" or "No audio arrived ..." | Grant mic permission (see above), restart the terminal |
| "No usable microphone was found" | Pick an input device in System Settings > Sound |
| Every line says `Speaker ?` | OpenRouter did not return speaker labels, so the diarization option may not be forwarded |
