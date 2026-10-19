#!/bin/sh
# Print the commit this source tree was built from.
#
# A build learns its commit in three steps. A git checkout (or worktree)
# answers with `git rev-parse HEAD`. A tree made by `git archive` has no
# .git, but the BUILD_COMMIT file at the root is marked `export-subst` in
# .gitattributes, so git replaced its `$Format:%H$` placeholder with the
# archived commit. A tree with neither prints `unknown`, which is what it
# honestly has. The `.git` test matters: an archive unpacked inside some
# other repository must not report that repository's HEAD.
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -e "$root/.git" ]; then
  if commit="$(git -C "$root" rev-parse HEAD 2>/dev/null)"; then
    echo "$commit"
    exit 0
  fi
fi
if [ -f "$root/BUILD_COMMIT" ]; then
  commit="$(tr -d '[:space:]' < "$root/BUILD_COMMIT")"
  case "$commit" in
    ''|*'$Format'*) ;;
    *) echo "$commit"; exit 0 ;;
  esac
fi
echo unknown
