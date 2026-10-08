#!/usr/bin/env python3
"""Probe 60- and 90-minute OpenRouter STT requests, then 40 minutes if 60 times out.

Repeat the source recording and calibrate Opus/Ogg. Paid POSTs are never retried;
attempt markers prevent duplicate sends, and the HTTP timeout is 20 minutes.
Only Test 5 is fitted below the measured 50 MiB JSON body limit before sending.
"""

import base64
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import numpy
import requests
import soundfile
from dotenv import load_dotenv

DIRECTORY = Path(__file__).resolve().parent
WORK = DIRECTORY / "work"
SOURCE_PATH = DIRECTORY.parent / "speaker-continuity" / "work" / "normalized.flac"
FALLBACK_SOURCE_PATH = Path.home() / "Downloads" / "New Recording.m4a"
ENVIRONMENT_PATH = DIRECTORY.parent / "poc" / ".env"
ENDPOINT = "https://openrouter.ai/api/v1/audio/transcriptions"
MODEL = "elevenlabs/scribe-v2"
SAMPLE_RATE_HZ = 16000
SECONDS_PER_HOUR = 3600
GAP_SECONDS = 1
BODY_LIMIT_BYTES = 52_428_800
SECONDS_PER_SPEAKER_BLOCK = 30 * 60
# #COMPLETION_DRIVE: up to 15 seconds without a final word can represent trailing silence.
# #SUGGEST_VERIFY: review end_gap_seconds against the source if completeness is uncertain.
END_GAP_TOLERANCE_SECONDS = 15
# #COMPLETION_DRIVE: price per audio hour comes from the earlier $0.11/h measurement, not a
#   current OpenRouter price list.
# #SUGGEST_VERIFY: compare with usage.cost in the first successful response.
ESTIMATED_COST_USD_PER_HOUR = Decimal("0.11")
HTTP_TIMEOUT_SECONDS = 20 * 60
ERROR_BODY_LIMIT_BYTES = 2048
RELEVANT_HEADER_KEYWORDS = ("limit", "retry", "timeout", "size", "length", "date", "request-id")
# #COMPLETION_DRIVE: any 4xx except 429 whose body mentions these words is a size rejection.
#   "limit" alone could also match other limit errors.
# #SUGGEST_VERIFY: read the saved error body of each rejected request before relying on the label.
SIZE_REJECTION_PATTERN = re.compile(r"size|payload|limit|too large|exceed|\bMB\b|bytes", re.IGNORECASE)
RATE_LIMITED_STATUS_CODE = 429
PAYLOAD_TOO_LARGE_STATUS_CODE = 413
PROBE_SECONDS = 30
CALIBRATION_ITERATIONS = 12
PROBE_TOLERANCE_FRACTION = 0.02
FULL_TRACK_TOLERANCE_FRACTION = 0.05


