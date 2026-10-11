# protocol-change/081: retain request usage across attempts

Status: accepted on 2026-10-04 under the protocol delegation in
`docs/execution.md` section 7, within the owner's Sign in with ChatGPT
migration in PR #496. Affects the provider terminal contract in spec
Part 1.5 and the shared usage encoding. The proposal was originally numbered
067 and was renumbered to 081 after main used 067 through 080 for other
contracts. Its accepted contract is unchanged.
Implementation follows acceptance.

## Problem

The gateway can make several provider attempts for one request. Its fallback
walk discards a retryable failure, and `response.failed` currently discards
any usage in that response. Runtime turns a failed stream into an assistant
message with zero usage. The ledger therefore cannot distinguish a request
that spent nothing from a request whose spending was not reported.

A successful assistant message has a different responsibility: its usage
describes the final response, which context estimation and overflow
classification consume. Replacing that usage with the sum of fallback
attempts would fix a cost total by breaking the next request's context size.

Numeric dollar totals have the same missing-evidence problem. An absent
rate card becomes zero, and a sum mixing priced and unpriced requests can
appear to be a complete estimate. ChatGPT plan consumption introduces a
second distinction: an operator-supplied API rate card can provide a
reference estimate, but it cannot establish consumed ChatGPT credits or
remaining plan allowance.

## Proposal

Add one typed evidence field to `core/message.Usage`. Its opaque value
records token coverage, estimate coverage, and the estimate's basis. Coverage
is `Unknown`, `Partial`, or `Complete`; an unavailable estimate has no
invented basis, while priced estimates distinguish ordinary API rates from
subscription API reference rates and a mixed estimate. Smart
constructors and a shared addition function preserve these properties.
The total includes the counts actually reported by each attempt. Missing
cache-partition details make bucket allocation and rate estimates provisional:
an inclusive prompt count allocated to uncached input can overstate that
bucket. Incomplete evidence therefore does not claim that every bucket or
dollar estimate is a lower bound. An explicit local refusal before dispatch
can establish no consumption; missing remote usage cannot. The trusted HTTP
transport expresses that refusal as terminal `RequestRefused(status, body)`
before admitting inference. Ordinary HTTP failures never imply an empty
report. Its owner must still drain before the provider publishes failure.

Change the provider's terminal payload to carry an opaque request accounting
report independently of the assistant message:

```gleam
pub type StreamEvent {
  Delta(delta: Delta)
  Settled(message: SettledAssistantMessage, accounting: RequestAccounting)
  Failed(error: ProviderError, accounting: RequestAccounting)
}
```

`RequestAccounting` holds the aggregate usage, the final attempt's usage,
and the number of attempts in constant space. Construction prices each
attempt under its actual resolved provider's rate card before adding it.
The empty report is the addition identity and establishes zero remote
attempts. Appending an attempt replaces the final-attempt observation and adds its
reported usage once. It never adds repeated snapshots of the same attempt.
The message's usage remains the final response's usage.

Add a pure usage-snapshot callback to `ResponseMachine`. Local cancellation,
deadline, disconnect, and malformed-stream paths obtain the same accumulated
report as a remote terminal. A snapshot that precedes a final provider usage
witness remains partial. No snapshot means unknown usage. Accounting does
not change cancellation custody, the original monitor, or retry eligibility.

The runtime passes accounting separately into the machine's settlement
observation. Settlement inserts one usage row under the request's existing
reserved usage ID. The row's `usage` is the aggregate; its existing `details`
field carries a versioned, typed final-attempt observation and attempt count
in its own namespace, preserving existing details such as distillation phase.
The assistant entry, usage row, and next operation state still commit in one
transaction. A machine-level retry creates its own row as it does today.
Summary and distillation requests preserve failure usage through their own
existing ledger owner.

## Evidence and presentation

The shared aggregate operation combines coverage as well as counters. An
unknown attempt combined with known consumption yields a partial total.
Missing pricing never makes a request free; configured zero rates can
establish a complete zero estimate. Reasoning is already a subset of output
and is not charged again. Uncached input, cache reads, cache writes, and
output remain disjoint buckets.

Views show complete estimates, partial estimates, and unavailable estimates
explicitly. Subscription reference estimates identify their API basis and
remain separate from ChatGPT plan usage. Actual allowance and credit state
belongs to ChatGPT's usage surface; this contract exposes no invented credit
conversion or remaining-percentage counter. Goal accounting counts uncached
input plus output without subtracting cache buckets a second time, and does
not present incomplete cost evidence as a fully measured spend.

Context and cache projections select the final-attempt observation from
ledger details rather than the request aggregate. Entry-local usage remains
available to existing context readers. An unknown final observation with all
primary token counters zero is not a context measurement: readers preserve
their prior context and cache state. Complete or partial zero observations,
and historical nonzero observations, remain measurements. A session fork copies history but
starts with an empty ledger; copied entry usage is never charged again.

