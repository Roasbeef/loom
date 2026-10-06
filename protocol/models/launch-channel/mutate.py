#!/usr/bin/env python3
"""Compile isolated fault mutations; unchanged monitors must report exact violations."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
from runner import ROOT, check, compile_model, hashes, record, snapshot

MUTATIONS = [
 ('chunk-credit', 'tcReply', 'frame credit returned before exact consumed ACK',
  '      announce mChunk, key(p);',
  '      announce mChunk, key(p);\n      announce mFreed, lanes[(id = p.identity.id, direction = p.direction)].frame;'),
 ('completion-slot', 'tcReply', 'CapDone released slot before original consumed write',
  '      announce mCallSettled, (identity = p.identity, call = p.call);',
  '      announce mCallSettled, (identity = p.identity, call = p.call);\n      rows[p.identity.id].calls -= (p.call);\n      announce mCallReleased, (identity = p.identity, call = p.call);'),
 ('stale-sequence', 'tcStale', 'stale ACK changed current directional reservation',
  'if (lane.window != Pending || lane.frame.key != key(p) || !lane.frame.consumed ||',
  'if (lane.window != Pending || !lane.frame.consumed ||'),
 ('retired-ack', 'tcRetirement', 'late ACK resurrected retired channel',
  'if (lane.window != Pending || lane.frame.key != key(p) || !lane.frame.consumed ||\n        (rows[id].phase != Active && !(rows[id].phase == Terminating && lane.frame.final)))',
  'if (lane.frame.key != key(p) || !lane.frame.consumed)'),
 ('final-credit', 'tcTerminal', 'frame credit returned before exact consumed ACK',
  'if (lane.frame.final) { lanes[address].window = Finished;',
  'if (lane.frame.final) { lanes[address].window = Available; announce mFreed, lane.frame;'),
 ('terminal-destroy', 'tcTerminal', 'terminal destroy preceded final consumption ACK',
  '      announce mTerminalValidated, lane.frame;\n      consume(p.identity, ToOwner, true);',
  '      announce mTerminalValidated, lane.frame;\n      destroy(p.identity);\n      consume(p.identity, ToOwner, true);'),
 ('cancel-writer-queue', 'tcCancel', 'cancellation deferred behind blocked writer data',
  '      retire(p.identity); destroy(p.identity); announce mCancelReturned, p.identity;',
  '      retire(p.identity); announce mCancelReturned, p.identity;'),
 ('uncertain-refund', 'tcCancel', 'uncertainty refunded original inbound byte admission',
  '    announce mRetired, id;',
  '    lanes[(id = id.id, direction = ToOwner)].spent = 0;\n    lanes[(id = id.id, direction = ToSocket)].spent = 0;\n    announce mRetired, id;'),
 ('stream-metadata', 'tcCancel', 'channel lifetime borrowed endpoint metadata credit',
  'if (p.payload != 0 || slot < 0 || slot >= 6 || slot in metadata)',
  'if (slot < 0 || slot >= 6 || slot in metadata)'),
 ('release-resources', 'tcActive', 'Launch entry released before independent resource joins and native retirement',
  '!row.readerJoined || !row.writerJoined || !row.nativeRetired || !row.resourcesReleased)',
  '!row.readerJoined || !row.writerJoined || !row.nativeRetired)'),
 ('outcome-delete', 'tcReport', 'execution directory deleted on known outcome without safe cleanup',
  '      if (!row.cleanupSafe) { view(p.identity, Refused); return; }',
  '      if (!row.terminal) { view(p.identity, Refused); return; }'),
 ('end-overtakes', 'tcEnd', 'channel EOF overtook unconsumed original frame',
  'p.direction != ToOwner || p.sequence != lane.sequence ||\n        (lane.window != Available && lane.window != Finished))',
  'p.direction != ToOwner || p.sequence != lane.sequence)'),
 ('activate-before-custody', 'tcStartup', 'inbound activated before custody or after original retirement',
  'if (row.phase != PreparedPaused || !row.custody || row.activated || !row.ownerAlive)',
  'if (row.phase != PreparedPaused || row.activated || !row.ownerAlive)'),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schedules', type=int, default=100)
    parser.add_argument('--seed', type=int, default=697)
    parser.add_argument('--mutation', action='append')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.schedules <= 0 or args.seed < 0:
        parser.error('positive schedule count and nonnegative seed required')
    chosen = MUTATIONS
    if args.mutation:
        if set(args.mutation) - {m[0] for m in chosen}:
            parser.error('unknown mutation')
        chosen = [m for m in chosen if m[0] in args.mutation]
    out = args.output or ROOT / 'PCheckerOutput' / datetime.now(timezone.utc).strftime('mutations-%Y%m%dT%H%M%S%f')
    results = []
    control = snapshot(out / 'control/project')
    baseline = hashes(control)
    (out / 'source-hashes.json').write_text(json.dumps(baseline, indent=2) + '\n')
    try:
        results.append(compile_model(control, out / 'control'))
        for case in sorted({m[1] for m in chosen}):
            results.append(check(control, out / 'control' / case, case, args.schedules, args.seed))
        print('source-only unmodified controls: exit=0', flush=True)
        for name, case, marker, before, after in chosen:
            output = out / name
            project = snapshot(output / 'project')
            source = project / 'PSrc/Channel.p'
            body = source.read_text()
            if body.count(before) != 1:
                raise RuntimeError(f'{name}: mutation anchor is not unique')
            source.write_text(body.replace(before, after))
            changed = hashes(project)
            if {p for p in baseline if baseline[p] != changed[p]} != {'PSrc/Channel.p'}:
                raise RuntimeError(f'{name}: monitor or fixture changed')
            (output / 'source-hashes.json').write_text(json.dumps(changed, indent=2) + '\n')
            (output / 'mutation.json').write_text(json.dumps({'name': name, 'before': before, 'after': after,
                 'case': case, 'marker': marker, 'monitors_and_tests_unchanged': True}, indent=2) + '\n')
            results.append(compile_model(project, output))
            result = check(project, output / case, case, args.schedules, args.seed, marker)
            result['mutation'] = name
            results.append(result)
            print(f"{name}: compile=0 check={result['exit']} exact violation found", flush=True)
    finally:
        record(out / 'results.json', results)
    print(f'evidence: {out / "results.json"}', flush=True)


if __name__ == '__main__':
    main()
