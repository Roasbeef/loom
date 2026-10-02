# Directory callback retention

Status: local package gates, independent review, and the full macOS signoff
passed. Hosted CI remains outstanding. These measurements do not establish a
reduction in the installed daemon's RSS.

The gateway needs its execution runtime, but directory administration needs
less state. Its add callback reads and conditionally commits one reserved fact.
Its read callback reads the durable store. Retaining the full runtime or session
inside those callbacks creates additional paths to unrelated executable state.

## Baseline measurement

The fixture constructs a real runtime, supplies the real directory callbacks to
a standalone gateway, and measures the initialized gateway state with
`erts_debug:flat_size/1`. It varies only a dynamically allocated payload held by
the tool executor. Each standalone gateway is shut down and its monitored exit
is observed before the runtime is closed.

| Object | Small executor payload, words | Large executor payload, words |
|---|---:|---:|
| Runtime | 1,588 | 26,158 |
| Directory add callback | 1,647 | 26,217 |
| Gateway without directory administration | 1,689 | 26,259 |
| Gateway with directory administration | 4,731 | 53,871 |

The payload increases the runtime by 24,570 flat words. The gateway without
directory administration grows by that amount; with administration it grows by
49,140 words. The difference identifies one additional payload-dependent path
through the retained callback. Whole gateway state should continue to grow with
the execution runtime after this fix.

Two separate perturbations identify smaller projections inside administration:
unused policy environment and root fields enlarge the add callback from 58 to
61,468 flat words, and an unrelated lease-renewal payload enlarges the read
callback from 428 to 24,998 words. Directory mutation needs the protected-path
list; readback needs the store. Neither needs those perturbed fields.

Flat size measures the cost of an unshared term representation. It does not
measure currently shared objects, allocator capacity, garbage, or resident
memory. The experiment supports narrowing callback ownership; it does not
justify multiplying these word counts by the number of sessions to predict RSS.

## Ownership and failure behavior

An opaque internal fact handle projects the runtime's restartable writer
address. Each operation resolves that address through the existing writer API;
the handle caches no PID and adds no process, timeout, retry, or liveness check.
Fact reads and reserved conditional writes share the existing transaction and
error mapping. In particular, an uncertain commit remains uncertain.

The production directory constructor receives a supplier retaining this narrow
handle. The existing constructor remains a compatibility adapter: it obtains
the runtime only after validating the requested directory, at the same point as
before. Filesystem checks, authenticated origin, reserved-key restrictions,
lease fencing, and stale-sequence rejection retain their existing owners.

The handle and its operations are additive internal exported Gleam interfaces.
They do not change existing public signatures or wire contracts. The repository
owner approved these additions before implementation.

## Verification required

The initialized-state regression must show constant incremental administration
cost as unrelated executor payload grows. Restoring the broad runtime supplier
must restore the additional growth. Policy and session perturbations must stop
changing their respective callbacks.

Behavioral tests must retain a handle across writer replacement, cover absent
and stale conditional writes, preserve unavailable and lease-loss errors, and
show that namespace retirement prevents an old handle from reaching a reopened
session. Existing directory authorization and filesystem tests remain part of
the affected gate.

## Candidate measurements and local checks

With the projected production constructor, the gateway without administration
still grows from 1,689 to 26,259 words. The directory-enabled gateway grows from
3,074 to 27,644 words: administration adds 1,385 words at both payload sizes.
The add callback stays at 36 words; the read callback stays at 1,342 words.
The policy-only perturbation leaves its add callback at 13 words, and the
session-only perturbation leaves its read callback at 375 words.

Three negative controls restore the old runtime, policy, and session captures
one at a time. Each fails its intended growth assertion with exit status 1.
Each source mutation was restored before the package gates ran. Numerical
printing remains in the ignored evidence logs, not in the regression source.

The runtime gate passed 179 tests and the client gate passed 2,640 tests,
both with their own exit status 0. The first focused client run lacked the
sandbox helper and failed a Git-identity boot fixture; building the existing
helper made that exact case pass without modifying its test or production
behavior. The complete client gate then passed.

The handle tests cover writer replacement, an unbound interval, namespace
retirement, absent/stale conditional writes, reserved-key rejection, and actual
SQLite lease theft. A deterministic lost-reply fixture kills the writer after
storage commits: the caller crashes, the replacement reads the durable value,
and the API performs no retry. Compatibility administration tests preserve
lazy runtime acquisition and durable directory upgrades.

The complete local signoff passed at `ed574473` with its own exit status 0
in 831 seconds, including all six lanes, enforcement, and release/update
verification. Its two declared macOS prerequisites were the existing `/proc`
and rust-analyzer exclusions; the skip census reported no undeclared skip.

A fresh independent review found no blocking correctness or simplification
findings. Its coverage qualification prompted a fresh-runtime witness: after
retiring the original namespace, a new handle commits successfully, while the
old handle cannot read or write even when supplied the fresh cell's current
sequence. The fresh value and sequence remain unchanged. That additional
focused test passed with its own exit status 0.
