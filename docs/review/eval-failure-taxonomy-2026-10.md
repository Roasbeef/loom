# Eval failure taxonomy, 2026-10

Status: protocol only. No sessions have been exported or labelled. The
authoring environment held no production sessions and no model keys, so the
results table below is empty on purpose; every count, share and exemplar in it
is the owner's to fill from real data, and none is estimated here.

## Purpose

Hand-written eval tasks should follow from how agents actually fail, not from
what is easy to think of (design note `docs/design-notes/eval-instrument.md`,
section 9). This document is the protocol that produces that evidence: export
the daemon's recorded sessions, label a stratified sample by hand, and let the
counts decide which failure kinds the tune split must cover before any task
is written. The vocabulary below is a starting point. Replace it with whatever
the data says; do not force sessions into it.

## Export

The exporter copies each session database, never opening an original, and
writes one scrubbed JSONL file per session. The scrubber is a heuristic and
the header of every file says so: short unlabelled secrets and private prose
survive it. The output is for the owner's eyes and is not committed.

```sh
cd packages/eval
gleam run -m eval/transcripts_cli -- export \
  --state "$LOOM_STATE" --since 2026-09-01 --out "$HOME/transcripts-2026-10"
```

`--db PATH` (repeatable) names databases directly instead of searching
`$LOOM_STATE/sessions`. A session whose daemon still holds its writer lease is
reported as FAILED in the census rather than read around the lease: stop the
daemon or wait out the lease and export again.

## Sample

```sh
gleam run -m eval/transcripts_cli -- sample \
  --dir "$HOME/transcripts-2026-10" --n 40 --seed taxonomy-2026-10 > batch.txt
```

The sample is stratified by primary model id and by operator outcome
(`succeeded`, `failed`, `unmarked`), dealt round-robin across strata so a rare
stratum appears before a common one repeats. The same directory, `--n` and
seed reproduce the same batch. Record the seed in the results below.

## Labelling

- The owner and one independent reviewer each label every sampled session
  alone, before comparing.
- One primary category per session: the failure that, had it not happened,
  would most likely have changed the outcome. A session that succeeded is
  labelled `none`; one that failed for a reason outside the vocabulary gets a
  new category with a one-line definition and an observable signal.
- Disagreements are discussed once. If they do not converge, the owner's label
  stands and the session is listed as contested, so the number is visible.
- A category holding at least 5 percent of labelled failures needs at least 3
  tune-split tasks tagged with it (`Task.tags`) before any hand-written task is
  authored. `eval report` prints the pass rate per tag.

## Starting vocabulary

| Category | Definition | Signal in the transcript |
| --- | --- | --- |
| wrong-tool-shape | The tool was right but called with arguments of the wrong shape. | A `tool_call` whose `arg_keys` differ from the tool's schema, followed by an `is_error` result. |
| refusal-loop | The model keeps being refused and repeats the same call. | Several consecutive `tool_call`s with equal name and `arg_keys`, each result `is_error`. |
| context-overflow | The window filled and work was lost or abandoned. | A `compaction` record with large `tokens_before` shortly before the session ends. |
| gave-up-early | The model stopped with the task unfinished and no blocking error. | Final `assistant` text claims completion or asks to stop; no test run follows the last edit. |
| wrong-test-run | Verification ran the wrong tests or the wrong package. | A test-running `tool_call` whose preview names a different module than the one edited. |
| edited-without-reading | A file was changed without being read first. | An edit `tool_call` on a path with no earlier read of it. |
| hallucinated-api | The model used a function, flag or module that does not exist. | A compile or lookup error `tail` naming a symbol the model introduced. |
| jail-misread | The model misread a sandbox limit as a bug in its own work. | An `is_error` `tail` showing a permission or network denial, then attempts to work around it. |
| verifier-irrelevant | The model solved a task the hidden verifier does not measure. | `outcome` is `failed` yet the transcript ends in a green run of the model's own tests. |

## Results

Seed: not yet chosen. Sampled: 0 of 0 sessions. Contested: 0.

| Category | Count | Share of failures | Exemplar session ids |
| --- | --- | --- | --- |
| wrong-tool-shape | | | |
| refusal-loop | | | |
| context-overflow | | | |
| gave-up-early | | | |
| wrong-test-run | | | |
| edited-without-reading | | | |
| hallucinated-api | | | |
| jail-misread | | | |
| verifier-irrelevant | | | |
