#!/usr/bin/env python3
"""PoC: record the Mac microphone, transcribe it through OpenRouter's speech-to-text
endpoint with speaker diarization, and save a timestamped, speaker-labelled transcript
(Markdown + raw JSON)."""

import argparse
import base64
import json
import os
import queue
import string
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import requests
import sounddevice as sd
import soundfile as sf
from dotenv import load_dotenv

SAMPLE_RATE_HZ = 16000
CHANNELS = 1
BLOCK_FRAMES = 4096
INPUT_POLL_INTERVAL_SECONDS = 0.1
INPUT_STALL_TIMEOUT_SECONDS = 5
RECORDER_JOIN_TIMEOUT_SECONDS = 2
RECORDING_PROGRESS_INTERVAL_SECONDS = 10
HTTP_TIMEOUT_SECONDS = 120
HTTP_ATTEMPT_COUNT = 3
HTTP_RETRY_BACKOFF_SECONDS = 2
OPENROUTER_TRANSCRIPTION_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
ELEVENLABS_SCRIBE_V2_MODEL = "elevenlabs/scribe-v2"
# #COMPLETION_DRIVE: diarization is sent as provider.options.elevenlabs.diarize = true, and the
#   speaker count as provider.options.elevenlabs.num_speakers. Both field names come from the
#   ElevenLabs API reference (elevenlabs.io/docs/api-reference/speech-to-text/convert). The
#   OpenRouter STT docs name no ElevenLabs field, only the "provider.options.<endpoint tag>" shape.
#   The tag "elevenlabs" comes from openrouter.ai/api/v1/models/elevenlabs/scribe-v2-20260929/endpoints.
# #SUGGEST_VERIFY: run a real two-person recording. If every line says "Speaker ?", OpenRouter is
#   not forwarding these options and they need another name.
ELEVENLABS_PROVIDER_TAG = "elevenlabs"
SUPPORTED_AUDIO_FORMATS = ("wav", "flac", "mp3", "m4a", "ogg")
# #COMPLETION_DRIVE: the 25 MB cap is read as 25,000,000 bytes (the stricter reading). The docs
#   do not say whether the cap applies to the base64 JSON body (about 33% larger than the file).
# #SUGGEST_VERIFY: send a file of about 24 MB and check whether OpenRouter rejects it.
MAX_AUDIO_BYTES = 25_000_000
SPEAKER_LETTERS = string.ascii_uppercase

SCRIPT_DIRECTORY = Path(__file__).resolve().parent


def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description=(
            "Record the Mac microphone (or use an existing audio file), transcribe it with "
            "speaker diarization through OpenRouter, and save a timestamped transcript."
        )
    )
    parser.add_argument(
        "--file",
        type=Path,
        metavar="PATH",
        help="skip recording and transcribe this existing audio file instead (wav, flac, mp3, m4a or ogg)",
    )
    parser.add_argument(
        "--speakers",
        type=int,
        metavar="N",
        help=(
            "maximum number of speakers, sent to ElevenLabs as num_speakers. "
            "ElevenLabs treats it as an upper bound, not an exact count"
        ),
    )
    parser.add_argument(
        "--model",
        default=ELEVENLABS_SCRIBE_V2_MODEL,
        metavar="MODEL",
        help=f"OpenRouter speech-to-text model id (default: {ELEVENLABS_SCRIBE_V2_MODEL})",
    )
    return parser.parse_args()


def load_api_key():
    load_dotenv(SCRIPT_DIRECTORY / ".env")
    api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not api_key:
        fail(
            "OPENROUTER_API_KEY is not set.\n"
            "  Put your key in experiments/poc/.env (copy .env.example) or export it:\n"
            "  export OPENROUTER_API_KEY=your_key_here"
        )
    return api_key


def ensure_input_device_available():
    try:
        sd.query_devices(kind="input")
    except (sd.PortAudioError, ValueError) as error:
        fail(
            f"No usable microphone was found: {error}\n"
            "  Check that an input device is selected in System Settings > Sound.\n"
            "  macOS also requires microphone permission for your terminal:\n"
            "  System Settings > Privacy & Security > Microphone, then restart the terminal."
        )


def make_audio_block_collector(audio_blocks):
    def collect_block(indata, frame_count, time_info, status):
        if status:
            print(f"Warning: audio input reported {status}.")
        audio_blocks.put(indata.copy())

    return collect_block


