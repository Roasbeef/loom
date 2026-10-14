# Current handoff

Baselined October 14, 2026 against main
`3ee679ca7b7a36bb2e518f4494214de364217e7b`. This edition covers Responses
keepalive compatibility. Main includes #972's register decoding, #979's
diagnostics and deployment CI enforcement, #982's per-strand timing and #976's
capture archive. The prior handoff's pending-cleanup wording is historical;
its archive recovery commands, timing rulings and CI boundary remain in the
[pinned main handoff](https://github.com/Roasbeef/loom/blob/3ee679ca7b7a36bb2e518f4494214de364217e7b/docs/next.md).
The project plan remains `docs/issue-plan.md`.

## Demonstrated failure

A live native Daybreak stream sent `type = "keepalive"` at sequence 343 after
ordinary reasoning and text events. All observed output/content/summary/
annotation positions and content-bearing fields were absent. The production
adapter rejected the frame as `event_unsupported`, returning `MalformedStream`
after 57.46 seconds, before its 60-second deadline. This reproduction used a
known synthetic integer-enumeration prompt and executed no tools or hooks.
It establishes a concrete Loom compatibility defect without relying on private
audit contents.

Earlier audit failures retained only `event=unknown`, sequence 5 and absent
positions. A closer read-only replay reproduced the same refusal class, but
its raw unknown event name was not retained. The structural match supports the
keepalive diagnosis; it does not prove every historical failure had that type.
The owner later saw the real session respond without a provider patch, so
observed recovery alone was not treated as a fix.

## Acceptance boundary

The adapter admits only the fixed `keepalive` control as a semantic no-op after
existing JSON, event-name and monotonic-sequence validation. No text, tool call,
item, usage or terminal witness is created or cleared. Unknown semantic events
remain refusals. The outer cumulative-byte and absolute-attempt bounds continue
to apply. A keepalive cannot make an unfinished stream settle.

## Verification boundary

All 309 provider tests passed. Removing only the keepalive no-op made the new
regression fail with `event_unsupported`; restoring it passed. Provider lint,
formatting, diff and documentation checks passed. One independent adversarial
review found no actionable findings. A live native response using the committed
adapter crossed `keepalive` at sequence 333 and reached canonical completion at
338, settling successfully in 54.73 seconds. The probe verified the loaded BEAM
and source against implementation commit `489fd0703`. It used a known synthetic
prompt, no tools and no private context.
Broader affected checks, hosted CI and exact-head Linux signoff are separate
requirements. No installed daemon, operator configuration or audit session has
been changed by this work.

## Separate work

Login PR #985 is independently reviewed and rebased onto this main revision;
its current-head checks must pass before the explicitly authorized merge.
Fast-mode PR #987 remains separate. Its local affected gate passed, but a full
Linux signoff hit an unchanged remote-daemon options-file refusal; a fresh
focused Linux reproduction passed all four variants. Those results do not
validate this provider change.

## Next steps

1. Finish the running affected-package gate and publish the reviewed provider
   PR with its baseline-failing regression and successful live settlement.
2. Publish the scoped provider PR and obtain its current-head affected checks,
   hosted CI and Linux signoff. Do not carry forward other branches' results.
3. Merge #985 only under its own authorization and gates. Installation and
   restarting the owner daemon remain separate operator actions.
