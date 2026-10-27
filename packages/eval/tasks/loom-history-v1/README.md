# loom-history-v1

A portable set of 21 regression tasks mined from Loom's own fix commits and
proved admissible. Each task starts from the parent of a fix commit and is
graded by that commit's own tests, hidden from the agent.

- Packages: provider 13, lint 4, prompt 2, machine 2 (the miner was pointed at
  `machine,core,prompt,provider,lint`; no `core` candidate was admitted).
- Fix commits span 2026-08-24 (`fd6f9ad9f`) to 2026-10-18 (`2a99a8b44`), mined
  from the history ending at `756097db4` (2026-10-25).
- Mining: 49 candidates, 21 admitted. A candidate whose tests need the network
  is culled (the verifier jail has it off), which removed the socket tasks the
  earlier set carried.
- Proving: 21 tasks, 21 admitted, 0 could not be proved. Gold scores 1, null
  scores 0, and the sabotage census is recorded per task (17 caught, 4
  survived; census only, it never gates).
- Identity: a task records its repository as the logical name `loom`, never a
  path, so a task id is the same on every machine. The operator supplies the
  clone at run time and the clone must hold each task's commit with the
  recorded tree.

## Enforcement posture

The proofs in `prove.jsonl` ran with the best-effort demand. The kernel
enforced every layer except the cgroup pids and memory ceilings, because the
host has no delegated cgroup v2 (`skip:cgroup-v2` in each line's
`enforcement`). A host with cgroup v2 can re-prove under the production
demand by dropping `--best-effort`.

## Reproducing

From `packages/eval`, with a Loom checkout at `$LOOM` whose history contains
the commits above:

```
gleam run -m eval/mine_cli -- --repo loom=$LOOM --name loom \
  --package machine,core,prompt,provider,lint --out ~/evalwt/mined
gleam run -m eval/prove_cli -- --tasks tasks/loom-history-v1 \
  --repo loom=$LOOM --out ~/evalwt/prove --best-effort
```

Without `--repo`, `loom` is the checkout of the current directory. Run a plan
over the set with `eval/run_cli run <plan.json> --tasks tasks/loom-history-v1`.
Re-mining may admit a different set as the history grows; the files here are
the record.