def record_audio_blocks_to_queue(audio_blocks, recorder_errors, stop_recording):
    # The stream runs in a background thread so a blocked microphone open (macOS
    # permission denial) can be detected instead of freezing the whole script.
    try:
        with sd.InputStream(
            samplerate=SAMPLE_RATE_HZ,
            channels=CHANNELS,
            dtype="int16",
            blocksize=BLOCK_FRAMES,
            callback=make_audio_block_collector(audio_blocks),
        ):
            stop_recording.wait()
    except Exception as error:
        recorder_errors.append(error)


def report_recorder_error(recorder_errors):
    if not recorder_errors:
        return
    fail(
        f"Could not record from the microphone: {recorder_errors[0]}\n"
        "  If this is a permission problem, grant microphone access in\n"
        "  System Settings > Privacy & Security > Microphone, then restart the terminal."
    )


def fail_if_input_stalled(last_block_at):
    stalled_seconds = time.monotonic() - last_block_at
    if stalled_seconds <= INPUT_STALL_TIMEOUT_SECONDS:
        return
    fail(
        f"No audio arrived from the microphone for {int(stalled_seconds)} seconds.\n"
        "  This usually means macOS is blocking microphone access for your terminal:\n"
        "  System Settings > Privacy & Security > Microphone, enable your terminal, restart it.\n"
        "  Also check System Settings > Sound > Input that a working input device is selected."
    )


def write_blocks_until_interrupt(audio_file, audio_blocks, recorder_errors):
    frames_written = 0
    started_at = time.monotonic()
    last_progress_print = started_at
    last_block_at = started_at
    try:
        while True:
            report_recorder_error(recorder_errors)
            block = audio_blocks.get_nowait() if not audio_blocks.empty() else None
            if block is None:
                fail_if_input_stalled(last_block_at)
                time.sleep(INPUT_POLL_INTERVAL_SECONDS)
                continue
            audio_file.write(block)
            frames_written += len(block)
            last_block_at = time.monotonic()
            last_progress_print = print_recording_progress(started_at, last_progress_print)
    except KeyboardInterrupt:
        return frames_written


def drain_audio_blocks(audio_file, audio_blocks):
    frames_written = 0
    while not audio_blocks.empty():
        block = audio_blocks.get_nowait()
        audio_file.write(block)
        frames_written += len(block)
    return frames_written


def record_until_interrupt(output_path):
    ensure_input_device_available()
    audio_blocks = queue.Queue()
    recorder_errors = []
    stop_recording = threading.Event()
    recorder = threading.Thread(
        target=record_audio_blocks_to_queue,
        args=(audio_blocks, recorder_errors, stop_recording),
        name="microphone-recorder",
        daemon=True,
    )
    recorder.start()
    frames_written = 0
    with sf.SoundFile(
        output_path,
        mode="w",
        samplerate=SAMPLE_RATE_HZ,
        channels=CHANNELS,
        format="FLAC",
        subtype="PCM_16",
    ) as audio_file:
        try:
            print("Recording... press Ctrl+C to stop")
            frames_written = write_blocks_until_interrupt(audio_file, audio_blocks, recorder_errors)
        finally:
            stop_recording.set()
            recorder.join(timeout=RECORDER_JOIN_TIMEOUT_SECONDS)
            frames_written += drain_audio_blocks(audio_file, audio_blocks)
    if frames_written == 0:
        fail("Recording stopped before any audio was captured, nothing to transcribe.")
    duration_seconds = frames_written / SAMPLE_RATE_HZ
    print(f"Stopped. Saved {output_path.name} ({format_duration_seconds(duration_seconds)})")


def print_recording_progress(started_at, last_progress_print):
    now = time.monotonic()
    if now - last_progress_print < RECORDING_PROGRESS_INTERVAL_SECONDS:
        return last_progress_print
    print(f"Still recording ({format_duration_seconds(now - started_at)})...")
    return now


def is_retryable_status(status_code):
    return status_code == 429 or status_code >= 500


def post_with_retries(url, api_key, json_payload):
    headers = {"Authorization": f"Bearer {api_key}"}
    last_problem = "unknown error"
    for attempt in range(1, HTTP_ATTEMPT_COUNT + 1):
        try:
            response = requests.post(
                url, headers=headers, json=json_payload, timeout=HTTP_TIMEOUT_SECONDS
            )
            if not is_retryable_status(response.status_code):
                return response
            last_problem = f"HTTP {response.status_code}: {response.text[:200]}"
        except requests.RequestException as error:
            last_problem = str(error)
        if attempt < HTTP_ATTEMPT_COUNT:
            wait_seconds = HTTP_RETRY_BACKOFF_SECONDS * attempt
            print(f"Request to OpenRouter failed ({last_problem}), retrying in {wait_seconds} s...")
            time.sleep(wait_seconds)
    fail(f"Request to OpenRouter failed after {HTTP_ATTEMPT_COUNT} attempts: {last_problem}")


