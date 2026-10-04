# Bounded command proposals

The command codec preserves a physical service's complete original reference,
ordered region mappings, argv, environment, cwd and sandbox policy. Its opaque
value certifies bounded data. The owner still has to derive the expected
compiler or satellite command from retained input, pinned enrollment and
prepared resources before clearance.

## Boundaries

The constructor checks fixed list prefixes and string bytes before converting
policy records. It then counts exact canonical MessagePack bytes and nodes.
Peer frames pass the shared raw preflight before decoding. The policy is a
nested value, so it cannot hide an unchecked tree in a binary field. The
reference uses a separately bounded canonical JSON header. Both that header
and the complete frame must reproduce their original encoding.

The fixed envelope admits 256 KiB, 2,048 nodes, depth 16, 128 array elements
or map entries, 8 KiB strings and 128 KiB binaries. Command arguments have a
128-item ceiling and environment pairs have a 64-item ceiling. Aggregate
access paths have a separate 128-path limit. Logical bounds do not promise an
equal amount of BEAM resident memory.

## Validation and review

The frozen component is `6b08cd2e`; integration carries the same four files
as `1f5b4f59b`. Thirteen focused codec tests passed, including an exact 256-KiB
boundary, a one-byte overflow, canonical framing, full-policy preservation and
hostile nested values. Bypassing preflight compiled but failed the hostile-tree
control. Dropping the policy environment field compiled but failed five
preservation controls. Both mutations were reverted to the frozen source hash.

The worker's complete broker gate passed 421 tests. Root independently reran
the complete gate with host access: exit 0 in 100.623 seconds. Two existing
Darwin tests explicitly skip Linux `/proc` kill witnesses. Existing dependency
warnings remain separate from the warning-free broker build. The initial root
run inside the outer tool sandbox failed on listener and Darwin process-table
permissions; those failures were not counted as successful verification.
Worker format, lint and documentation gates exited zero.

The independent Astra pass checked the frozen source and test hashes, integer
and subfield bounds, canonical encoding, complete policy preservation and the
mutation assertions. It found no actionable defect. No semantic command
acceptance, physical resource preparation or separate-host execution was
claimed by this codec gate.
