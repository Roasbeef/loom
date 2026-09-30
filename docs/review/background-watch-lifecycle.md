# Background watcher lifecycle review

Base: `01f14ef8f`, after #667. The implementation is split into cancellation
grace, explicit lifetime authority, generated capability signatures and docs.

## Verified invariants

A quiet finite deadline starts cancellation grace after its selective receive
ends. Caller death follows the same rule. Delayed exit reports settle before
a helper returns to checkout; a premature check-in cannot admit another call.

Session lifetime requires an explicit Bash lifetime or named code-mode API.
Zero finite timeouts remain invalid. The launching action receives wall
authority before execution, and the job captures that authority. Broker refusal
under a finite base occurs before dispatch. The satellite remains finite.

A session job retains outstanding limits, sandbox authority and cancellation.
Its quiet receive has no deadline wake. Owner kill, originating-operation abort
and session shutdown retain their existing custody and notification rules.
Settled session tokens are revoked and reclaimed.

## Review disposition

One independent adversarial source review checked authorization, deadlines,
clearance, drain, token reclamation and nearby stale-clock variants. It found
no confirmed defects. A focused follow-up reviewed the real-helper and
shipped-daemon acceptance tests and protocol-change/057, with no findings.
Source review and executed validation remain separate evidence.

## Executed acceptance

The real broker/helper test refuses session lifetime without a wall grant,
then remains running past a one-second control wall and acknowledges explicit
cancellation with an enforcement report. The jobs actor tests cover quiet
finite settlement, deadline guidance, session lifetime and silent shutdown.

The shipped-daemon fixture starts from a finite policy, receives approval
through the real TUI, and builds and executes `job.start_for_session` in a
jailed satellite. The program checks the zero lifetime receipt and returns.
A second program finds the same job running and kills it; its birth-qualified
payload departs. The provider fixture observes exactly four requests. The
original finite-lifetime fixture remains present.

Full repository checks, mutation results and hosted CI/signoff are reported
on the pull request rather than inferred from these focused cases.
