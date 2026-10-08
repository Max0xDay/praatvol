#!/usr/bin/env python3
"""Compare cached OpenRouter transcriptions of lossless and compressed meeting audio."""

import argparse
import base64
from collections import Counter
from decimal import Decimal
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import unicodedata

import requests
import soundfile
from dotenv import load_dotenv

DIRECTORY = Path(__file__).resolve().parent
WORK = DIRECTORY / "work"
POC = DIRECTORY.parent / "poc"
SOURCE = POC / "recordings/2026-10-08_10-15-41.flac"
REFERENCE = POC / "transcripts/2026-10-08_10-15-41.json"
MODEL = "elevenlabs/scribe-v2"
ENDPOINT = "https://openrouter.ai/api/v1/audio/transcriptions"
BITRATES_KBPS = (64, 48, 32, 24)
SPEND_CAP_USD = Decimal("0.40")
# #COMPLETION_DRIVE: Interpret the documented 25 MB audio limit as decimal bytes.
# #SUGGEST_VERIFY: Check the current OpenRouter limit before using these estimates elsewhere.
MAX_AUDIO_BYTES = 25_000_000


def save_json(path, content):
    staging_path = path.with_suffix(path.suffix + ".partial")
    staging_path.write_text(json.dumps(content, indent=2, ensure_ascii=False) + "\n")
    staging_path.replace(path)


def read_json(path):
    return json.loads(path.read_text())


def normalized_words(transcript):
    words = transcript.get("words")
    if not words:
        raise ValueError("Transcript has no word timestamps.")
    normalized = []
    for word in words:
        token = "".join(character for character in word["word"].lower()
                        if not unicodedata.category(character).startswith("P"))
        normalized.extend((part, word.get("speaker")) for part in token.split())
    if not normalized:
        raise ValueError("Transcript contains no normalized words.")
    return normalized


def edit_alignment(reference_words, variant_words):
    """Exact Levenshtein alignment; ties prefer diagonal, then deletion, then insertion."""
    previous = list(range(len(variant_words) + 1))
    directions = [bytearray([2] * (len(variant_words) + 1))]
    for reference_index, reference_word in enumerate(reference_words, 1):
        current = [reference_index]
        direction_row = bytearray(len(variant_words) + 1)
        direction_row[0] = 1
        for variant_index, variant_word in enumerate(variant_words, 1):
            diagonal = previous[variant_index - 1] + (reference_word[0] != variant_word[0])
            deletion = previous[variant_index] + 1
            insertion = current[-1] + 1
            minimum = min(diagonal, deletion, insertion)
            current.append(minimum)
            direction_row[variant_index] = 0 if minimum == diagonal else (1 if minimum == deletion else 2)
        directions.append(direction_row)
        previous = current
    matched = []
    reference_index, variant_index = len(reference_words), len(variant_words)
    while reference_index or variant_index:
        direction = directions[reference_index][variant_index]
        if direction == 0:
            reference_index -= 1
            variant_index -= 1
            if reference_words[reference_index][0] == variant_words[variant_index][0]:
                matched.append((reference_words[reference_index][1], variant_words[variant_index][1]))
        elif direction == 1:
            reference_index -= 1
        else:
            variant_index -= 1
    return previous[-1], matched


def best_speaker_agreement(matched):
    """Maximum-weight one-to-one mapping, allowing unmatched predicted speakers."""
    if not matched:
        return None
    pair_counts = Counter((reference, predicted) for reference, predicted in matched
                          if reference is not None if predicted is not None)
    reference_speakers = sorted({reference for reference, _ in pair_counts}, key=str)
    predicted_speakers = sorted({predicted for _, predicted in pair_counts}, key=str)
    mapping_scores = {0: 0}
    for predicted in predicted_speakers:
        next_scores = dict(mapping_scores)
        for used_mask, score in mapping_scores.items():
            for reference_index, reference in enumerate(reference_speakers):
                speaker_bit = 1 << reference_index
                if used_mask & speaker_bit:
                    continue
                new_mask = used_mask | speaker_bit
                new_score = score + pair_counts[(reference, predicted)]
                next_scores[new_mask] = max(next_scores.get(new_mask, 0), new_score)
        mapping_scores = next_scores
    return 100 * max(mapping_scores.values()) / len(matched)