def save_json(path, content):
    staging_path = path.with_suffix(path.suffix + ".partial")
    staging_path.write_text(json.dumps(content, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    staging_path.replace(path)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


def load_api_key():
    load_dotenv(ENVIRONMENT_PATH)
    api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("OPENROUTER_API_KEY is not set in experiments/poc/.env or the environment.")
    return api_key


def decode_fallback_source():
    # #COMPLETION_DRIVE: this path is only used when the FLAC is missing. It has not been run here.
    # #SUGGEST_VERIFY: check that the decoded duration is about 16 min 56 s.
    decoded_path = WORK / "source_fallback_16k_mono.wav"
    subprocess.run(
        ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
         str(FALLBACK_SOURCE_PATH), str(decoded_path)],
        check=True, capture_output=True, timeout=600,
    )
    return decoded_path


def load_source_samples():
    source_path = SOURCE_PATH
    if not source_path.is_file():
        print(f"Source FLAC missing; decoding {FALLBACK_SOURCE_PATH.name} with afconvert.")
        source_path = decode_fallback_source()
    samples, sample_rate_hz = soundfile.read(source_path, dtype="int16")
    if samples.ndim != 1 or sample_rate_hz != SAMPLE_RATE_HZ:
        raise RuntimeError(
            f"Source must be 16 kHz mono; got {sample_rate_hz} Hz with {samples.ndim} dimension(s)."
        )
    print(f"Source: {len(samples) / SAMPLE_RATE_HZ:.1f} s, 16 kHz mono")
    return samples


def repeated_segments(source_samples):
    gap_samples = numpy.zeros(GAP_SECONDS * SAMPLE_RATE_HZ, dtype=source_samples.dtype)
    yield source_samples
    while True:
        yield gap_samples
        yield source_samples


def iter_track_blocks(source_samples, target_sample_count):
    remaining_sample_count = target_sample_count
    for segment in repeated_segments(source_samples):
        block = segment[:remaining_sample_count]
        yield block
        remaining_sample_count -= len(block)
        if remaining_sample_count == 0:
            return


def write_opus(audio_path, blocks, compression_level):
    with soundfile.SoundFile(
        audio_path, mode="w", samplerate=SAMPLE_RATE_HZ, channels=1,
        format="OGG", subtype="OPUS", compression_level=compression_level,
    ) as audio_file:
        for block in blocks:
            audio_file.write(block)


def kilobits_per_second(audio_path, duration_seconds):
    return audio_path.stat().st_size * 8 / duration_seconds / 1000


def calibrate_compression_level(source_samples, target_kilobits_per_second):
    # Same binary search as encode_opus in experiments/compression-quality/run_experiment.py.
    probe_samples = source_samples[: PROBE_SECONDS * SAMPLE_RATE_HZ]
    probe_duration_seconds = len(probe_samples) / SAMPLE_RATE_HZ
    probe_path = WORK / "calibration_probe.ogg"
    lower_level, upper_level = 0.0, 1.0
    compression_level = 0.5
    for _ in range(CALIBRATION_ITERATIONS):
        compression_level = (lower_level + upper_level) / 2
        write_opus(probe_path, [probe_samples], compression_level)
        measured = kilobits_per_second(probe_path, probe_duration_seconds)
        if abs(measured / target_kilobits_per_second - 1) <= PROBE_TOLERANCE_FRACTION:
            break
        if measured > target_kilobits_per_second:
            lower_level = compression_level
        else:
            upper_level = compression_level
    return compression_level


def encode_track(audio_path, source_samples, duration_seconds, target_kilobits_per_second, compression_level):
    target_sample_count = round(duration_seconds * SAMPLE_RATE_HZ)
    write_opus(audio_path, iter_track_blocks(source_samples, target_sample_count), compression_level)
    encoded_seconds = soundfile.info(audio_path).duration
    measured = kilobits_per_second(audio_path, encoded_seconds)
    if abs(measured / target_kilobits_per_second - 1) > FULL_TRACK_TOLERANCE_FRACTION:
        raise RuntimeError(
            f"Full track encoded at {measured:.2f} kbps, outside 5% of "
            f"{target_kilobits_per_second} kbps. Not sent."
        )
    return encoded_seconds, measured


def build_request_body(audio_path):
    audio_base64 = base64.b64encode(audio_path.read_bytes()).decode("ascii")
    payload = {
        "model": MODEL,
        "input_audio": {"data": audio_base64, "format": "ogg"},
        "response_format": "verbose_json",
        "timestamp_granularities": ["word"],
        "provider": {"options": {"elevenlabs": {"diarize": True}}},
    }
    return json.dumps(payload).encode("utf-8")


def estimate_cost_usd(duration_seconds):
    return ESTIMATED_COST_USD_PER_HOUR * Decimal(duration_seconds) / SECONDS_PER_HOUR


def parse_json_or_none(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def is_size_rejection(status_code, body_text):
    if status_code == PAYLOAD_TOO_LARGE_STATUS_CODE:
        return True
    client_error = 400 <= status_code < 500
    return (client_error and status_code != RATE_LIMITED_STATUS_CODE
            and SIZE_REJECTION_PATTERN.search(body_text) is not None)


def contains_transcript(response_json):
    if not isinstance(response_json, dict):
        return False
    return bool(response_json.get("text") or response_json.get("words"))


def classify_outcome(status_code, body_text):
    if status_code == 200:
        response_json = parse_json_or_none(body_text)
        if isinstance(response_json, dict):
            if "error" in response_json:
                return "provider_error_in_200"
        return "success" if contains_transcript(response_json) else "missing_transcript"
    if is_size_rejection(status_code, body_text):
        return "size_rejected"
    return "http_error"


def is_timeout_failure(record):
    if record["outcome"] == "success":
        return False
    return re.search(r"524|timeout|timed out", record.get("error_body") or "", re.IGNORECASE) is not None


def limited_error_body(body_text):
    return body_text.encode("utf-8")[:ERROR_BODY_LIMIT_BYTES].decode("utf-8", errors="ignore")


def relevant_headers(response):
    return {
        name: value for name, value in response.headers.items()
        if any(keyword in name.lower() for keyword in RELEVANT_HEADER_KEYWORDS)
    }


def reported_cost_usd(response_json):
    if not isinstance(response_json, dict):
        return None
    cost = (response_json.get("usage") or {}).get("cost")
    return None if cost is None else Decimal(str(cost))


def summarise_success(response_json, duration_seconds):
    words = response_json.get("words") or []
    usage = response_json.get("usage") or {}
    block_count = int(numpy.ceil(duration_seconds / SECONDS_PER_SPEAKER_BLOCK))
    speakers_by_block = {block: set() for block in range(block_count)}
    for word in words:
        speaker = word.get("speaker")
        if speaker is None:
            continue
        block = int(word["start"] // SECONDS_PER_SPEAKER_BLOCK)
        speakers_by_block.setdefault(block, set()).add(speaker)
    all_speakers = set().union(*speakers_by_block.values())
    word_end_seconds = [word["end"] for word in words]
    last_word_end_seconds = max(word_end_seconds) if word_end_seconds else None
    end_gap_seconds = None if last_word_end_seconds is None else duration_seconds - last_word_end_seconds
    return {
        "usage_seconds": usage.get("seconds"),
        "usage_cost_usd": usage.get("cost"),
        "word_count": len(words),
        "speaker_count": len(all_speakers),
        "speaker_count_per_30_minutes": {
            block: len(speakers) for block, speakers in sorted(speakers_by_block.items())
        },
        "last_word_end_seconds": last_word_end_seconds,
        "audio_duration_seconds": duration_seconds,
        "end_gap_seconds": end_gap_seconds,
        "transcript_reaches_end": transcript_reaches_end(end_gap_seconds),
    }


def transcript_reaches_end(end_gap_seconds):
    if end_gap_seconds is None:
        return False
    return 0 <= end_gap_seconds <= END_GAP_TOLERANCE_SECONDS


def record_response(record, response, latency_seconds, reserved_cost_usd, body_path):
    body_path.write_text(response.text, encoding="utf-8")
    response_json = parse_json_or_none(response.text)
    outcome = classify_outcome(response.status_code, response.text)
    cost_usd = reported_cost_usd(response_json)
    if cost_usd is None:
        # #COMPLETION_DRIVE: a missing usage.cost does not establish whether this request was billed.
        # #SUGGEST_VERIFY: check the OpenRouter dashboard; cost_usd stays null until confirmed.
        cost_usd = None
    record.update(
        outcome=outcome,
        http_status=response.status_code,
        latency_seconds=round(latency_seconds, 3),
        response_headers=relevant_headers(response),
        error_body=None if outcome == "success" else limited_error_body(response.text),
        cost_usd=None if cost_usd is None else str(cost_usd),
        success_summary=summarise_success(response_json, record["audio_duration_seconds"])
        if outcome == "success" else None,
    )


def record_request_exception(record, error, latency_seconds, reserved_cost_usd):
    record.update(
        outcome="request_exception",
        http_status=None,
        latency_seconds=round(latency_seconds, 3),
        error_body=limited_error_body(f"{type(error).__name__}: {error}"),
        cost_usd=None,
    )


def send_request(record, api_key, body_bytes, body_path, reserved_cost_usd):
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    started_seconds = time.monotonic()
    try:
        response = requests.post(ENDPOINT, headers=headers, data=body_bytes, timeout=HTTP_TIMEOUT_SECONDS)
    except requests.RequestException as error:
        # No retry: the request may already have been billed, so the reservation stays charged.
        record_request_exception(record, error, time.monotonic() - started_seconds, reserved_cost_usd)
        return
    record_response(record, response, time.monotonic() - started_seconds, reserved_cost_usd, body_path)


def base_record(test_key, label, duration_seconds, target_kilobits_per_second, estimated_cost_usd):
    return {
        "test": test_key,
        "label": label,
        "audio_duration_seconds": duration_seconds,
        "target_kilobits_per_second": target_kilobits_per_second,
        "estimated_cost_usd": str(estimated_cost_usd),
        "model": MODEL,
        "timeout_seconds": HTTP_TIMEOUT_SECONDS,
    }


def run_test(test_key, label, duration_seconds, target_kilobits_per_second, source_samples,
             api_key, maximum_size_bytes=None):
    result_path = WORK / f"{test_key}_result.json"
    if result_path.exists():
        print(f"{label}: result already recorded in {result_path.name}; not sending again.")
        return read_json(result_path)
    attempt_path = WORK / f"{test_key}_attempt.json"
    if attempt_path.exists():
        raise RuntimeError(f"{label} has an attempt marker with no saved result; refusing to send again.")
    estimated_cost_usd = estimate_cost_usd(duration_seconds)
    record = base_record(test_key, label, duration_seconds, target_kilobits_per_second, estimated_cost_usd)
    audio_path = WORK / f"{test_key}.ogg"
    body_bytes, encoded_seconds, measured_kilobits, compression_level, fitted_kilobits = prepare_body(
        audio_path, source_samples, duration_seconds, target_kilobits_per_second, maximum_size_bytes
    )
    size_bytes = audio_path.stat().st_size
    record.update(
        audio_file=audio_path.name,
        compression_level=compression_level,
        fitted_target_kilobits_per_second=fitted_kilobits,
        audio_duration_seconds=encoded_seconds,
        actual_kilobits_per_second=round(measured_kilobits, 3),
        audio_size_mb=round(size_bytes / 1_000_000, 3),
        body_size_mb=round(len(body_bytes) / 1_000_000, 3),
        body_size_bytes=len(body_bytes),
        size_bytes=size_bytes,
    )
    save_json(attempt_path, {"started_at": utc_now_iso(), "reserved_cost_usd": str(estimated_cost_usd)})
    print(f"{label}: sending {encoded_seconds / SECONDS_PER_HOUR:.2f} h, "
          f"{measured_kilobits:.2f} kbps, {record['body_size_mb']} MB body...", flush=True)
    send_request(record, api_key, body_bytes, WORK / f"{test_key}_response.json", estimated_cost_usd)
    save_json(result_path, record)
    print_outcome(record)
    return record


def prepare_body(audio_path, source_samples, duration_seconds, target_kilobits_per_second,
                 maximum_body_size_bytes):
    fitted_kilobits = target_kilobits_per_second
    while True:
        compression_level = calibrate_compression_level(source_samples, fitted_kilobits)
        encoded_seconds, measured_kilobits = encode_track(
            audio_path, source_samples, duration_seconds, fitted_kilobits, compression_level
        )
        body_bytes = build_request_body(audio_path)
        if maximum_body_size_bytes is None:
            break
        if len(body_bytes) < maximum_body_size_bytes:
            print(f"Verified body: {len(body_bytes)} bytes < {maximum_body_size_bytes} bytes.")
            break
        # #COMPLETION_DRIVE: body size scales approximately with bitrate for this repeated track.
        # #SUGGEST_VERIFY: re-encode and measure the actual JSON body before any POST.
        fitted_kilobits = int(fitted_kilobits * maximum_body_size_bytes / len(body_bytes) * 0.99)
        if fitted_kilobits < 6:
            raise RuntimeError("Cannot fit Test 5 below the body limit at a usable Opus bitrate.")
        print(f"Body too large; re-encoding locally at {fitted_kilobits} kbps before sending.")
    return body_bytes, encoded_seconds, measured_kilobits, compression_level, fitted_kilobits


def print_outcome(record):
    print(f"{record['label']}: outcome={record['outcome']} HTTP {record['http_status']} "
          f"latency {record['latency_seconds']} s cost ${record['cost_usd']}")
    if record.get("error_body"):
        print(f"  error body (up to {ERROR_BODY_LIMIT_BYTES} bytes): {record['error_body']}")
    if record.get("success_summary"):
        print(f"  success summary: {record['success_summary']}")


def run_sequence(api_key, source_samples):
    test_four = run_test("test4", "Test 4", 60 * 60, 64, source_samples, api_key)
    run_test("test5", "Test 5", 90 * 60, 48, source_samples, api_key,
             maximum_size_bytes=BODY_LIMIT_BYTES)
    if is_timeout_failure(test_four):
        run_test("test6", "Test 6", 40 * 60, 64, source_samples, api_key)


def main():
    WORK.mkdir(exist_ok=True)
    api_key = load_api_key()
    source_samples = load_source_samples()
    run_sequence(api_key, source_samples)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print request objects or headers here; they may contain the key.
        print(f"Error: {type(error).__name__}: {error}")
        raise SystemExit(1)
