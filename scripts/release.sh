#!/usr/bin/env bash
# release — cut a new bridger version.
#
# Claude Code decides a plugin has an update by comparing the "version" field
# in .claude-plugin/plugin.json against the installed copy. The git commit sha
# is NOT the signal: you can push all day, but until that string changes an
# auto-updating marketplace has no reason to re-fetch. This script makes the
# version bump, the README badge, a CHANGELOG entry, the commit, the tag, the
# push, and the GitHub Release one atomic step — so the thing that triggers an
# update is never forgotten, and every release documents itself.
#
# Usage: scripts/release.sh <version> [--notes <file>] [--push]
#   scripts/release.sh 0.7.0                   bump, changelog, test, commit, tag (local)
#   scripts/release.sh 0.7.0 --notes notes.md  take the changelog/release body from a file
#   scripts/release.sh 0.7.0 --push            ... and push + open the GitHub Release
#
# Without --notes the changelog body is drafted from the commit subjects since
# the last version tag; edit CHANGELOG.md afterward if you want it tighter.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

die() { echo "release: $*" >&2; exit 1; }

version=""
push=0
notes_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push)  push=1; shift ;;
    --notes) notes_file="${2:-}"; shift 2 ;;
    -*)      die "unknown option: $1" ;;
    *)       [ -z "$version" ] || die "unexpected argument: $1"; version="$1"; shift ;;
  esac
done

[ -n "$version" ] || die "usage: scripts/release.sh <version> [--notes <file>] [--push]"
echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version must be X.Y.Z, got: $version"

# The release commit must contain only the release — refuse to bury it in
# unrelated uncommitted work.
[ -z "$(git status --porcelain)" ] || die "working tree not clean — commit or stash first"

plugin=".claude-plugin/plugin.json"
readme="README.md"
changelog="CHANGELOG.md"
current="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$plugin" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "$version" != "$current" ] || die "already at $version"

# Release notes: an explicit file, else a draft from the commits since the last
# version tag (release commits themselves filtered out).
if [ -n "$notes_file" ]; then
  [ -f "$notes_file" ] || die "notes file not found: $notes_file"
  notes="$(cat "$notes_file")"
else
  lasttag="$(git tag --list 'v*' --sort=-version:refname | head -1)"
  notes="$(git log --format='- %s' "${lasttag:+$lasttag..}HEAD" | grep -vE '^- release: ' || true)"
  [ -n "$notes" ] || notes="- Maintenance release."
fi

# One temp file holds the notes for both the changelog entry and the release.
# (Passing multi-line notes through awk -v trips BSD awk's "newline in string".)
notes_tmp="$(mktemp)"
trap 'rm -f "$notes_tmp"' EXIT
printf '%s\n' "$notes" >"$notes_tmp"

today="$(date +%Y-%m-%d)"
repo_url="$(git remote get-url origin 2>/dev/null \
  | sed -E 's#git@github.com:#https://github.com/#; s#\.git$##')"

# 1. plugin.json — the field Claude Code compares.
tmp="$(mktemp)"
sed -E "s/(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1$version\2/" "$plugin" >"$tmp"
mv "$tmp" "$plugin"

# 2. README badge — keep the number shown to readers honest (alt + shields url).
tmp="$(mktemp)"
sed -E "s/version-$current-/version-$version-/g; s/(alt=\"version )$current(\")/\1$version\2/g" "$readme" >"$tmp"
mv "$tmp" "$readme"

# 3. CHANGELOG — prepend this version above the newest existing entry, and its
#    link reference above the newest existing one.
if [ -f "$changelog" ]; then
  tmp="$(mktemp)"
  awk -v ver="$version" -v date="$today" -v url="$repo_url/releases/tag/v$version" -v nf="$notes_tmp" '
    !sec && /^## \[/ {
      print "## [" ver "] — " date; print ""
      while ((getline line < nf) > 0) print line
      close(nf); print ""; sec=1
    }
    !ref && /^\[[0-9]/ { print "[" ver "]: " url; ref=1 }
    { print }
  ' "$changelog" >"$tmp"
  mv "$tmp" "$changelog"
fi

# 4. gate — never tag a release the self-check rejects.
./test.sh

# 5. commit + annotated tag.
git add "$plugin" "$readme"
[ -f "$changelog" ] && git add "$changelog"
git commit -m "release: v$version"
git tag -a "v$version" -m "v$version"

if [ "$push" -eq 0 ]; then
  echo "staged v$version locally. review: git show"
  echo "publish:  git push origin HEAD refs/tags/v$version   (or re-run with --push)"
  exit 0
fi

# 6. publish: push the branch + tag, then open the GitHub Release.
git push origin HEAD "refs/tags/v$version"
echo "pushed v$version — Claude Code picks it up on the next marketplace refresh."

if command -v gh >/dev/null 2>&1; then
  gh release create "v$version" --title "v$version" --latest --notes-file "$notes_tmp"
  echo "opened GitHub Release v$version."
else
  echo "gh not found — open the release manually once installed:"
  echo "  gh release create v$version --title \"v$version\" --notes-file CHANGELOG.md"
fi
