# Per-package CLAUDE.md template

Use this when generating or updating a package's documentation file.

```markdown
# {package}

## Purpose

{1-2 sentences: what this package is, specifically enough that someone who
has never opened it knows what belongs in it and what does not.}

## Key Types

- `module.TypeName` — {one line: what it is, plus any non-obvious wiring}
- `module.fn_name` — {only when a function is the package's real entry point}

## Relationships

- **Depends on**: pkg (reason), pkg (reason)
- **Depended on by**: pkg (reason), pkg (reason)
- **FFI**: `pkg/internal/ffi_x` — {which OTP/Erlang capability, why}

## Traffic

- **Actor messages**: `module.Variant(fields)` — {sender → receiver, call
  or cast}
- **Commits**: {which `core/tx.Write`s, through which path, under which
  expectations}
- **Registers**: reads `ns.key-shape`, writes `ns.key-shape`
- **Wire**: {frame kinds / stream events crossing a process or OS boundary}

## Invariants

- {A rule that causes a bug when violated, in this package's own vocabulary}

## Deep Docs

- [docs/architecture/x.md](../../docs/architecture/x.md) — {which plane}
- [README.md](README.md) — {only if the package has one}
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph
```

## Guidelines

- **Purpose** — be specific. "The SQLite backend: one database file per
  session" beats "Provides storage functionality." Where a module doc
  already says it well, borrow its words.

- **Key Types** — top 3-5. Qualify with the module (`machine/planner.Action`,
  not `Action`) because Loom packages hold many modules and the same short
  name recurs. Prefer the types an agent must understand to change the
  package: opaque handles, the ADT the package exists to model, the record
  of injected effects. Skip helpers.

- **Relationships** — real package names, with the reason. Derive them from
  `import` statements, cross-check against `gleam.toml` and the spec DAG
  (`docs/loom-implementation-spec.md` §0.1), and note a divergence rather
  than papering over it. Always name the `internal/ffi_*` modules: they are
  the package's complete inventory of impurity, and a pure package having
  none is itself worth stating.

- **Traffic** — this section is the reason the file exists. Concrete type
  names only.
  - *Actor messages*: one line per variant family, with direction and
    whether it is a call (`reply: Subject(...)`) or a cast.
  - *Commits*: which `Write` variants, through which path, guarded by which
    `SeqExpectation`s. "Commits `SetRegister(OpState, ...)` guarded by the
    op-state seq" is useful; "writes to storage" is not.
  - *Registers*: use the wire namespace names — `strand.*`, `op.*`,
    `pending.entry`, `fact.*` — and the key shape (`{op}:{step}:{index}`).
  - *Wire*: framing kinds, SSE event names, `StreamEvent` variants.
  - A pure package with no traffic says so in one line, and that is a real
    fact about it — do not pad.

- **Invariants** — the load-bearing ones. Mine the module docs (they were
  written to state invariants) and `docs/spec-gaps.md` (which records where
  implementation had to interpret the spec). The register here is:
  - total-decoder boundaries — what is rejected rather than guessed;
  - replay and idempotency policy — what a crash may repeat;
  - CAS and ordering expectations — what a concurrent writer sees;
  - purity layering — `core` and `machine` import nothing effectful;
  - fail-closed behavior — where a capability narrows rather than widens.

  "Every transaction opens with `BEGIN IMMEDIATE`" is an invariant.
  "Hashline plans are digest-bound; re-apply always rejects" is an
  invariant. "Uses `Result` for errors" is not.

- **Deep Docs** — link the architecture doc for the plane the package sits
  in (`durability`, `orchestration`, `effects`, `simulation`), the package
  README when one exists, and always the root `CLAUDE.md`. Link
  `docs/spec-gaps.md` when the package has entries there.

- Never name an assistant, an AI, or an authoring tool in the content.
