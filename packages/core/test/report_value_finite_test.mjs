// Run after `gleam build --target javascript` with `node test/report_value_finite_test.mjs`.
// JavaScript can construct the nonfinite FloatValue terms that Erlang cannot.
import assert from 'node:assert/strict';
import * as rv from '../build/dev/javascript/core/core/report_value.mjs';
import * as mp from '../build/dev/javascript/core/core/msgpack.mjs';
import { Ok, Error as GleamError, toList } from '../build/dev/javascript/core/gleam.mjs';

const checkedMetadata = rv.metadata(
  'sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  new rv.Enforcement(new rv.Unreported('not launched'), new rv.Unreported('not launched')),
  new rv.CallLog(0, 0, 0, 0, 0, 0, toList([])),
);
assert(checkedMetadata instanceof Ok, 'The finite fixture has checked metadata.');

// Each public constructor must apply the same recursive admission invariant.
const nonfiniteFailures = [];
for (const value of [Infinity, -Infinity, NaN]) {
  const term = new mp.FloatValue(value);
  const outcomes = [
    new rv.Completed(term),
    new rv.Completed(new mp.ArrayValue(toList([new mp.IntValue(1), term]))),
    new rv.Completed(new mp.MapValue(toList([[term, new mp.IntValue(1)]]))),
    new rv.Errored('failed', term),
  ];
  for (const [index, outcome] of outcomes.entries()) {
    if (!(rv.encode_terminal(outcome) instanceof GleamError)) {
      nonfiniteFailures.push(`terminal ${value} shape ${index}`);
    }
    if (!(rv.from_outcome(outcome, checkedMetadata[0]) instanceof GleamError)) {
      nonfiniteFailures.push(`report ${value} shape ${index}`);
    }
  }
}

// Range endpoints, subnormals and signed zero remain admissible and exact.
for (const value of [Number.MAX_VALUE, -Number.MAX_VALUE, Number.MIN_VALUE, -Number.MIN_VALUE, 0, -0, 1, -1]) {
  const outcome = new rv.Completed(new mp.FloatValue(value));
  const terminal = rv.encode_terminal(outcome);
  assert(terminal instanceof Ok, `Admit finite terminal ${value}.`);
  const terminalReadback = rv.decode_terminal(terminal[0]);
  assert(terminalReadback instanceof Ok, `Read finite terminal ${value}.`);
  assert(Object.is(terminalReadback[0].value.value, value), `Preserve terminal float ${value}.`);

  const report = rv.from_outcome(outcome, checkedMetadata[0]);
  assert(report instanceof Ok, `Admit finite report ${value}.`);
  const reportReadback = rv.decode(rv.bytes(report[0]));
  assert(reportReadback instanceof Ok, `Read finite report ${value}.`);
  assert(Object.is(rv.outcome(reportReadback[0]).value.value, value), `Preserve report float ${value}.`);
}
assert.deepEqual(nonfiniteFailures, [], 'Both constructors refuse every nonfinite shape.');
console.log('Nonfinite refusal: 24 checks; finite admission and exact readback: 48 checks passed.');
