# protocol-change/009 — `RequestTarget.ForRole` carries a thinking level

**Status**: ACCEPTED 2026-08-28 · **Affects**: Part 1.5 `RequestTarget` ·
**Raised by**: issue #14 (the wiring seam's model-routing questions) ·
**Implemented**: provider + client

## Problem

Spec §1.5 closes the dispatch vocabulary at two shapes:

```gleam
RequestTarget = ForRole(role)            # resolve the chain, walk it
              | ForResolved(resolved)    # exactly this identity, no walk
```

`ForResolved` carries a whole `ResolvedModel`, and a `ResolvedModel`
carries a `thinking` level. `ForRole` carries a role and nothing else, so
the level every attempt of a walk is made at is whatever each route entry
declares — a static figure the operator wrote into `loom.toml` when the
session did not exist.

Until now that cost nothing, because no production path built a `ForRole`
target: `client/wiring` dispatched `ForResolved` on every request, and the
one place a level could disagree with the route's was overwritten there
(`ResolvedModel(..resolved, thinking:)`). Issue #14 moves on-route
generations to `ForRole` so a rate-limited chain head falls to its own
tail instead of burning the machine's retry ladder. With that move the gap
becomes reachable and wrong in both directions:

- A turn that raised its reasoning budget through `set_config
  thinking_level` reaches the *head* at that budget and the *fallback* at
  whatever the fallback's row says — very often `off`. The fallback answers
  a question the model was told to think hard about, without thinking.
- A structural summary has no per-turn level at all. It is a one-shot
  prompt with no conversation behind it, and the operator's `thinking` on
  the summarization entry is exactly the right answer for it — but a
  target that always carried a level would have nowhere to say "leave the
  entry's own alone", and the caller would have to invent one.

The two needs are opposite, which is why the field is optional rather than
required.

## Proposal

One optional field on the variant:

```gleam
pub type RequestTarget {
  ForRole(role: Role, thinking: Option(ThinkingLevel))   # was ForRole(role)
  ForResolved(resolved: ResolvedModel)
}
```

Semantics, and they are the whole of the change:

- **`None`** — each target the walk attempts keeps its own static level,
  the one its route entry declares. This is what a structural summary
  sends.
- **`Some(level)`** — that level is overlaid onto **every** target the
  walk attempts, before the walk starts. The head and the third fallback
  are asked for the same budget. This is what a generation sends, carrying
  the strand's per-turn level.

`ForResolved` is untouched: it carries a `ResolvedModel` and always did
carry the level with it.

## Impact

- `provider/model.RequestTarget` gains the field; the compiler finds
  every construction site (two in `client/wiring`, two in the gateway's
  own tests).
- `provider/gateway` applies the overlay in `dispatch_role`, over the
  usable chain, before `attempt` walks it — one `list.map`, and the point
  of doing it there rather than per attempt is that a fallback cannot
  quietly differ from the head.
- `client/wiring.request_target` returns `ForRole(role, Some(level))` on
  route and `summary_target` returns `ForRole(Summarize, None)`.
- No durable format changes and no wire changes. `RequestTarget` is an
  in-VM dispatch instruction; what durable state stores is the
  `ModelIdentity`, and that is unchanged.

**One accepted cost, stated so nobody rediscovers it as a bug.** A
generation dispatched `ForRole` may settle on a *fallback* target, and a
settlement carries the answering identity. If such a settlement were
`Deferred`, the handle would name the fallback while the committed intent
names the head — and `machine/classification` validates a deferred handle
against the captured `{provider, model_id, api}` (ORCH-L4). The handle
therefore fails its check and the operation drains as a failure rather
than suspending. That is the honest outcome: nothing in the harness could
poll such a handle correctly, because the poll is `ForResolved` on the
captured identity and the continuation lives at the fallback. It is also
unreachable today — no adapter settles `Deferred`, which is itself
recorded as a spec gap. Deferred polls are dispatched `ForResolved`
precisely so this stays confined to the settlement that created it.

## Decision

**Accepted.** Two alternatives were considered and dismissed.

*Leave `ForRole` as it is and let each entry's declared level stand.* This
is the cheaper diff and it is wrong about what a thinking level is. The
per-turn level is a property of the turn — a human or a model asked for a
deeper answer to this question — and a fallback that silently downgrades
it produces a worse answer with no signal anywhere that it did. The
operator's row is a *default*, and defaults belong at strand creation,
which is where the catalogue's `thinking` now actually takes effect.

*Make the field required, `thinking: ThinkingLevel`.* Every caller would
then have to name a level, including the summary path, which has none to
name and would have to fabricate one — reproducing exactly the override
this change exists to remove, one layer up. `Option` is the type of the
question being asked ("does the caller have an opinion?"), and answering
"no" is a real answer here rather than a missing value.
