# Speaker continuity experiment

Can independently transcribed lossless audio pieces retain consistent speaker identities using OpenRouter only, without local ML? This experiment compares raw labels, audio anchors, and text-based identity matching against a previously transcribed three-speaker recording.

## Run

From the repository root, using the existing PoC environment (no new dependencies):

```bash
# Synthetic checks: no key, private recording, or network access needed.
experiments/poc/.venv/bin/python experiments/speaker-continuity/run_experiment.py --self-test

# Live experiment, or a cached rerun.
experiments/poc/.venv/bin/python experiments/speaker-continuity/run_experiment.py
```

Prerequisites:

- macOS with `afconvert` available.
- Source: `~/Downloads/New Recording.m4a`.
- Reference: `experiments/poc/transcripts/2026-10-08_10-37-15.json`.
- `OPENROUTER_API_KEY` in `experiments/poc/.env` or the environment, loaded with python-dotenv. The script never prints or copies the key.
- The existing `experiments/poc/.venv` with numpy, soundfile, requests, and python-dotenv.

All audio, model metadata, raw API responses, the spending ledger, anchor diagnostics, and results stay in the root-gitignored `work/` directory. Do not publish that directory: it contains private meeting material. The full source is **not** retranscribed for ground truth.

### Audio and splits

`afconvert` decodes/resamples the source once to 16 kHz mono FLAC (`work/original.flac`). Its output on this machine was 24-bit, 37.16 MB. The script normalizes decoded samples to **16-bit PCM** (`normalized.flac`, 20.82 MB) and preserves those samples in all derived FLAC files. This reduces sample precision, but introduces **no lossy codec**; no AAC, MP3, or Opus is sent. The source itself is already AAC, so conversion cannot restore its discarded information.

Cuts are the midpoints of the longest positive gaps between reference words within ±30 seconds of each target. Overlapping word ends are tracked so a gap cannot cut another overlapping word. Cuts are rounded to sample boundaries. Piece audio is limited to 20 minutes, excluding the anchor prefix; requests must also fit the 25,000,000-byte audio-file cap.

| Recording | Duration | Cuts from recording start | Piece durations |
|---|---:|---|---|
| Original, two pieces | 16:56.916 | 8:18.060 | 8:18.060 / 8:38.856 |
| Original, three pieces | 16:56.916 | 5:36.960, 11:14.180 | 5:36.960 / 5:37.220 / 5:42.736 |
| Doubled, two pieces | 33:54.832 | 16:58.612 | 16:58.612 / 16:56.220 |

The doubled recording concatenates the normalized original, one second of silence, and the original again. Its reference is the original word list plus a copy shifted by 1,017.916 seconds, retaining the same speaker identities. **This is easier than a real long meeting: anchor clips are identical to audio that repeats later.** Its split is near the repetition seam, not a new conversational context.

## Methods

All speech requests use OpenRouter `/api/v1/audio/transcriptions`, `elevenlabs/scribe-v2`, base64 FLAC, `verbose_json`, word timestamps, and `provider.options.elevenlabs.diarize: true`.

- **E1 — no matching:** transcribe pieces independently and retain raw labels. Fit one global one-to-one reference mapping using only piece 1; later label permutations remain errors.
- **E2 — speaker anchors:** reuse the plain first piece. For each global speaker seen so far, select the longest consecutive same-speaker word run in any earlier piece, at least four seconds long. Trim to at most ten seconds, ending at a word boundary. Append each anchor followed by one second of silence, then two additional seconds of silence and the next piece. Identify each anchor by its majority word speaker label, remove prefix words, and shift piece timestamps back to recording time. An unmatched piece label gets a new global identity. Missing anchors and anchors without words are logged. If multiple anchors receive the same label, log the merge and leave that label unresolved/new rather than arbitrarily assigning it to one person. Future requests include anchors for these newly allocated identities too.
- **E3 — LLM text matching:** reuse E1's transcriptions. Send the last approximately three minutes of the immediately previous piece (with global labels) and the first approximately three minutes of the next piece (with local labels) to OpenRouter chat completions. Require a JSON mapping to previous labels or `new`, covering every next-piece label with no duplicate existing target. Apply mappings sequentially. The parser accepts both the requested `mapping` envelope and the direct mapping actually returned by the model.

**Chat model:** `google/gemini-2.5-flash-lite`, selected from the live `/api/v1/models` catalogue as an inexpensive general-purpose model with JSON support: $0.10/million input tokens and $0.40/million output tokens. These matched GPT-4.1 Nano's listed prices when checked; Gemini was chosen for this experiment, not claimed to be the cheapest model available. Temperature is zero and output is capped at 1,000 tokens. E3 ran for both original-file splits; it was not run on the doubled file (optional in the brief).

### Scoring

For each predicted word, find the closest reference-word midpoint within 0.3 seconds, otherwise skip it. This is time-only matching, not a lexical alignment; multiple predictions may match one reference word. Non-speaker events are excluded. Fit the single best one-to-one speaker mapping using **only aligned piece-1 words**, then freeze it for the entire recording. Later newly allocated labels with no piece-1 mapping are incorrect, not retrospectively matched to the reference.

Accuracies below use matched predicted words as denominators, not all reference words. “Pieces 2+” excludes the calibration piece. The supplied three-speaker full-file transcription is treated as correct; this measures continuity against it, not independently human-verified diarization quality.

## Results

Measured live through OpenRouter; costs are USD from `usage.cost`.