def quality_metrics(reference, variant):
    reference_words = normalized_words(reference)
    variant_words = normalized_words(variant)
    distance, matched = edit_alignment(reference_words, variant_words)
    return {
        "wer_percent": 100 * distance / len(reference_words),
        "speaker_agreement_percent": best_speaker_agreement(matched),
        "speakers": len({word.get("speaker") for word in variant["words"]
                         if word.get("speaker") is not None}),
        "matched_words": len(matched),
        "reference_words": len(reference_words),
        "edit_distance": distance,
    }


def audio_metrics(path, duration_seconds):
    size_bytes = path.stat().st_size
    return {
        "actual_kbps": size_bytes * 8 / duration_seconds / 1000,
        "size_mb": size_bytes / 1_000_000,
        "mb_per_minute": size_bytes / 1_000_000 / (duration_seconds / 60),
        "max_minutes_per_request": MAX_AUDIO_BYTES / size_bytes * duration_seconds / 60,
    }


def encode_opus(samples, sample_rate_hz, target_kbps, duration_seconds):
    path = WORK / f"opus_{target_kbps}.ogg"
    if path.exists():
        encoded_duration_seconds = soundfile.info(path).duration
        if abs(encoded_duration_seconds - duration_seconds) <= 1 / sample_rate_hz:
            actual_kbps = audio_metrics(path, duration_seconds)["actual_kbps"]
            if abs(actual_kbps / target_kbps - 1) <= 0.05:
                return path, None
    probe_samples = samples[:sample_rate_hz * 30]
    probe_path = WORK / "opus_probe.ogg"
    probe_duration_seconds = len(probe_samples) / sample_rate_hz
    lower_level, upper_level = 0.0, 1.0
    for _ in range(12):
        compression_level = (lower_level + upper_level) / 2
        soundfile.write(probe_path, probe_samples, sample_rate_hz, format="OGG", subtype="OPUS",
                        compression_level=compression_level)
        actual_kbps = audio_metrics(probe_path, probe_duration_seconds)["actual_kbps"]
        if abs(actual_kbps / target_kbps - 1) <= 0.02:
            break
        if actual_kbps > target_kbps:
            lower_level = compression_level
        else:
            upper_level = compression_level
    soundfile.write(path, samples, sample_rate_hz, format="OGG", subtype="OPUS",
                    compression_level=compression_level)
    actual_kbps = audio_metrics(path, duration_seconds)["actual_kbps"]
    if abs(actual_kbps / target_kbps - 1) <= 0.05:
        return path, compression_level
    raise RuntimeError(f"Could not calibrate Opus to within 5% of {target_kbps} kbps.")


def prepare_variants(duration_seconds):
    manifest_path = WORK / "audio_manifest.json"
    source_digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    if manifest_path.exists():
        manifest = read_json(manifest_path)
        if manifest["source_sha256"] != source_digest:
            raise ValueError("Source changed; cached experiment must not be reused.")
        for variant in manifest["variants"]:
            path = Path(variant["path"])
            if hashlib.sha256(path.read_bytes()).hexdigest() != variant["audio_sha256"]:
                raise ValueError("Cached audio changed; refusing to reuse results.")
        return manifest["variants"]
    variants = [{"variant": "FLAC repeat", "codec": "FLAC (lossless)", "path": str(SOURCE),
                 "cache_name": "flac_repeat", "target_kbps": None}]
    samples, sample_rate_hz = soundfile.read(SOURCE, dtype="float32")
    if samples.ndim != 1:
        raise ValueError("The specified source must be mono.")
    compressed = []
    try:
        for target_kbps in BITRATES_KBPS:
            path, level = encode_opus(samples, sample_rate_hz, target_kbps, duration_seconds)
            compressed.append({"variant": f"{target_kbps} kbps", "codec": "Opus/Ogg (VBR)",
                               "path": str(path), "cache_name": f"compressed_{target_kbps}",
                               "target_kbps": target_kbps, "compression_level": level})
    except (ValueError, RuntimeError) as error:
        print(f"Opus calibration failed ({type(error).__name__}); using AAC for all four rates.",
              file=sys.stderr)
        compressed = prepare_aac(samples, sample_rate_hz)
    variants.extend(compressed)
    for variant in variants:
        path = Path(variant["path"])
        variant.update(audio_metrics(path, duration_seconds))
        variant["audio_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    save_json(manifest_path, {"source_sha256": source_digest, "variants": variants})
    return variants


def prepare_aac(samples, sample_rate_hz):
    wave_path = WORK / "source.wav"
    soundfile.write(wave_path, samples, sample_rate_hz, subtype="PCM_16")
    variants = []
    for target_kbps in BITRATES_KBPS:
        path = WORK / f"aac_{target_kbps}.m4a"
        subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b",
                        str(target_kbps * 1000), str(wave_path), str(path)],
                       check=True, capture_output=True, timeout=180)
        variants.append({"variant": f"{target_kbps} kbps", "codec": "AAC/m4a",
                         "path": str(path), "cache_name": f"compressed_{target_kbps}",
                         "target_kbps": target_kbps})
    return variants


