# Compression quality experiment

## Run

```bash
experiments/poc/.venv/bin/python experiments/compression-quality/run_experiment.py
```

Use `--prepare-only` to encode without API calls; `--analyze-only` requires all responses cached.
Re-running uses the cached audio and responses; never retries a paid POST automatically.

## Method

Source: `2026-10-08_10-15-41.flac`, 20.237 minutes, 16 kHz mono; reference: the existing transcript with the same basename in `experiments/poc/transcripts/`.
Model: `elevenlabs/scribe-v2` through OpenRouter, verbose JSON, segment/word timestamps and `provider.options.elevenlabs.diarize: true`; no speaker-count hint. Same options as the PoC.
The original transcript is an automated reference, **not a human-verified ground truth**. These metrics measure change, not absolute transcription or diarization accuracy.

Codec probe: soundfile 0.14.0 / libsndfile 1.2.2 supports Opus in Ogg. `bitrate_mode='CONSTANT'` failed; `compression_level` successfully controls variable bitrate. Binary-search calibration on a 30-second excerpt selects the encoder setting; each final full-length file must measure within 5% of its target. Completed in-range files from an interrupted preparation can be reused after duration and bitrate checks. All four variants use one codec. AAC via built-in `afconvert` is the fallback only if Opus calibration fails.
Selected codec: **Opus/Ogg (VBR)**. Actual bitrate includes container overhead and is measured as file bytes × 8 / original duration, not taken from the encoder target.

WER: lowercase; remove Unicode punctuation (including internal punctuation); split whitespace; discard empty tokens. Exact word-level Levenshtein distance / reference token count. Alignment ties prefer diagonal, then deletion, then insertion. Speaker agreement uses only exact lexical matches from that alignment and fits the globally optimal one-to-one speaker mapping independently for each variant. Extra/unlabelled speakers cannot match; missing labels remain in the denominator. Speaker count includes all non-null returned word labels. Repeated words can make lexical alignment ambiguous; timestamps do not affect the metric.

The **FLAC repeat is the observed run-to-run noise floor**, based on only one repeat. A lossy variant qualifies only if its WER is no higher AND speaker agreement no lower than this repeat. No extra tolerance or statistical significance is inferred from this small sample.

## Results

MB and kbps are decimal; max minutes assumes a 25,000,000-byte audio limit.

> **Note:** this experiment used the documented 25 MB cap and 60 s timeout. The later [limits test](../limits-test/README.md) measured the real limits: a 50 MiB request body, with 60 min and 90 min single requests succeeding.

| Variant | Codec | Actual kbps | Size MB | MB/min | Max min / 25 MB | WER % | Speaker agreement % | Speakers | Latency s | Cost USD |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FLAC repeat **(noise floor)** | FLAC (lossless) | 158.63 | 24.076 | 1.190 | 21.0 | 2.14 | 98.64 | 3 | 35.00 | $0.037101 |
| 64 kbps | Opus/Ogg (VBR) | 61.66 | 9.359 | 0.462 | 54.1 | 2.11 | 98.53 | 3 | 27.13 | $0.037101 |
| 48 kbps | Opus/Ogg (VBR) | 49.31 | 7.483 | 0.370 | 67.6 | 2.60 | 99.72 | 3 | 26.11 | $0.037101 |
| 32 kbps | Opus/Ogg (VBR) | 31.60 | 4.795 | 0.237 | 105.5 | 3.45 | 99.86 | 3 | 23.97 | $0.037101 |
| 24 kbps | Opus/Ogg (VBR) | 23.47 | 3.563 | 0.176 | 142.0 | 3.28 | 100.00 | 3 | 17.66 | $0.037101 |

Total reported API spend: **$0.185504**, cap $0.40. Original reference cost (not part of this run): $0.037101.

## Latency extrapolation — estimates only

Measured latency is wall time from starting POST to receiving the complete response, including client upload/serialization and gateway overhead. It is not a measurement of the provider's upstream processing time alone.

**Rough safe-length estimate:** assume latency scales linearly with duration, allow 48 seconds (20% margin below the documented 60-second upstream timeout), then take the smaller of `original_minutes × 48 / measured_latency` and the 25 MB size limit. One observation per variant cannot establish a real maximum; overhead, server load, nonlinear scaling and longer-audio diarization can invalidate this extrapolation. Validate with actual longer recordings before relying on it.

| Variant | Matched words | Rough safe min (size + latency) |
|---|---:|---:|
| FLAC repeat | 3603 | 21.0 |
| 64 kbps | 3600 | 35.8 |
| 48 kbps | 3583 | 37.2 |
| 32 kbps | 3557 | 40.5 |
| 24 kbps | 3563 | 55.0 |

## Recommendation

**None of the tested lossy bitrates qualifies on both metrics. Keep lossless FLAC.**
This is only a recommendation for this recording/model, not a change to the product's lossless-only policy. Repeat trials and human review are needed for general conclusions.

## Spend, caching and privacy

The key is loaded with python-dotenv from `experiments/poc/.env` (or the environment) and is never printed or persisted. Audio, every HTTP response, latency, hashes, and per-request spend reservations are saved only under ignored `work/`. Attempt markers are written before POST; interruptions cannot silently trigger a second charge. Run only one instance at a time. Failures stop the run without automatic POST retries.

#COMPLETION_DRIVE: Budget reservation assumes unchanged duration-based pricing and reserves twice the original reported cost before each POST. Failed/unknown-cost attempts retain that reservation. Reported costs are checked after each response, but a vendor price jump above that reserve cannot be prevented by a client-side estimate.
#SUGGEST_VERIFY: Verify current model pricing before future paid runs; use a server-side key limit if a strict billing hard stop is needed.

No meeting content is included in this README. Do not commit the private `work/` directory.