| Recording / split | Method | Overall correct | Pieces 2+ correct | Predicted / reference speakers | Method cost |
|---|---|---:|---:|---:|---:|
| Original / 2 | E1 raw labels | **62.80%** | **23.53%** | 3 / 3 | **$0.031072** |
| Original / 2 | E2 anchors | 54.64% | 5.89% | 5 / 3 | $0.032126 |
| Original / 2 | E3 text matching | **62.80%** | **23.53%** | 3 / 3 | $0.031261 |
| Original / 3 | E1 raw labels | **44.66%** | **14.69%** | 3 / 3 | **$0.031072** |
| Original / 3 | E2 anchors | 39.62% | 7.30% | 7 / 3 | $0.033693 |
| Original / 3 | E3 text matching | **44.66%** | **14.69%** | 3 / 3 | $0.031449 |
| Doubled / 2 | E1 raw labels | **93.84%** | **95.12%** | 3 / 3 | **$0.062175** |
| Doubled / 2 | E2 anchors | 58.19% | 23.85% | 5 / 3 | $0.063220 |

| Recording / split | E1/E3 matched / skipped words | E2 matched / skipped words |
|---|---:|---:|
| Original / 2 | 3,016 / 8 | 3,018 / 10 |
| Original / 3 | 3,005 / 9 | 3,031 / 8 |
| Doubled / 2 | 6,026 / 16 | 6,034 / 10 |

Each method's cost represents its standalone request set: E2 includes the shared plain first piece; E3 includes all plain speech requests plus chat. **Do not sum table costs to calculate experiment spend**, because several requests are shared.

**Actual unique API spend: $0.212504**, below the $0.50 cap. This includes a $0.015218 initial 24-bit first-piece request, excluded from the comparison rows. The initial size check counted base64 expansion and stopped locally; the final guard follows the PoC's experimentally validated audio-file-byte interpretation of the cap. Normalized pieces were then used consistently for all comparison rows. The actual chat costs were $0.000188 for the two-piece split and $0.000377 total for the three-piece split.

## Observations and failures

- **Anchors merged different people.** On the two-piece original, global speakers 0 and 1 both received local anchor label 0. The doubled test had the same merge. Both runs consequently predicted five global identities rather than three.
- On the three-piece original, the second request merged globals 0/1 into local 0. The third request merged globals 0/1/3 into local 0 and globals 2/4 into local 1. This propagated identity fragmentation to seven predicted speakers. No missing-word anchors or missing four-second anchor candidates were logged in these runs.
- Consecutive diarized words are only a proxy for clean solo speech: no acoustic overlap detector or local model was used. Long pauses inside such runs are not filtered out. Bad initial labels, overlap, or silence-heavy clips can undermine anchors. Majority labels also hide mixed-label anchors; inspect private `*_anchors.json` and cached response words when investigating.
- **Text matching did not correct the permutations.** All three chat requests returned identity mappings (0→0, 1→1, 2→2), so E3 exactly reproduced E1's scores. This model/prompt/context combination failed to infer identities from the text, despite instructions not to assume equal labels identify the same person. It cannot use voice similarity and can miss a person absent from the boundary context.
- Raw-label performance deteriorated with three pieces. High overall scores would hide the problem: later-piece accuracy was only 23.53% for two pieces and 14.69% for three.
- The doubled baseline's 95.12% later-piece accuracy is **not** evidence that real long meetings retain stable labels. Repeated audio and similar ordering make stable raw label permutations much easier. Anchors still failed even in that favorable case.
- These are single API outcomes from one meeting, not repeated trials or a population-level evaluation. Resampling/AAC decoding and small timing changes affect time-only alignment; the reference transcription itself may contain errors.

## Conclusion

**E1 wins on cost and ties E3 on accuracy; E2 loses on every tested split. None of the methods solves reliable continuity for a real split meeting.** Use E1 as the inexpensive baseline for further experiments, not as a production identity matcher. Do not adopt this anchor scheme unchanged: merges and accumulating false identities are its decisive failure cases. This inexpensive text matcher provided no benefit either. For now, prefer a single request when the recording fits; otherwise present labels as piece-local rather than promising consistent identities.

## Cache, budget, and checks

Responses are cached by SHA-256 of the endpoint and exact request payload, including audio or chat context. A successful rerun reuses all paid responses. Changed audio, prompts, or models yield new requests, still counted by the persistent ledger. Do not delete `work/` to retry: that deletes both caches and budget history.

Before each paid request, the ledger reserves twice the observed Scribe rate ($0.22/audio-hour), or chat input UTF-8 byte count plus overhead at the catalogue input price and the full output token allowance. Confirmed `usage.cost` replaces that reservation. These are conservative estimates, **not a provider-enforced billing cap**; the script stops on a reservation overrun or when the next reservation would exceed $0.50. Unknown costs and failed/time-out requests retain their reservations. POST retries are deliberately disabled to avoid double billing after uncertain completion; reconcile pending fingerprints with OpenRouter activity before attempting recovery. Free catalogue GETs have timeouts and retries. Run only one experiment process at a time; the ledger is not a concurrent-process lock.

Verification passed: eight synthetic tests, Python compilation, and `git diff --check`. A complete rerun with network calls mocked to fail reused every cached response, made zero network calls, and left the spend ledger unchanged. Decoding the doubled FLAC confirmed two exact normalized PCM copies separated by exactly 16,000 zero samples.

`--self-test` checks first-piece-only mapping, honest later-piece scoring, skipped-word timing, longest-gap selection, anchor collisions/selection, actual chat response shapes, response reuse, and budget rejection before any network call. No existing project lint/test configuration was detected; the script's synthetic tests and Python compilation are the local verification commands. Assumptions and verification suggestions about pricing, sample precision, audio limits, anchor cleanliness, merge handling, and POST retry safety are tagged in the script.