def ensure_request_succeeded(response):
    if response.status_code == 200:
        return
    if response.status_code == 401:
        fail(
            "OpenRouter rejected the API key (HTTP 401).\n"
            "  Check OPENROUTER_API_KEY in experiments/poc/.env or your shell environment."
        )
    fail(f"OpenRouter transcription request failed (HTTP {response.status_code}): {response.text}")


def read_audio_format(audio_path):
    audio_format = audio_path.suffix.lower().lstrip(".")
    if audio_format not in SUPPORTED_AUDIO_FORMATS:
        fail(
            f"Unsupported audio format '.{audio_format}' for {audio_path.name}.\n"
            f"  Supported: {', '.join(SUPPORTED_AUDIO_FORMATS)}"
        )
    return audio_format


def ensure_audio_within_size_limit(audio_path):
    audio_size_bytes = audio_path.stat().st_size
    if audio_size_bytes <= MAX_AUDIO_BYTES:
        return
    fail(
        "recording too long for a single request — chunking not supported yet "
        f"({audio_size_bytes / 1_000_000:.1f} MB, limit 25 MB).\n"
        f"  The audio is kept at {audio_path}"
    )


def build_provider_options(model, speakers_expected):
    if model != ELEVENLABS_SCRIBE_V2_MODEL:
        return None
    elevenlabs_options = {"diarize": True}
    if speakers_expected is not None:
        elevenlabs_options["num_speakers"] = speakers_expected
    return {ELEVENLABS_PROVIDER_TAG: elevenlabs_options}


def build_request_payload(model, audio_base64, audio_format, speakers_expected):
    payload = {
        "model": model,
        "input_audio": {"data": audio_base64, "format": audio_format},
        "response_format": "verbose_json",
        "timestamp_granularities": ["segment", "word"],
    }
    provider_options = build_provider_options(model, speakers_expected)
    if provider_options:
        payload["provider"] = {"options": provider_options}
    return payload


def warn_if_model_has_no_diarization(model):
    if model == ELEVENLABS_SCRIBE_V2_MODEL:
        return
    print(
        f"Note: no speaker-diarization option is set up for {model}, so speaker labels may be "
        "missing and --speakers is not sent."
    )


def transcribe_audio(audio_path, audio_format, api_key, model, speakers_expected):
    print(f"Sending {audio_path.name} to OpenRouter ({model})...")
    audio_base64 = base64.b64encode(audio_path.read_bytes()).decode("ascii")
    payload = build_request_payload(model, audio_base64, audio_format, speakers_expected)
    response = post_with_retries(OPENROUTER_TRANSCRIPTION_URL, api_key, payload)
    ensure_request_succeeded(response)
    try:
        transcript = response.json()
    except ValueError:
        fail(f"OpenRouter returned a response that is not JSON: {response.text[:200]}")
    print("Transcription complete.")
    return transcript


def format_timestamp(seconds):
    total_seconds = int(seconds)
    return f"{total_seconds // 60:02d}:{total_seconds % 60:02d}"