def committed_spend():
    committed = Decimal("0")
    for attempt_path in WORK.glob("*_attempt.json"):
        attempt = read_json(attempt_path)
        response_path = WORK / attempt["response_file"]
        if response_path.exists():
            cached = read_json(response_path)
            cost = (cached.get("response", {}).get("usage") or {}).get("cost")
            if cost is not None:
                committed += Decimal(str(cost))
                continue
        committed += Decimal(attempt["reserved_cost_usd"])
    return committed


def cached_response(variant):
    path = WORK / f"{variant['cache_name']}_response.json"
    if not path.exists():
        return None
    cached = read_json(path)
    if cached["audio_sha256"] != variant["audio_sha256"]:
        raise ValueError("Cached response does not match audio.")
    if cached["status_code"] != 200:
        raise RuntimeError(f"Cached HTTP {cached['status_code']}; no automatic retry.")
    if (cached["response"].get("usage") or {}).get("cost") is None:
        raise ValueError("Cached response has no reported cost; reservation remains charged.")
    return cached


def transcribe(variant, api_key, reserved_cost_usd):
    cached = cached_response(variant)
    if cached is not None:
        print(f"Using cached {variant['variant']}", flush=True)
        return cached
    attempt_path = WORK / f"{variant['cache_name']}_attempt.json"
    if attempt_path.exists():
        raise RuntimeError("A prior attempt has no usable response; refusing another paid POST.")
    if committed_spend() + reserved_cost_usd > SPEND_CAP_USD:
        raise RuntimeError("Spend cap would be exceeded by the next reserved request.")
    audio_path = Path(variant["path"])
    if audio_path.stat().st_size > MAX_AUDIO_BYTES:
        raise ValueError("Audio exceeds the 25 MB request limit.")
    payload = {
        "model": MODEL,
        "input_audio": {"data": base64.b64encode(audio_path.read_bytes()).decode("ascii"),
                        "format": audio_path.suffix.lstrip(".")},
        "response_format": "verbose_json",
        "timestamp_granularities": ["segment", "word"],
        "provider": {"options": {"elevenlabs": {"diarize": True}}},
    }
    response_path = WORK / f"{variant['cache_name']}_response.json"
    save_json(attempt_path, {"reserved_cost_usd": str(reserved_cost_usd),
                            "response_file": response_path.name,
                            "audio_sha256": variant["audio_sha256"]})
    print(f"Sending {variant['variant']} ({variant['actual_kbps']:.2f} kbps)...", flush=True)
    started_seconds = time.monotonic()
    # No retry: an interrupted or failed request may already have been billed.
    response = requests.post(ENDPOINT, headers={"Authorization": f"Bearer {api_key}"},
                             json=payload, timeout=(10, 120))
    latency_seconds = time.monotonic() - started_seconds
    try:
        response_content = response.json()
    except ValueError:
        print("Non-JSON response; caching privately and stopping without retry.", file=sys.stderr)
        response_content = {"raw_response": response.text}
    save_json(response_path, {"response": response_content, "latency_seconds": latency_seconds,
                              "status_code": response.status_code,
                              "audio_sha256": variant["audio_sha256"]})
    if committed_spend() > SPEND_CAP_USD:
        raise RuntimeError("Reported spend exceeded the cap; stopped immediately.")
    return cached_response(variant)


def within_noise(variant, noise_floor):
    if variant["wer_percent"] > noise_floor["wer_percent"]:
        return False
    agreement = variant["speaker_agreement_percent"]
    if agreement is None:
        return False
    noise_agreement = noise_floor["speaker_agreement_percent"]
    if noise_agreement is None:
        return False
    return agreement >= noise_agreement