## Durability and compatibility

The usage codec writes the new evidence field and rejects malformed present
evidence. Historical records without it remain readable with unknown
coverage. Storage needs no new SQL column: the payload remains JSON, and
the usage row's existing details field carries the bounded observation.
Live wire readers and writers ship together; the client protocol must carry
the evidence and final-attempt observation wherever it transports ledger
usage, so a remote view has the same meaning as a local view.

Owner loss before terminal publication cannot reconstruct remote billing.
A surviving custodian preserves the reports it actually retained and marks
the unfinished attempt unknown. One private report replacement at the existing
gateway guard retains completed fallback reports without a new handshake.
A snapshot callback cannot recover state from a dead process. Recovery without a retained report writes
unknown coverage. This proposal does not claim that every remote charge can
be recovered after a process or host crash, and it adds no per-attempt
durable acknowledgement protocol.

## Alternatives and cost

Putting totals in failure context cannot cover successful fallback, and
context normalization and retry classification are deliberately about local
failure observations. Hiding a report in assistant diagnostics requires
fallible decoding during settlement and makes the terminal contract unable
to state the accounting invariant. A typed terminal report gives consumers
the evidence directly and leaves diagnostics with their existing purpose.

A list of all attempts is unnecessary for totals and introduces retention
proportional to a configured route. The aggregate and final observation are
enough for billing estimates, context, and cache projections. A durable
acknowledgement before each fallback could retain more observations through
crashes, but changes scheduling and the effect sandwich for a property this
migration does not promise.

The cost is a compiler-visible change to usage constructors, terminal
consumers, the machine observation, and codecs. Shared constructors and
aggregation keep the evidence rules in one pure module. Tests and fixtures
must assign evidence intentionally rather than infer it from numeric zero.

## Verification

Required negative and positive cases are: a usage-bearing failure followed
by a differently priced successful fallback; an exhausted chain; known and
unknown usage in one chain; repeated provider snapshots followed by a
disconnect or cancellation; Responses failures with reported, missing, zero,
and malformed usage; configured zero rates versus no rate card; a real
settlement racing cancellation; owner loss and recovery; old and new codec
round trips; malformed evidence refusal; mixed subscription/API estimates;
goal counters with both uncached and cached input; unchanged final context
and cache measurements after fallback; and a session fork with a fresh
ledger. The repository gates and independent final review remain required.

## Decision

Accepted after independent read-only critique. The review favored the typed
terminal over diagnostic metadata and the constant aggregate over an attempt
list. Its corrections are incorporated above: provisional cache allocation,
an unavailable estimate basis, an empty identity, replacement snapshots,
retained evidence at the existing guard, final-attempt data on live observation
events, shared evidence-aware addition, and namespaced ledger details.
The cache-subtraction finding was verified against the Responses normalization
and the goal counter before including its correction.

No new retry machinery, credit conversion, remaining allowance estimate,
billing reconciliation service, or durable per-attempt acknowledgement is
part of this decision. The final implementation review and repository gates
remain outstanding.

## Goal estimate witness

The goal state cell and its client board add `cost_evidence`, encoded with
the same total evidence codec as `Usage.evidence`. The goal writer folds
this witness alongside primary usage rows and its durable accounting cursor.
New goals start with the no-consumption identity; historical cells without
the field read as unknown coverage, and malformed present fields are refused.
The cost remains a display estimate and never gates continuation. Plan
estimates are labelled as API reference estimates on both goal panels.

This extends protocol 044's goal and board fields under the same accepted
migration. Its uncached-token formula is `input + output`: `Usage.input` is
already the uncached partition, and subtracting cache counters again loses
counted primary work. Reasoning remains a subset of output.

## Addendum, October 8, 2026: evidence as a plain sum type

Review of the implementation replaced the opaque evidence value described in
the proposal with public constructors whose shape rules out the states the
smart constructors used to refuse at runtime. `Evidence` is now `NoProvider`
or `Remote(billing, tokens)`; tokens are `Unreported` or
`Reported(coverage, cost)`; a cost is `Unpriced` or `Priced(coverage,
basis)`; and coverage is `Partial` or `Complete`. The proposal's `Unknown`
coverage is the `Unreported` token state, and an unknown token count can no
longer carry a price. The local no-consumption identity is the single
`NoProvider` constructor rather than a matching billing and cost pair. The
`mixed` billing arrangement had no reader distinct from `other` and is
merged into it.

`RequestAccounting` stays opaque. Its representation is either no attempts or
an aggregate, a final observation and a count, so a report with attempts and
no final observation, or a final observation with no attempts, cannot be
built.

The encoding is unchanged. Every evidence form written before this addendum
decodes to the equivalent value, a stored `mixed` billing decodes as `other`,
and decoding still refuses the stored combinations the new types cannot
represent. `core/test/core/durable_usage_compat_test.gleam` pins those forms
as literal JSON.