def format_duration_seconds(seconds):
    total_seconds = int(seconds)
    minutes, seconds = divmod(total_seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours > 0:
        return f"{hours} h {minutes} min {seconds} s"
    if minutes > 0:
        return f"{minutes} min {seconds} s"
    return f"{seconds} s"


def format_speaker_label(speaker_index):
    if speaker_index is None:
        return "?"
    if speaker_index < len(SPEAKER_LETTERS):
        return SPEAKER_LETTERS[speaker_index]
    return str(speaker_index)


def speaker_labelled_items(items):
    return any(item.get("speaker") is not None for item in items)


def speaker_labels_present(response):
    words = response.get("words") or []
    segments = response.get("segments") or []
    return speaker_labelled_items(words) or speaker_labelled_items(segments)


def warn_if_speaker_labels_missing(response):
    if speaker_labels_present(response):
        return
    print("Warning: no speaker labels came back from OpenRouter, so lines are marked 'Speaker ?'.")


def normalise_timed_items(items, text_key):
    return [
        {"start": item["start"], "speaker": item.get("speaker"), "text": str(item[text_key]).strip()}
        for item in items
    ]


def choose_timed_items(response):
    words = response.get("words") or []
    segments = response.get("segments") or []
    if speaker_labelled_items(words):
        return normalise_timed_items(words, "word")
    return normalise_timed_items(segments, "text")


def continues_utterance(utterance, item):
    return item["speaker"] is not None and item["speaker"] == utterance["speaker"]


def group_timed_items_by_speaker(timed_items):
    utterances = []
    for item in timed_items:
        if not item["text"]:
            continue
        if utterances and continues_utterance(utterances[-1], item):
            utterances[-1]["text"] = f"{utterances[-1]['text']} {item['text']}"
        else:
            utterances.append({"start": item["start"], "speaker": item["speaker"], "text": item["text"]})
    return utterances


def build_utterances(response):
    timed_items = choose_timed_items(response)
    if timed_items:
        return group_timed_items_by_speaker(timed_items)
    text = str(response.get("text") or "").strip()
    if not text:
        return []
    # #COMPLETION_DRIVE: no usable segments or words came back, so the whole text is placed at 00:00.
    # #SUGGEST_VERIFY: check whether OpenRouter ever returns text without timestamps for this model.
    return [{"start": 0.0, "speaker": None, "text": text}]


def format_cost(response):
    cost_usd = (response.get("usage") or {}).get("cost")
    if cost_usd is None:
        return "not reported"
    return f"${cost_usd:.6f} (OpenRouter)"


def write_transcript_markdown(output_path, response, source_name, recorded_at):
    utterances = build_utterances(response)
    speaker_count = len({utterance["speaker"] for utterance in utterances if utterance["speaker"] is not None})
    duration_seconds = (response.get("usage") or {}).get("seconds", 0)
    lines = [
        f"# Transcript: {recorded_at:%Y-%m-%d %H:%M:%S}",
        "",
        f"- Source audio: {source_name}",
        f"- Date/time: {recorded_at:%Y-%m-%d %H:%M:%S}",
        f"- Duration: {format_duration_seconds(duration_seconds)}",
        f"- Speakers: {speaker_count}",
        f"- Cost: {format_cost(response)}",
        "",
    ]
    if not utterances:
        lines.append("No speech was detected.")
    for utterance in utterances:
        timestamp = format_timestamp(utterance["start"])
        speaker_label = format_speaker_label(utterance["speaker"])
        lines.append(f"[{timestamp}] Speaker {speaker_label}: {utterance['text']}")
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_transcript_json(output_path, transcript):
    output_path.write_text(json.dumps(transcript, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main():
    arguments = parse_arguments()
    if arguments.speakers is not None and arguments.speakers < 1:
        fail("--speakers must be a positive whole number.")
    api_key = load_api_key()
    warn_if_model_has_no_diarization(arguments.model)
    started_at = datetime.now()
    timestamp = started_at.strftime("%Y-%m-%d_%H-%M-%S")

    if arguments.file is not None:
        # #COMPLETION_DRIVE: with --file the header date/time is the transcription time,
        #   not the time the audio was originally recorded.
        # #SUGGEST_VERIFY: change this if transcripts must show the original recording time.
        audio_path = arguments.file.expanduser().resolve()
        if not audio_path.is_file():
            fail(f"Audio file not found: {audio_path}")
    else:
        SCRIPT_DIRECTORY.joinpath("recordings").mkdir(exist_ok=True)
        audio_path = SCRIPT_DIRECTORY / "recordings" / f"{timestamp}.flac"
        record_until_interrupt(audio_path)

    audio_format = read_audio_format(audio_path)
    ensure_audio_within_size_limit(audio_path)
    response = transcribe_audio(audio_path, audio_format, api_key, arguments.model, arguments.speakers)
    warn_if_speaker_labels_missing(response)

    SCRIPT_DIRECTORY.joinpath("transcripts").mkdir(exist_ok=True)
    markdown_path = SCRIPT_DIRECTORY / "transcripts" / f"{timestamp}.md"
    json_path = SCRIPT_DIRECTORY / "transcripts" / f"{timestamp}.json"
    write_transcript_markdown(markdown_path, response, audio_path.name, started_at)
    write_transcript_json(json_path, response)
    print(f"Wrote transcript: {markdown_path}")
    print(f"Wrote raw API JSON: {json_path}")


if __name__ == "__main__":
    main()