def write_report(rows, duration_seconds, reference):
    qualifying = [row for row in rows[1:] if within_noise(row, rows[0])]
    if qualifying:
        best = min(qualifying, key=lambda row: row["target_kbps"])
        recommendation = (f"**{best['variant']} {best['codec']} is the lowest tested bitrate within "
                          "the FLAC-repeat noise on both metrics.**")
    else:
        recommendation = "**None of the tested lossy bitrates qualifies on both metrics. Keep lossless FLAC.**"
    lines = [
        "# Compression quality experiment", "", "## Run", "", "```bash",
        "experiments/poc/.venv/bin/python experiments/compression-quality/run_experiment.py", "```", "",
        "Use `--prepare-only` to encode without API calls; `--analyze-only` requires all responses cached.",
        "Re-running uses the cached audio and responses; never retries a paid POST automatically.", "",
        "## Method", "",
        f"Source: `2026-10-08_10-15-41.flac`, {duration_seconds / 60:.3f} minutes, 16 kHz mono; "
        "reference: the existing transcript with the same basename in `experiments/poc/transcripts/`.",
        f"Model: `{MODEL}` through OpenRouter, verbose JSON, segment/word timestamps and "
        "`provider.options.elevenlabs.diarize: true`; no speaker-count hint. Same options as the PoC.",
        "The original transcript is an automated reference, **not a human-verified ground truth**. "
        "These metrics measure change, not absolute transcription or diarization accuracy.", "",
        "Codec probe: soundfile 0.14.0 / libsndfile 1.2.2 supports Opus in Ogg. "
        "`bitrate_mode='CONSTANT'` failed; `compression_level` successfully controls variable bitrate. "
        "Binary-search calibration on a 30-second excerpt selects the encoder setting; "
        "each final full-length file must measure within 5% of its target. Completed in-range files "
        "from an interrupted preparation can be reused after duration and bitrate checks. "
        "All four variants use one codec. AAC via built-in `afconvert` is the fallback only if Opus calibration fails.",
        f"Selected codec: **{rows[1]['codec']}**. Actual bitrate includes container overhead and is "
        "measured as file bytes × 8 / original duration, not taken from the encoder target.", "",
        "WER: lowercase; remove Unicode punctuation (including internal punctuation); split whitespace; "
        "discard empty tokens. Exact word-level Levenshtein distance / reference token count. "
        "Alignment ties prefer diagonal, then deletion, then insertion. Speaker agreement uses only "
        "exact lexical matches from that alignment and fits the globally optimal one-to-one speaker "
        "mapping independently for each variant. Extra/unlabelled speakers cannot match; missing labels "
        "remain in the denominator. Speaker count includes all non-null returned word labels. "
        "Repeated words can make lexical alignment ambiguous; timestamps do not affect the metric.", "",
        "The **FLAC repeat is the observed run-to-run noise floor**, based on only one repeat. "
        "A lossy variant qualifies only if its WER is no higher AND speaker agreement no lower than this repeat. "
        "No extra tolerance or statistical significance is inferred from this small sample.", "",
        "## Results", "",
        "MB and kbps are decimal; max minutes assumes a 25,000,000-byte audio limit.", "",
        "| Variant | Codec | Actual kbps | Size MB | MB/min | Max min / 25 MB | WER % | Speaker agreement % | Speakers | Latency s | Cost USD |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        label = row["variant"] + (" **(noise floor)**" if row is rows[0] else "")
        agreement = row["speaker_agreement_percent"]
        agreement_text = "N/A" if agreement is None else f"{agreement:.2f}"
        lines.append(f"| {label} | {row['codec']} | {row['actual_kbps']:.2f} | {row['size_mb']:.3f} "
                     f"| {row['mb_per_minute']:.3f} | {row['max_minutes_per_request']:.1f} "
                     f"| {row['wer_percent']:.2f} | {agreement_text} | {row['speakers']} "
                     f"| {row['latency_seconds']:.2f} | ${row['cost_usd']:.6f} |")
    append_report_details(lines, rows, reference, recommendation)
    (DIRECTORY / "README.md").write_text("\n".join(lines) + "\n")


def append_report_details(lines, rows, reference, recommendation):
    lines.extend(["", f"Total reported API spend: **${sum(row['cost_usd'] for row in rows):.6f}**, "
                  f"cap $0.40. Original reference cost (not part of this run): "
                  f"${reference['usage']['cost']:.6f}.", "", "## Latency extrapolation — estimates only", "",
                  "Measured latency is wall time from starting POST to receiving the complete response, "
                  "including client upload/serialization and gateway overhead. It is not a measurement "
                  "of the provider's upstream processing time alone.", "",
                  "**Rough safe-length estimate:** assume latency scales linearly with duration, allow "
                  "48 seconds (20% margin below the documented 60-second upstream timeout), then take "
                  "the smaller of `original_minutes × 48 / measured_latency` and the 25 MB size limit. "
                  "One observation per variant cannot establish a real maximum; overhead, server load, "
                  "nonlinear scaling and longer-audio diarization can invalidate this extrapolation. "
                  "Validate with actual longer recordings before relying on it.", "",
                  "| Variant | Matched words | Rough safe min (size + latency) |", "|---|---:|---:|"])
    for row in rows:
        lines.append(f"| {row['variant']} | {row['matched_words']} | {row['estimated_safe_minutes']:.1f} |")
    lines.extend(["", "## Recommendation", "", recommendation,
                  "This is only a recommendation for this recording/model, not a change to the product's "
                  "lossless-only policy. Repeat trials and human review are needed for general conclusions.", "",
                  "## Spend, caching and privacy", "",
                  "The key is loaded with python-dotenv from `experiments/poc/.env` (or the environment) "
                  "and is never printed or persisted. Audio, every HTTP response, latency, hashes, and "
                  "per-request spend reservations are saved only under ignored `work/`. "
                  "Attempt markers are written before POST; interruptions cannot silently trigger a second charge. "
                  "Run only one instance at a time. Failures stop the run without automatic POST retries.", "",
                  "#COMPLETION_DRIVE: Budget reservation assumes unchanged duration-based pricing and "
                  "reserves twice the original reported cost before each POST. Failed/unknown-cost attempts "
                  "retain that reservation. Reported costs are checked after each response, but a vendor "
                  "price jump above that reserve cannot be prevented by a client-side estimate.",
                  "#SUGGEST_VERIFY: Verify current model pricing before future paid runs; use a server-side "
                  "key limit if a strict billing hard stop is needed.", "",
                  "No meeting content is included in this README. Do not commit the private `work/` directory."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--prepare-only", action="store_true")
    modes.add_argument("--analyze-only", action="store_true")
    arguments = parser.parse_args()
    WORK.mkdir(exist_ok=True)
    reference = read_json(REFERENCE)
    source_info = soundfile.info(SOURCE)
    duration_seconds = source_info.duration
    variants = prepare_variants(duration_seconds)
    if arguments.prepare_only:
        for variant in variants:
            print(f"{variant['variant']}: {variant['codec']}, {variant['actual_kbps']:.2f} kbps, "
                  f"{variant['size_mb']:.3f} MB")
        return
    api_key = None
    if not arguments.analyze_only:
        load_dotenv(POC / ".env")
        api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
        if not api_key:
            raise ValueError("OPENROUTER_API_KEY is missing; key was not logged.")
    # #COMPLETION_DRIVE: Unchanged duration pricing; a 2x reference-cost reservation covers each call.
    # #SUGGEST_VERIFY: Check current pricing or set an OpenRouter key spending limit before later runs.
    reserved_cost_usd = Decimal(str(reference["usage"]["cost"])) * 2
    rows = []
    for variant in variants:
        cached = (cached_response(variant) if arguments.analyze_only
                  else transcribe(variant, api_key, reserved_cost_usd))
        if cached is None:
            raise ValueError(f"Missing cached response for {variant['variant']}.")
        latency_seconds = cached["latency_seconds"]
        if latency_seconds <= 0:
            raise ValueError("Request latency must be positive.")
        cost_usd = float(cached["response"]["usage"]["cost"])
        if not math.isfinite(cost_usd):
            raise ValueError("Reported cost must be finite.")
        row = {**variant, **quality_metrics(reference, cached["response"]),
               "latency_seconds": latency_seconds, "cost_usd": cost_usd}
        # #COMPLETION_DRIVE: Linear latency scaling with a 20% margin below 60 seconds is only an estimate.
        # #SUGGEST_VERIFY: Test longer recordings; one duration cannot establish a safe upstream timeout bound.
        row["estimated_safe_minutes"] = min(row["max_minutes_per_request"],
                                             duration_seconds / 60 * 48 / latency_seconds)
        rows.append(row)
        print(f"{variant['variant']}: WER {row['wer_percent']:.2f}%, "
              f"speaker agreement {row['speaker_agreement_percent']}, cost ${cost_usd:.6f}", flush=True)
    save_json(WORK / "metrics.json", rows)
    write_report(rows, duration_seconds, reference)
    print(f"Wrote {DIRECTORY / 'README.md'}; total committed spend ${committed_spend():.6f}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print HTTP bodies, request objects or credentials on an error path.
        if isinstance(error, requests.RequestException):
            message = f"HTTP request failed ({type(error).__name__}); no retry; reservation retained."
        else:
            message = str(error)
        print(f"Error: {message}", file=sys.stderr)
        sys.exit(1)
