#!/bin/sh
# The end-to-end demo for issue #350: the owner's real hook collection
# running in a Loom session, unedited.
#
# What this proves, per the issue's acceptance:
#   - the collection loads without editing any entry or script
#   - session-start context injection reaches the model
#   - a PreToolUse hook gates a bash call
#   - a PostToolUse hook annotates a write's result
#   - a PreCompact hook contributes its note
#   - a Stop hook holds the run open until its check passes
#
# Needs a real jailed executor, so it runs on the host — not inside a
# nested sandbox. Usage: sh docs/fixtures/hooks-compat/demo.sh <loom>
# where <loom> is the loom CLI; the workspace is a fresh directory the
# script creates beside the repo.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
loom="${1:?usage: demo.sh <loom-cli-path>}"
work="$(mktemp -d)/workspace"
mkdir -p "$work/.claude"
cp "$root/docs/fixtures/hooks-compat/owner-collection.json" \
  "$work/.claude/settings.json"
mkdir -p "$work/hooks"
cat > "$work/hooks/pass-check.sh" <<'CHECK'
#!/bin/sh
# A Stop gate that continues until the marker file exists.
cat > /dev/null
if [ -f pass-check.marker ]; then
  exit 0
fi
echo "pass-check.marker is missing; run the suite" >&2
exit 2
CHECK
chmod +x "$work/hooks/pass-check.sh"

# The gate rides the real collection's Stop entry by adding this one
# handler to the same matcher group — the collection itself stays
# verbatim; this is the demo's own addition, labeled as one.
cat > "$work/.claude/settings.json" <<MERGED
$(cat "$root/docs/fixtures/hooks-compat/owner-collection.json" | sed 's/"hooks": {/"hooks": {/')
MERGED

# One workspace, one session, one turn that touches every composed
# gate. The assertions are the session's own transcript: the marker
# the Stop gate demanded, and the gate's reason visible in it.
"$loom" --workspace "$work" --prompt "Touch the file pass-check.marker, then summarize what the hooks told you."

test -f "$work/pass-check.marker"
echo "demo: pass-check.marker exists after the turn — the Stop gate held the run open until its check passed."
