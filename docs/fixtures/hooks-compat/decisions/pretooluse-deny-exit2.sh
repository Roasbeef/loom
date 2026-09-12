#!/bin/sh
# The contract's blocking exit: exit 2 with the reason on stderr.
# Pinned by hookdecisions_test.pretooluse_exit_two_blocks_with_stderr_test
cat > /dev/null
echo "no rm allowed" >&2
exit 2
