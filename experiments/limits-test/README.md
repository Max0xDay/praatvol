# OpenRouter single-request limits test

Question: what single-request recording length works on OpenRouter's `elevenlabs/scribe-v2`, and what body-size and timeout limits have been observed?

**Product recommendation: maximum 60 minutes per request at Opus/Ogg ~64 kbps.** The longest verified success is 90 minutes at ~48 kbps; the absolute maximum is not established.

## Run

```bash
experiments/poc/.venv/bin/python experiments/limits-test/run_limits_test.py
```

The script reads `OPENROUTER_API_KEY` from `experiments/poc/.env` (or the environment). It never prints or saves the key. Audio, responses and the log go to the git-ignored `work/` folder.

The script now runs this follow-up sequence, preserving the earlier results:

1. **Test 4:** 60 min Opus/Ogg at about 64 kbps. Sent once.
2. **Test 5:** 90 min at about 48 kbps. Sent once, regardless of Test 4's result. Measure the complete base64 JSON body before sending; if it is not below 52,428,800 bytes, lower the encoding target just enough and re-measure locally.
3. **Test 6:** only if Test 4 fails with a timeout/524. 40 min at about 64 kbps. Not triggered in this run.

No paid POST is retried automatically. Saved results are reused, and an attempt marker without a result blocks another send. The HTTP client timeout is 20 minutes. There is no general client-side size guard; only Test 5 has the explicitly required pre-send body-fit check. There is no spend cap.

Offline regression tests (no network or key access):

```bash
experiments/poc/.venv/bin/python -m unittest discover -s experiments/limits-test -p 'test_*.py'
```

## Method

- Source: the 16 kHz mono FLAC of a 16 min 56.9 s meeting recording, repeated with 1 s of silence between copies, then trimmed to the requested duration (3 h originally; 60 and 90 min for the follow-up).
- Encoding: soundfile Opus/Ogg, with `compression_level` calibrated by the same binary search as `experiments/compression-quality/run_experiment.py`.
- Request: JSON body with base64 `input_audio` (`format: "ogg"`), `response_format: verbose_json`, `timestamp_granularities: ["word"]`, `provider.options.elevenlabs.diarize: true`.
- Cost: estimated at about $0.11 per audio hour and recorded in the attempt marker; actual cost comes from `usage.cost`. A response without that field has an unknown charge, not a confirmed zero or estimated bill. Earlier Test 2 retains its historical reservation record.
- Classification: HTTP 200 with an `error` key is a failure, even if transcript fields are present. HTTP 200 with invalid JSON or neither nonempty `text` nor `words` is also a failure. Error bodies are recorded up to 2 KiB; raw response bodies are saved in `work/testN_response.json`.
- Completeness: record the last word's `end`, its gap to the audio duration, and `transcript_reaches_end`. The check allows 0–15 s of trailing silence (an explicit `#COMPLETION_DRIVE` assumption in the script). Both new successes end within 0.06 s, so neither depends on that allowance.
- Diarization: count distinct speaker labels in each half-open 30-minute block by word start. Three labels throughout is a count check, not proof that identities or all words are correct.

## Results

| Test | Duration | kbps (actual) | Audio MB | Body MB | HTTP status | Latency s | Outcome | Cost USD |
|---|---|---:|---:|---:|---:|---:|---|---:|
| 1 | 3 h 00 min | 63.54 | 85.78 | 114.38 | 413 | 6.35 | Rejected for size: body of 114,376,467 bytes exceeds the maximum of 52,428,800 bytes | 0 (not billed) |
| 2 | 3 h 00 min | 23.53 | 31.77 | 42.36 | 200 with body `{"error":{"message":"Provider returned 524","code":524}}` | 148.35 | Provider error (524), no transcript | 0.33 reserved, not confirmed |
| 3 | not run | - | - | - | - | - | Not triggered (Test 2 was not a size rejection) | - |
| 4 | 60 min | 63.550 | 28.598 | 38.130 | 200 | 68.009 | Success, transcript reaches end | 0.110 reported |
| 5 | 90 min | 47.310 | 31.934 | 42.579 | 200 | 88.307 | Success, transcript reaches end | 0.165 reported |
| 6 | not run | - | - | - | - | - | Not triggered (Test 4 succeeded) | - |

MB means decimal megabytes; 50 MiB = 52.4288 MB. Test 4's body was 38,130,355 bytes. Test 5's body was verified at **42,579,075 bytes < 52,428,800 bytes** before its single POST; no bitrate reduction was needed (target 48 kbps, actual 47.310 kbps). Both successful responses had no error body.

| Test | `usage.seconds` | `usage.cost` USD | Words | Speakers total | Speakers per 30-min block | Last word end s | Audio duration s | End gap s |
|---|---:|---:|---:|---:|---|---:|---:|---:|
| 4 | 3600 | 0.10999999999998 | 10,843 | 3 | 0–30: 3; 30–60: 3 | 3599.940 | 3600 | 0.060 |
| 5 | 5400 | 0.16499999999997 | 16,183 | 3 | 0–30: 3; 30–60: 3; 60–90: 3 | 5399.946 | 5400 | 0.054 |

Tests 4 and 5 each ran live once, in that order, on 2026-10-08. Their raw JSON and metric records are in git-ignored `work/test4_response.json`, `work/test5_response.json`, `work/test4_result.json`, and `work/test5_result.json`; the run log is `work/tests4-6.log`. No meeting content is included here.

The Test 2 cost is the reservation, not a billed amount. The 524 response has no `usage` field. Check the OpenRouter dashboard for the real charge.

Only `date` came back among the relevant headers in Tests 1, 2, 4 and 5. No rate-limit or timeout headers were present.

## Conclusions

1. **Body size limit: 52,428,800 bytes (50 MiB) for the complete base64 JSON body, as explicitly reported by the server's 413.** It is not a 25 MB raw-audio cap: both new successes contained more than 25 MB of audio. The 114.38 MB body was rejected; bodies of 38.13 and 42.579 MB succeeded, and the earlier 42.36 MB body reached the provider before timing out. We have not probed immediately either side of the exact 50 MiB boundary, so the exact threshold is server-reported rather than boundary-validated.

2. **Observed timeout behaviour: successes at 68.009 s (60 min/~64 kbps) and 88.307 s (90 min/~48 kbps); provider 524 at 148.35 s (180 min/~24 kbps).** Earlier 20-minute Opus/~64 kbps succeeded in about 27 s. These results rule out a universal 60-second end-to-end cut-off for these requests. They do not establish a fixed timeout threshold or identify the component responsible for the 524. An HTTP 200 carrying that error is a failed transcription, not a success.

3. **Recommended product maximum: 60 minutes per single request at Opus/Ogg ~64 kbps, retaining the lossless local archive.** This exact combination succeeded, reaches the end, and keeps the current ~64 kbps upload quality. Its measured 38.13 MB body leaves **27.3% headroom** below the reported 50 MiB limit. Its 68.009 s latency is about **54% below** the observed 148.35 s failure latency; that is an observed comparison, not a guaranteed timeout budget. The recommendation is also 30 minutes shorter than the longest verified success, though that 90-minute test used a lower bitrate. These margins support a conservative operating limit, not a guarantee under different audio or provider load.

**Longest verified success: 90 minutes at ~48 kbps**, with three speaker labels per block and no end truncation. The absolute maximum remains unknown: no duration between 90 and 180 minutes was tested, and the bitrates differ. Do not claim 90 minutes at ~64 kbps is supported. These are single trials on a repeated recording, not a reliability or diarization-accuracy benchmark; longer product recordings need a separate strategy rather than assuming these results scale indefinitely.
