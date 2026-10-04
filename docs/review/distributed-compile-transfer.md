# Compile completion transport review

The existing bounded workspace transfer now has a closed Compile completion
kind. Its new tag is 2; tags 0 and 1 keep their existing encodings and ceilings.
At the 256-KiB aggregate limit, four 64-KiB data chunks follow the fixed header.
Every individual frame fits the unchanged TLS bound. Length, direction, offset,
chunk size and final digest checks share the existing implementation.

Root independently ran all 194 executor tests without reported skips in
96.054 seconds. Nine focused controls cover exact aggregate length, the first
excess byte, wrong direction, duplicate and reordered chunks, and corrupt digests.
The real mutually authenticated TLS test carries all three content maxima under
one finite whole-exchange deadline. A compiling one-byte ceiling mutation returns
an oversized Sender and fails the intended assertion; source restoration is exact.

Independent review found no production defect. It identified an unrelated reason
for one scanner assertion to pass: the excess-size fixture contained malformed
MessagePack. The corrected fixture contains two individually bounded binaries
whose valid encoded shape exceeds only the aggregate limit. Root reran all nine
focused tests after that correction; they passed in 0.735 seconds. Production
and documentation hashes were unchanged. The original and corrected freeze
manifests are retained separately.

The exact-limit scanner fixture proves byte/scanner agreement; it is not a
semantically valid Compile completion. Callers still authenticate scope, decode
against full original identity, enforce whole-exchange deadlines and connection
credits, then retain the result before acknowledgement. This component neither
creates a physical Compile service nor proves separate-host acceptance.
