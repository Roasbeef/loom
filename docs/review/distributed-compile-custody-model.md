# Compile custody model review

The existing P product model now separates a retained native terminal payload
from its reducer commit. This exposes the production window in which bytes exist
but cannot yet justify an outer Compile completion. A Before-native error also
requires the original live Preparing claim and atomically fences late Ready.
Ready with an unassociated Submit in flight remains uncertain.

Four directed scenarios and exact witness probes exercise those transitions,
historical completion readback and independent receipts. Outer acknowledgement,
native owner receipt, native retirement and resource cleanup remain separate
facts. The native Executor and Types change only to represent the terminal
payload/commit split; the existing native Owner, Helper and safety monitor remain
unchanged.

Independent Astra review found no actionable findings. It traced actual actor
transitions and confirmed that the three new mutants weaken real decisions while
leaving monitors intact. The complete frozen manifest and both compiled model
snapshots match the reviewed source.

Root independently ran the strict safety/reachability gate: exit zero in
243.375 seconds, with 35 normal cases at 1,000 schedules each and 44 exact-marker
probes bounded at 2,000 schedules. The strict mutation gate exited zero in
88.182 seconds: all 30 unchanged controls passed 100 schedules, every mutant
compiled, and each failed its intended runtime assertion. Probe assertion failures
are expected witnesses; the runner rejects unrelated assertions, compile errors,
missing witnesses, timeouts and resource-limit exits. Source hashes remained
unchanged after both gates.

The new mutations admit late Ready after Before settlement, manufacture a Before
result after Ready without an association, and settle from terminal payload alone.
Each reaches its corresponding monitor assertion. Earlier controls and mutations
remain registered. The seed is 697; step, memory and deadline bounds are unchanged.
An initial development compile failed because of declaration placement and is
retained separately from the passing evidence.

These checks establish bounded safety and reachability within the modeled
identities and equality classes. They do not prove SQLite crash atomicity, encoded
byte correctness, cryptography, transport or kernel cleanup. This slice neither
reruns nor extends the separate PlusCal/TLC and Lean models, and it is not an
end-to-end refinement proof of the shipped remote runtime.
