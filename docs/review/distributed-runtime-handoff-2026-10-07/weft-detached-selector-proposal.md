> Archived at the October 7 pause. This records its original component or
> proposal state. The current handoff governs publication status and next steps.

# Deliver original Detached outcomes into actors

The Compile physical-close controls exposed two concrete problems with the
planned direct-holder adapter. `weft.pull(detached, within:0)` leaves outcome
demand outstanding. The later private reply reaches the actor between ticks,
where `weft/actor` discards it as an unexpected message. Increasing the wait
cannot eliminate that race. Separately, unlinking the original scope prevents
its existing caller-exit path from switching to discarded delivery after the
holder dies, so a cancelled scope may wait forever for a dead holder's demand.

The second problem needs no weft engine change. Its actor explicitly supports
overriding trapped exits through the typed selector. Loom can retain the original
link and classify exact retained scope exits without killing its whole service;
actual parent exits and unrelated link failures retain their existing behavior.
The independent original scope monitor remains mandatory for successful closure.

The first problem needs three small public functions in the existing weft module:

```gleam
pub fn select_detached(
  selector: process.Selector(message),
  detached: Detached(a, e),
  map: fn(Pulled(a, e)) -> message,
) -> process.Selector(message) {
  process.select_map(selector, detached.outbox, fn(reply) {
    map(case reply {
      Delivered(outcome:, ..) -> PulledOutcome(outcome)
      Done -> AllDelivered
      Ready(_) -> NotYet
    })
  })

pub fn request_next(detached: Detached(a, e)) -> Nil {
  process.send(detached.inbox, Next)
}

pub fn deselect_detached(
  selector: process.Selector(message),
  detached: Detached(a, e),
) -> process.Selector(message) {
  process.deselect(selector, detached.outbox)
}
```

These expose existing typed delivery and unary demand without exporting private
Subjects or adding a relay, timer, Dynamic router, FFI, process, or scope-side
state. The constructor handshake already consumes Ready; the explicit NotYet
mapping keeps the projection total. The original start_detached caller owns the
selector. It installs the outbox selector and original scope monitor in its state
before granting work and initial demand, processes each result before requesting
the next, and removes the selector when original custody is discharged. It must
not concurrently use synchronous pull on the same handle. Repeated demand has
the existing protocol semantics; callers do not request another result before
processing the preceding one.

AllDelivered means the existing Done message, and does not replace a separate
original Normal DOWN. RunLost comes from that retained original monitor. A work
permit Subject is created by the managed worker that receives it, offered back
in a typed readiness message, and granted only after the actor retained its
scope/monitor/account. The actor's periodic polling becomes unnecessary.

Implementation scope is src/weft.gleam, dedicated actor/Detached integration
tests, and weft documentation. Tests will use actual actors and scopes to prove
asynchronous outcome delivery, one-at-a-time backpressure, multiple tasks,
cancellation, holder death before work and with an undelivered result, original
scope Normal versus missing/abnormal evidence, and removal of a finished selector.
The existing full weft gate and one independent review remain required.

Loom currently pins weft at 368d01abcaaff3ef986317a89fe8b98e1e4a2ad6.
After approval, the implementation would use an isolated weft worktree based on
that exact commit, commit the reviewed change as the repository owner, and update
Loom's existing weft dependency references/generated manifests to the resulting
exact revision. Local integration can use an explicitly documented temporary
dependency override in isolated verification checkouts until the revision is
available from its configured remote. No override is a shipping dependency.
Publishing/pushing remains a separate ungranted action and is required before
remote exact-candidate CI can resolve a newly pinned revision.

No source or dependency manifest has been changed for this proposal. AGENTS.md
requires a user decision for public interface changes and for a workaround after
the intended approach fails; this proposal makes that decision concrete. It
leaves the separate existing-host metadata-reader dependency question unchanged.
