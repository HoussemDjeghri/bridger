#!/usr/bin/env bash
# release — cut a new bridger version.
#
# Claude Code decides a plugin has an update by comparing the "version" field
# in .claude-plugin/plugin.json against the installed copy. The git commit sha
# is NOT the signal: you can push all day, but until that string changes an
# auto-updating marketplace has no reason to re-fetch. This script makes the
# bump, the README badge, the test gate, the commit, and the tag one atomic
# step, so the one thing that actually triggers an update is never forgotten.
#
# Usage: scripts/release.sh <version> [--push]
#   scripts/release.sh 0.6.1           bump, test, commit, tag (local only)
#   scripts/release.sh 0.6.1 --push    ... and push the branch + tag to origin
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="${1:-}"
push=0
[ "${2:-}" = "--push" ] && push=1

[ -n "$version" ] || { echo "usage: scripts/release.sh <version> [--push]" >&2; exit 1; }
echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "version must be X.Y.Z, got: $version" >&2; exit 1; }

# The release commit must contain only the bump — refuse to bury it in
# unrelated uncommitted work.
[ -z "$(git status --porcelain)" ] \
  || { echo "working tree not clean — commit or stash first" >&2; exit 1; }

plugin=".claude-plugin/plugin.json"
readme="README.md"
current="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$plugin" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "$version" != "$current" ] || { echo "already at $version" >&2; exit 1; }

# 1. plugin.json — the field Claude Code compares.
tmp="$(mktemp)"
sed -E "s/(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1$version\2/" "$plugin" >"$tmp"
mv "$tmp" "$plugin"

# 2. README badge — keep the number shown to readers honest (alt + shields url).
tmp="$(mktemp)"
sed -E "s/version-$current-/version-$version-/g; s/(alt=\"version )$current(\")/\1$version\2/g" \
  "$readme" >"$tmp"
mv "$tmp" "$readme"

# 3. gate — never tag a release the self-check rejects.
./test.sh

# 4. commit + annotated tag.
git add "$plugin" "$readme"
git commit -m "release: v$version"
git tag -a "v$version" -m "v$version"

if [ "$push" -eq 1 ]; then
  git push origin HEAD "refs/tags/v$version"
  echo "pushed v$version — Claude Code picks it up on the next marketplace refresh."
else
  echo "staged v$version locally. review: git show"
  echo "publish:  git push origin HEAD refs/tags/v$version   (or re-run with --push)"
fi
