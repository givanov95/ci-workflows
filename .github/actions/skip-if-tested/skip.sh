#!/usr/bin/env bash
# Skip if tested (see action.yml): has this exact code already passed this workflow?
#
#   skip.sh   EVENT, SHA, REF_NAME, BEFORE, WORKFLOW_REF, RUN_ID -> outputs skip (true | false), reason
#
# Only a push is checked (any other event: skip=false). The code counts as tested when a successful
# run of the SAME workflow file, from this repository and not Dependabot's, exists for:
#   a) the same commit, from a PUSH - e.g. a fast-forward staging -> main pushes a commit staging
#      already tested (a push run tests exactly its commit);
#   b) the head of a pull request merged into the pushed branch (REF_NAME), from a PULL_REQUEST run,
#      when that head has the same tree (the same files) as this commit AND contains BEFORE (the
#      branch before this push; the first parent when there is none). A pull_request run tests the
#      head merged with the base of that moment; every such base is an ancestor of BEFORE, so of the
#      head, and the tested files were the head's. A PR that was behind its base runs the tests.
# The same tree also means the same workflow file. A dispatch, schedule or Dependabot/fork run never
# counts: it may run other steps or lack secrets. b) works on the default branch only: for another
# branch GitHub lists only open PRs of a commit. Known gaps (see the README): one head opened as PRs
# to two bases or retargeted after its run (GitHub does not keep a merged PR's runs linked to it), a
# force-pushed target branch, steps that depend on the branch, a run whose test job was skipped.
#
# Always exits 0 and never skips on doubt: a GitHub error, a missing permission, a timeout or an
# unexpected answer is a warning and skip=false, so the tests run as they would without this action.
#
# Needs GH_TOKEN (actions: read, contents: read, pull-requests: read) and GH_REPO (owner/repo).
# No checkout: everything goes through the GitHub API. Tested by tests/skip-if-tested/skip.test.sh.
set -uo pipefail

out() { [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1" >> "$GITHUB_OUTPUT"; }
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/skip-if-tested.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

run_tests() { # run_tests <reason> [warning]
  [ -z "${2:-}" ] || echo "::warning title=Skip if tested::$2 - the tests run"
  echo "tests run: $1"
  out "skip=false"; out "reason=$1"; exit 0
}
skip() {
  echo "::notice title=Skip if tested::$1"
  out "skip=true"; out "reason=$1"; exit 0
}
# api <path> <jq filter>: the answer on stdout. Called in $(...), so it cannot end the script
# itself: on an error it returns 1 and the caller ends with `|| gh_error` (skip=false).
api() {
  $limit gh api "$1" --jq "$2" </dev/null 2>"$tmp/gh.err" || { printf '%s' "$1" > "$tmp/gh.path"; return 1; }
}
limit=""   # GNU timeout; gtimeout from coreutils on macOS; without either, no limit
if command -v timeout >/dev/null; then limit="timeout 30"; elif command -v gtimeout >/dev/null; then limit="gtimeout 30"; fi
gh_error() {
  run_tests "GitHub error" "GitHub error on $(cat "$tmp/gh.path" 2>/dev/null): $(head -c 300 "$tmp/gh.err" 2>/dev/null | tr '\n' ' ')"
}

[ "${EVENT:-}" = push ] || run_tests "not a push (${EVENT:-no event})"
[[ "${GH_REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || run_tests "no repository" "GH_REPO must be owner/repo, not '${GH_REPO:-}'"
[[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] || run_tests "no commit" "SHA must be a full commit SHA, not '${SHA:-}'"
[[ "${RUN_ID:-}" =~ ^[0-9]+$ ]] || run_tests "no run id" "RUN_ID must be a number, not '${RUN_ID:-}'"
[ -n "${REF_NAME:-}" ] || run_tests "no branch" "REF_NAME (the pushed branch) is not set"
# github.workflow_ref: owner/repo/.github/workflows/ci.yml@refs/heads/main
workflow="${WORKFLOW_REF:-}"; workflow="${workflow%%@*}"; workflow="${workflow##*/}"
[[ "$workflow" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || run_tests "no workflow" "cannot read the workflow file from WORKFLOW_REF '${WORKFLOW_REF:-}'"

runs="repos/$GH_REPO/actions/workflows/$workflow/runs"
# passed <sha> <event>: "<event> run <url>" of a successful <event> run of this workflow for <sha>,
# other than this run, from this repository (not a fork) and not started by Dependabot
passed() {
  api "$runs?head_sha=$1&event=$2&status=success&per_page=20" \
    "[.workflow_runs[] | select(.id != $RUN_ID and .event == \"$2\" and .head_repository.full_name == \"$GH_REPO\" and .actor.login != \"dependabot[bot]\")] | first | select(. != null) | \"\(.event) run \(.html_url)\""
}

# a) the same commit, tested by a push
found="$(passed "$SHA" push)" || gh_error
[ -z "$found" ] || skip "commit ${SHA:0:12} already passed this workflow ($found)"

# b) the head of a PR merged into this branch: same files, contains the base, tested by a pull_request run
# one line per merged PR: number, head, base - the base is compared here, so any branch name works
prs="$(api "repos/$GH_REPO/commits/$SHA/pulls" '.[] | select(.merged_at != null) | "\(.number) \(.head.sha) \(.base.ref)"')" || gh_error
heads=""
while read -r number head ref; do
  [ -n "${number:-}" ] && [ "$ref" = "$REF_NAME" ] && heads+="$number $head"$'\n'
done <<< "$prs"
[ -n "$heads" ] || run_tests "no pull request merged into $REF_NAME for ${SHA:0:12}"
commit="$(api "repos/$GH_REPO/git/commits/$SHA" '"\(.tree.sha) \(.parents[0].sha // "")"')" || gh_error
read -r tree parent <<< "$commit"
[[ "${tree:-}" =~ ^[0-9a-f]{40}$ ]] || run_tests "no tree" "GitHub gave no tree for ${SHA:0:12}"
# the branch before this push (event.before); a new branch has zeros there - then the first parent
base="${BEFORE:-}"
[[ "$base" =~ ^[0-9a-f]{40}$ && "$base" != 0000000000000000000000000000000000000000 ]] || base="${parent:-}"
[[ "$base" =~ ^[0-9a-f]{40}$ ]] || run_tests "no base commit for ${SHA:0:12}"

while read -r number head; do
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
  head_tree="$(api "repos/$GH_REPO/git/commits/$head" .tree.sha)" || gh_error
  if [ "$head_tree" != "$tree" ]; then
    echo "PR #$number: its head ${head:0:12} has other files than ${SHA:0:12} (it was behind its base)"
    continue
  fi
  status="$(api "repos/$GH_REPO/compare/$base...$head?per_page=1" .status)" || gh_error
  case "$status" in
    ahead|identical) ;;
    *) echo "PR #$number: its head ${head:0:12} does not contain ${base:0:12} ($status) - it was tested against another base"
       continue ;;
  esac
  found="$(passed "$head" pull_request)" || gh_error
  [ -z "$found" ] || skip "the same files passed this workflow in PR #$number ($found)"
  echo "PR #$number: no successful pull_request run of $workflow for its head ${head:0:12}"
done <<< "${heads%$'\n'}"

run_tests "no successful run of $workflow for these files"
