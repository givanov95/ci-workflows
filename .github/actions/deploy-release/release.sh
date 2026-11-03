#!/usr/bin/env bash
# Deploy release (see action.yml): the two steps of the action, driven by the environment.
#
#   release.sh check   VERSION_URL, EXPECTED -> output sha (the commit the site runs)
#       Reads version.json ({"sha":"<short or full SHA>", ...}, written by the deploy script on the
#       server) and compares it with EXPECTED, the commit this run deployed.
#       exit 0 - the site runs EXPECTED                                       (sha = EXPECTED)
#       exit 0 - the site runs a NEWER commit that contains EXPECTED, warning (sha = that commit):
#                the server pulled the branch head, which a later push had moved; EXPECTED is live
#       exit 1 - anything else: another (older / diverged / unknown) commit, no version, a GitHub
#                error. The job fails, so the steps after it (the board) are skipped.
#   release.sh tag     SHA -> outputs tag, release (new | existing | failed)
#       Tag + GitHub release vYYYY.MM.DD (Europe/Sofia; a second release that day is .2, then .3 ...)
#       on SHA, with the notes of the PRs since the previous release (--generate-notes). Nothing is
#       created when a vYYYY.MM.DD[.N] tag already points at SHA (a re-run). Always exits 0: a failed
#       release must not undo a good deploy, so it is an ::error:: annotation and release=failed.
#
# Both need GH_TOKEN and GH_REPO (owner/repo). There is no checkout: everything goes through the
# GitHub API. Same logic as plugins/gws/scripts/release.sh (check + tag) of givanov95/claude-flow,
# which /gws:ship uses for deploys that do not run on GitHub Actions: change both together.
# Tested by tests/deploy-release/release.test.sh.
set -euo pipefail

out() { [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1" >> "$GITHUB_OUTPUT"; }
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/deploy-release.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
: "${GH_REPO:?GH_REPO (owner/repo) is not set}"

check() {
  local fail='::error title=Deploy release - version::'
  [[ "${EXPECTED:-}" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "${fail}expected-sha must be a full 40-character commit SHA, not '${EXPECTED:-}'"; exit 1; }
  [ -n "${VERSION_URL:-}" ] || { echo "${fail}version-url is empty"; exit 1; }

  local body="" sep attempt deployed full status
  case "$VERSION_URL" in *\?*) sep='&';; *) sep='?';; esac
  for attempt in 1 2 3; do
    # a unique query string and no-cache get past a CDN / proxy cache; curl's stderr (a warning on
    # success) must not end up in the JSON
    if body="$(curl -fsS --max-time 10 -H 'Cache-Control: no-cache' "$VERSION_URL${sep}t=$(date +%s)" 2>"$tmp/curl.err")"; then break; fi
    body=""; [ "$attempt" -lt 3 ] && sleep 5
  done
  [ -n "$body" ] || { echo "${fail}$VERSION_URL does not answer - the site does not report its version ($(head -c 200 "$tmp/curl.err" | tr '\n' ' '))"; exit 1; }
  deployed="$(printf '%s' "$body" | jq -r 'if type == "object" then (.sha // "") else "" end' 2>/dev/null || true)"
  [[ "$deployed" =~ ^[0-9a-f]{7,40}$ ]] || { echo "${fail}$VERSION_URL has no valid sha (answer: $(printf '%s' "$body" | head -c 120 | tr '\n' ' '))"; exit 1; }

  if [[ "$EXPECTED" == "$deployed"* ]]; then
    echo "the site runs ${EXPECTED:0:12}"
    out "sha=$EXPECTED"; return 0
  fi
  # Another commit. An unknown one (404/422) is a mismatch; any other GitHub error says so, not
  # "mismatch". On an HTTP error gh prints the response body to stdout, so look at the exit code.
  if ! full="$(gh api "repos/$GH_REPO/commits/$deployed" --jq .sha 2>"$tmp/gh.err")"; then
    case "$(cat "$tmp/gh.err")" in
      *"HTTP 404"*|*"HTTP 422"*) echo "${fail}the site runs $deployed, which is not in $GH_REPO - not ${EXPECTED:0:12}";;
      *) echo "${fail}GitHub error while resolving $deployed: $(head -c 300 "$tmp/gh.err" | tr '\n' ' ')";;
    esac
    exit 1
  fi
  [[ "$full" =~ ^[0-9a-f]{40}$ ]] || { echo "${fail}GitHub gave no commit for $deployed"; exit 1; }
  status="$(gh api "repos/$GH_REPO/compare/$EXPECTED...$full" --jq .status 2>"$tmp/gh.err")" \
    || { echo "${fail}GitHub error while comparing ${EXPECTED:0:12} with ${full:0:12}: $(head -c 300 "$tmp/gh.err" | tr '\n' ' ')"; exit 1; }
  if [ "$status" != ahead ]; then
    echo "${fail}the site runs ${full:0:12}, not ${EXPECTED:0:12} ($status) - the deploy did not ship this commit"; exit 1
  fi
  echo "::warning title=Deploy release - version::the site runs a newer commit ${full:0:12} that contains ${EXPECTED:0:12} - it is live without its own run"
  out "sha=$full"
}

tag() {
  failed() { # a failed release is reported, never fatal (see the top)
    echo "::error title=Deploy release - release::$1 - no release for ${SHA:0:12}; the deploy itself is fine (/gws:ship creates the release when it finds none: release.sh tag)"
    out "tag="; out "release=failed"; exit 0
  }
  [[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] || failed "no commit to release ('${SHA:-}')"

  local tags existing day name n
  # All tag kinds: an annotated tag's sha is the tag object (never matches the commit), but its name
  # is taken and must count for .N. A GitHub error must not look like "no tags" (a duplicate name).
  tags="$(gh api --paginate "repos/$GH_REPO/git/matching-refs/tags/v" \
            --jq '.[] | "\(.ref | ltrimstr("refs/tags/"))\t\(.object.sha)"' 2>"$tmp/gh.err")" \
    || failed "cannot read the tags of $GH_REPO: $(head -c 300 "$tmp/gh.err" | tr '\n' ' ')"
  tags="$(printf '%s\n' "$tags" | grep -E '^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?'$'\t' || true)"
  existing="$(awk -F'\t' -v s="$SHA" '$2 == s {print $1; exit}' <<< "$tags")"
  if [ -n "$existing" ]; then
    echo "${SHA:0:12} is already released as $existing"
    out "tag=$existing"; out "release=existing"; return 0
  fi
  day="v$(TZ=Europe/Sofia date +%Y.%m.%d)"; name="$day"; n=1
  # awk, not `| grep -q`: with pipefail an early exit of grep can kill the writer with SIGPIPE
  while awk -F'\t' -v t="$name" '$1 == t {f = 1} END {exit !f}' <<< "$tags"; do n=$((n+1)); name="$day.$n"; done
  gh release create "$name" --repo "$GH_REPO" --target "$SHA" --title "$name" --generate-notes >/dev/null 2>"$tmp/gh.err" \
    || failed "gh release create $name failed: $(head -c 300 "$tmp/gh.err" | tr '\n' ' ')"
  echo "::notice title=Deploy release::production is $name (${SHA:0:12})"
  out "tag=$name"; out "release=new"
}

case "${1:-}" in
  check) check ;;
  tag) tag ;;
  *) echo "usage: release.sh check | tag" >&2; exit 2 ;;
esac
