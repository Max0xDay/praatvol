#!/usr/bin/env python3
"""PoC: record the Mac microphone, transcribe it through OpenRouter's speech-to-text
endpoint with speaker diarization, and save a timestamped, speaker-labelled transcript
(Markdown + raw JSON)."""

import argparse
import base64
import json
import os
import queue
import signal
import string
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import numpy
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
    parser.add_argument(
        "--system-audio",
        action="store_true",
        help="record the microphone and system playback together via praatvol.app",
    )
    parser.add_argument(
        "--mic", metavar="NAME", help="select an input device by case-insensitive name substring"
    )
    parser.add_argument(
        "--list-devices", action="store_true", help="list input devices and default input/output, then exit"
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


def input_device_listing(devices):
    lines = ["Available input devices:"]
    for device in devices:
        if device["max_input_channels"] > 0:
            lines.append(
                f"  {device['index']}: {device['name']} "
                f"({device['default_samplerate']:g} Hz default, "
                f"{device['max_input_channels']} input channels)"
            )
    if len(lines) == 1:
        lines.append("  (none)")
    return "\n".join(lines)


def default_device_description(kind):
    try:
        device = sd.query_devices(kind=kind)
        return f"{device['name']} ({device['default_samplerate']:g} Hz default)"
    except (sd.PortAudioError, ValueError) as error:
        print(f"Warning: could not query default {kind}: {error}")
        return "unavailable"


def list_audio_devices():
    try:
        print(input_device_listing(sd.query_devices()))
    except (sd.PortAudioError, ValueError) as error:
        fail(f"Could not list audio devices: {error}")
    print(f"Default input: {default_device_description('input')}")
    print(f"Default output: {default_device_description('output')}")


def select_microphone(name=None):
    try:
        devices = sd.query_devices()
        if name is None:
            return sd.query_devices(kind="input")
        matches = [
            device for device in devices
            if device["max_input_channels"] > 0
            if name.casefold() in device["name"].casefold()
        ]
    except (sd.PortAudioError, ValueError) as error:
        fail(f"No usable microphone was found: {error}\n"
             "  Check System Settings > Sound > Input and terminal microphone permission.")
    if len(matches) == 1:
        return matches[0]
    fail(f"--mic {name!r} matched {len(matches)} input devices; use a more specific name.\n"
         f"{input_device_listing(devices)}")


def make_audio_block_collector(audio_blocks, first_block_time=None):
    def collect_block(indata, frame_count, time_info, status):
        if status:
            print(f"Warning: audio input reported {status}.")
        if first_block_time is not None:
            if not first_block_time:
                first_block_time.append(
                    time.time() - (time_info.currentTime - time_info.inputBufferAdcTime)
                )
        audio_blocks.put(indata.copy())

    return collect_block


def open_microphone_stream(microphone_device, callback):
    stream_options = {
        "device": microphone_device["index"],
        "channels": CHANNELS,
        "dtype": "int16",
        "blocksize": BLOCK_FRAMES,
        "callback": callback,
    }
    try:
        return sd.InputStream(samplerate=SAMPLE_RATE_HZ, **stream_options)
    except (sd.PortAudioError, ValueError) as error:
        native_rate_hz = microphone_device["default_samplerate"]
        print(f"Warning: microphone could not open at {SAMPLE_RATE_HZ} Hz: {error}")
        if native_rate_hz == SAMPLE_RATE_HZ:
            raise
        print(f"Retrying microphone at its default rate, {native_rate_hz:g} Hz.")
        return sd.InputStream(samplerate=native_rate_hz, **stream_options)


def record_audio_blocks_to_queue(
    audio_blocks, recorder_errors, stop_recording, microphone_device, capture_rates,
    first_block_time=None,
):
    # The stream runs in a background thread so a blocked microphone open (macOS
    # permission denial) can be detected instead of freezing the whole script.
    try:
        callback = make_audio_block_collector(audio_blocks, first_block_time)
        with open_microphone_stream(microphone_device, callback) as stream:
            capture_rates.append(round(stream.samplerate))
            print(f"Microphone: {microphone_device['name']} ({capture_rates[0]} Hz)")
            stop_recording.wait()
    except Exception as error:
        print(f"Error: microphone recorder failed: {error}", file=sys.stderr)
        recorder_errors.append(error)


def wait_for_microphone_rate(capture_rates, recorder_errors):
    started_at = time.monotonic()
    while not capture_rates:
        report_recorder_error(recorder_errors)
        fail_if_input_stalled(started_at)
        time.sleep(INPUT_POLL_INTERVAL_SECONDS)
    return capture_rates[0]


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


def resample_microphone_file(output_path, capture_rate_hz):
    if capture_rate_hz == SAMPLE_RATE_HZ:
        return
    try:
        microphone_samples, file_rate_hz = sf.read(output_path, dtype="float32")
        converted_samples = resample_audio(microphone_samples, file_rate_hz)
        sf.write(output_path, converted_samples, SAMPLE_RATE_HZ, format="FLAC", subtype="PCM_16")
    except (OSError, ValueError, RuntimeError) as error:
        fail(f"Could not resample microphone recording {output_path}: {error}")


def record_until_interrupt(
    output_path, first_block_time=None, capture_started=None, microphone_device=None
):
    if microphone_device is None:
        microphone_device = select_microphone()
    audio_blocks = queue.Queue()
    recorder_errors = []
    capture_rates = []
    stop_recording = threading.Event()
    recorder = threading.Thread(
        target=record_audio_blocks_to_queue,
        args=(audio_blocks, recorder_errors, stop_recording, microphone_device,
              capture_rates, first_block_time),
        name="microphone-recorder",
        daemon=True,
    )
    recorder.start()
    frames_written = 0
    try:
        capture_rate_hz = wait_for_microphone_rate(capture_rates, recorder_errors)
        with sf.SoundFile(
            output_path, mode="w", samplerate=capture_rate_hz, channels=CHANNELS,
            format="FLAC", subtype="PCM_16",
        ) as audio_file:
            try:
                if capture_started is None:
                    print("Recording... press Ctrl+C to stop")
                else:
                    print("Recording mic + system audio... press Ctrl+C to stop")
                    capture_started()
                frames_written = write_blocks_until_interrupt(audio_file, audio_blocks, recorder_errors)
            finally:
                stop_recording.set()
                recorder.join(timeout=RECORDER_JOIN_TIMEOUT_SECONDS)
                frames_written += drain_audio_blocks(audio_file, audio_blocks)
    finally:
        stop_recording.set()
        recorder.join(timeout=RECORDER_JOIN_TIMEOUT_SECONDS)
    if frames_written == 0:
        fail("Recording stopped before any audio was captured, nothing to transcribe.")
    duration_seconds = frames_written / capture_rate_hz
    resample_microphone_file(output_path, capture_rate_hz)
    print(f"Stopped. Saved {output_path.name} ({format_duration_seconds(duration_seconds)})")
    return f"mic: {microphone_device['name']} ({capture_rate_hz} Hz)"


def wait_for_tap_pid(system_path, application_process):
    pid_path = Path(str(system_path) + ".pid")
    deadline = time.monotonic() + INPUT_STALL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if pid_path.is_file():
            process_identifier = int(pid_path.read_text().strip())
            if process_identifier <= 1:
                raise ValueError(f"Invalid tap PID in {pid_path}")
            return process_identifier
        if application_process.poll() is not None:
            break
        time.sleep(INPUT_POLL_INTERVAL_SECONDS)
    raise RuntimeError(
        f"System audio tap failed to start; check {system_path}.log. "
        "Allow praatvol in System Settings > Privacy & Security > "
        "Screen & System Audio Recording, then retry."
    )


def stop_system_capture(application_process, process_identifier):
    if process_identifier is not None:
        try:
            os.kill(process_identifier, signal.SIGINT)
        except ProcessLookupError:
            print("Warning: system audio tap exited before it could be stopped.")
    try:
        application_process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        print("Error: system audio tap did not stop within 10 seconds.", file=sys.stderr)
        if process_identifier is not None:
            try:
                os.kill(process_identifier, signal.SIGKILL)
            except ProcessLookupError:
                print("Warning: system audio tap already exited.")
        application_process.terminate()
        application_process.wait(timeout=5)
        raise RuntimeError("System audio shutdown timed out; raw WAV may be incomplete.")


def system_capture_is_silent(capture_log, capture_info):
    return "silent=true" in capture_log or capture_info.frames == 0


def inspect_system_capture(system_path, microphone_end_seconds=None):
    log_path = Path(str(system_path) + ".log")
    try:
        capture_log = log_path.read_text()
    except OSError as error:
        print(f"Warning: could not read system audio log: {error}")
        capture_log = ""
    if "Error:" in capture_log:
        print(f"Warning: system audio tap reported an error; keeping captured audio; check {log_path}")
    if "Silence check:" not in capture_log:
        print(f"Warning: system audio tap did not report finalization; check {log_path}")
    capture_info = sf.info(system_path)
    print(f"System tap: {capture_info.samplerate} Hz, {capture_info.channels} channels")
    if system_capture_is_silent(capture_log, capture_info):
        print(
            f"Warning: system audio was silent; check {log_path}. "
            "Playback may have been idle or macOS may have denied permission."
        )
    start_path = Path(str(system_path) + ".start")
    if microphone_end_seconds is not None:
        if start_path.is_file():
            system_start_seconds = system_capture_start(system_path, microphone_end_seconds)
            system_end_seconds = system_start_seconds + capture_info.duration
            # #COMPLETION_DRIVE: A five-second shortfall suggests stopped callbacks, but
            # idle playback can also produce no frames; this is only a warning.
            # #SUGGEST_VERIFY: Switch output devices during playback and inspect the raw WAV.
            if microphone_end_seconds - system_end_seconds > INPUT_STALL_TIMEOUT_SECONDS:
                print("Warning: system audio may have stopped early (idle playback or output "
                      "device change); keeping captured audio and padding the remainder.")
    return capture_info


def resample_audio(mono_samples, source_rate_hz):
    if source_rate_hz <= 0:
        raise ValueError("Audio sample rate must be positive.")
    if mono_samples.size == 0:
        return mono_samples
    if source_rate_hz == SAMPLE_RATE_HZ:
        return mono_samples
    filtered_samples = mono_samples
    if source_rate_hz > SAMPLE_RATE_HZ:
        # #COMPLETION_DRIVE: A centered box filter of about three times the rate ratio
        # is adequate for speech, not a high-fidelity antialiasing filter.
        # #SUGGEST_VERIFY: Listen to headset recordings for downsampling artifacts.
        filter_frames = max(3, round(3 * source_rate_hz / SAMPLE_RATE_HZ))
        if filter_frames % 2 == 0:
            filter_frames += 1
        padding_frames = filter_frames // 2
        padded_samples = numpy.pad(mono_samples, (padding_frames, padding_frames), mode="edge")
        filtered_samples = numpy.convolve(
            padded_samples, numpy.ones(filter_frames) / filter_frames, mode="valid"
        )
    output_frames = round(len(mono_samples) * SAMPLE_RATE_HZ / source_rate_hz)
    source_positions = numpy.arange(output_frames) * (source_rate_hz / SAMPLE_RATE_HZ)
    return numpy.interp(source_positions, numpy.arange(len(mono_samples)), filtered_samples)


def system_capture_start(system_path, microphone_start_seconds):
    start_path = Path(str(system_path) + ".start")
    try:
        system_start_seconds = float(start_path.read_text())
        if not numpy.isfinite(system_start_seconds):
            raise ValueError("System start timestamp must be finite.")
        return system_start_seconds
    except (OSError, ValueError) as error:
        # #COMPLETION_DRIVE: Without a usable system timestamp, align to mic start.
        # #SUGGEST_VERIFY: Inspect the tap log; alignment of a partial capture is approximate.
        print(f"Warning: system start timestamp unavailable: {error}; aligning to microphone start.")
        return microphone_start_seconds


def mix_audio_tracks(microphone_path, system_path, microphone_start_seconds, output_path):
    microphone_samples, microphone_rate_hz = sf.read(microphone_path, dtype="float32")
    system_samples, system_rate_hz = sf.read(system_path, dtype="float32", always_2d=True)
    if microphone_rate_hz != SAMPLE_RATE_HZ:
        raise ValueError("Microphone track must be 16 kHz.")
    if microphone_samples.ndim != 1:
        raise ValueError("Microphone track must be mono.")
    if microphone_samples.size == 0:
        raise ValueError("Microphone track contains no samples.")
    system_mono = system_samples.mean(axis=1)
    system_start_seconds = microphone_start_seconds
    if system_mono.size:
        system_start_seconds = system_capture_start(system_path, microphone_start_seconds)
        system_mono = resample_audio(system_mono, system_rate_hz)
    start_offset_seconds = system_start_seconds - microphone_start_seconds
    if not numpy.isfinite(start_offset_seconds):
        raise ValueError("Capture start timestamps must be finite.")
    offset_frames = round(abs(start_offset_seconds) * SAMPLE_RATE_HZ)
    if start_offset_seconds >= 0:
        system_mono = numpy.pad(system_mono, (offset_frames, 0))
    else:
        microphone_samples = numpy.pad(microphone_samples, (offset_frames, 0))
    mixed_frames = max(len(microphone_samples), len(system_mono))
    mixed_samples = numpy.pad(microphone_samples, (0, mixed_frames - len(microphone_samples)))
    mixed_samples += numpy.pad(system_mono, (0, mixed_frames - len(system_mono)))
    if not numpy.isfinite(mixed_samples).all():
        raise ValueError("Captured audio contains non-finite samples.")
    peak = float(numpy.max(numpy.abs(mixed_samples)))
    # Keep the encoded PCM_16 peak below 0.95 too, not just the float samples.
    peak_limit = numpy.floor(0.95 * 32768) / 32768
    if peak > peak_limit:
        mixed_samples *= peak_limit / peak
    sf.write(output_path, mixed_samples, SAMPLE_RATE_HZ, format="FLAC", subtype="PCM_16")


def record_microphone_and_system(output_path, microphone_device=None):
    application_path = SCRIPT_DIRECTORY.parent / "system-audio" / "praatvol.app"
    if not application_path.is_dir():
        fail("praatvol.app is missing; run experiments/system-audio/build.sh first.")
    microphone_path = output_path.with_name(output_path.stem + "_mic.flac")
    system_path = output_path.with_name(output_path.stem + "_system.wav")
    microphone_start = []
    # #COMPLETION_DRIVE: Label global playback with the default output at startup;
    # the tap may include other outputs and does not track routing changes.
    # #SUGGEST_VERIFY: Compare with macOS Sound settings, especially for multi-output routing.
    try:
        system_device_name = sd.query_devices(kind="output")["name"]
    except (sd.PortAudioError, ValueError) as error:
        fail(f"Could not query the default system output: {error}")
    print(f"System playback: {system_device_name} (tap rate/channels reported after stop)")
    tap_process_identifier = None
    application_process = None

    def capture_started():
        nonlocal tap_process_identifier
        tap_process_identifier = wait_for_tap_pid(system_path, application_process)

    try:
        application_process = subprocess.Popen(
            ["open", "-n", "-W", str(application_path), "--args", str(system_path.resolve())],
            start_new_session=True,
        )
        try:
            microphone_source = record_until_interrupt(
                microphone_path, microphone_start, capture_started, microphone_device
            )
        finally:
            if tap_process_identifier is None:
                try:
                    tap_process_identifier = wait_for_tap_pid(system_path, application_process)
                except (OSError, ValueError, RuntimeError) as error:
                    print(f"Warning: could not locate tap for shutdown: {error}", file=sys.stderr)
            stop_system_capture(application_process, tap_process_identifier)
        if not microphone_start:
            raise RuntimeError("No microphone start timestamp was captured.")
        microphone_end_seconds = microphone_start[0] + sf.info(microphone_path).duration
        capture_info = inspect_system_capture(system_path, microphone_end_seconds)
        mix_audio_tracks(microphone_path, system_path, microphone_start[0], output_path)
        print(f"Saved mixed audio: {output_path.name}")
        return (f"{microphone_source}; system: {system_device_name} "
                f"({capture_info.samplerate} Hz, {capture_info.channels} channels)")
    except KeyboardInterrupt:
        fail("Recording interrupted before both captures were ready; raw tracks are kept.")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        fail(f"Mic + system audio capture failed: {error}; check {system_path}.log")


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


def write_transcript_markdown(output_path, response, source_name, recorded_at, sources=None):
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
    if sources:
        lines.insert(3, f"- Sources: {sources}")
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
    if arguments.list_devices:
        list_audio_devices()
        return
    if arguments.mic is not None:
        if arguments.file is not None:
            fail("--mic cannot be used with --file.")
    if arguments.speakers is not None and arguments.speakers < 1:
        fail("--speakers must be a positive whole number.")
    # #COMPLETION_DRIVE: --system-audio describes live capture, not an existing --file.
    # #SUGGEST_VERIFY: Keep these modes exclusive unless file mixing is requested later.
    if arguments.system_audio:
        if arguments.file is not None:
            fail("--system-audio cannot be used with --file.")
    api_key = load_api_key()
    warn_if_model_has_no_diarization(arguments.model)
    started_at = datetime.now()
    timestamp = started_at.strftime("%Y-%m-%d_%H-%M-%S")
    sources = None

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
        microphone_device = select_microphone(arguments.mic)
        if arguments.system_audio:
            sources = record_microphone_and_system(audio_path, microphone_device)
        else:
            sources = record_until_interrupt(audio_path, microphone_device=microphone_device)

    audio_format = read_audio_format(audio_path)
    ensure_audio_within_size_limit(audio_path)
    response = transcribe_audio(audio_path, audio_format, api_key, arguments.model, arguments.speakers)
    warn_if_speaker_labels_missing(response)

    SCRIPT_DIRECTORY.joinpath("transcripts").mkdir(exist_ok=True)
    markdown_path = SCRIPT_DIRECTORY / "transcripts" / f"{timestamp}.md"
    json_path = SCRIPT_DIRECTORY / "transcripts" / f"{timestamp}.json"
    write_transcript_markdown(
        markdown_path, response, audio_path.name, started_at, sources
    )
    write_transcript_json(json_path, response)
    print(f"Wrote transcript: {markdown_path}")
    print(f"Wrote raw API JSON: {json_path}")


if __name__ == "__main__":
    main()
