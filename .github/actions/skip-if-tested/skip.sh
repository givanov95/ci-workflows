#!/usr/bin/env bash
# Skip if tested (see action.yml): has this exact code already passed this workflow?
#
#   skip.sh   EVENT, SHA, WORKFLOW_REF, RUN_ID -> outputs skip (true | false), reason
#
# Only a push is checked (any other event: skip=false). The code counts as tested when a successful
# run of the SAME workflow file exists for:
#   a) the same commit - e.g. a fast-forward staging -> main pushes a commit staging already tested;
#   b) the head of the merged pull request of this commit, when that head has the same tree (the
#      same files) as this commit - a squash or merge of a PR that was up to date with its base.
#      A PR that was behind its base gives the base branch a tree it never tested, so it runs.
# The same tree also means the same workflow file, so the earlier run checked what this one would.
#
# Always exits 0 and never skips on doubt: a GitHub error, a missing permission or an unexpected
# answer is a warning and skip=false, so the tests run as they would without this action.
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
  gh api "$1" --jq "$2" </dev/null 2>"$tmp/gh.err" || { printf '%s' "$1" > "$tmp/gh.path"; return 1; }
}
gh_error() {
  run_tests "GitHub error" "GitHub error on $(cat "$tmp/gh.path" 2>/dev/null): $(head -c 300 "$tmp/gh.err" 2>/dev/null | tr '\n' ' ')"
}

[ "${EVENT:-}" = push ] || run_tests "not a push (${EVENT:-no event})"
[ -n "${GH_REPO:-}" ] || run_tests "no repository" "GH_REPO is not set"
[[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] || run_tests "no commit" "SHA must be a full commit SHA, not '${SHA:-}'"
[[ "${RUN_ID:-}" =~ ^[0-9]+$ ]] || run_tests "no run id" "RUN_ID must be a number, not '${RUN_ID:-}'"
# github.workflow_ref: owner/repo/.github/workflows/ci.yml@refs/heads/main
workflow="${WORKFLOW_REF:-}"; workflow="${workflow%%@*}"; workflow="${workflow##*/}"
[[ "$workflow" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || run_tests "no workflow" "cannot read the workflow file from WORKFLOW_REF '${WORKFLOW_REF:-}'"

runs="repos/$GH_REPO/actions/workflows/$workflow/runs"
# passed <sha>: "<event> run <url>" of a successful run of this workflow for <sha> other than this one
passed() {
  api "$runs?head_sha=$1&status=success&per_page=10" \
    "[.workflow_runs[] | select(.id != $RUN_ID)] | first | select(. != null) | \"\(.event) run \(.html_url)\""
}

# a) the same commit
found="$(passed "$SHA")" || gh_error
[ -z "$found" ] || skip "commit ${SHA:0:12} already passed this workflow ($found)"

# b) the head of the merged PR, with the same files
tree="$(api "repos/$GH_REPO/git/commits/$SHA" .tree.sha)" || gh_error
[[ "$tree" =~ ^[0-9a-f]{40}$ ]] || run_tests "no tree" "GitHub gave no tree for ${SHA:0:12}"
heads="$(api "repos/$GH_REPO/commits/$SHA/pulls" '.[] | select(.merged_at != null) | "\(.number) \(.head.sha)"')" || gh_error
[ -n "$heads" ] || run_tests "no merged pull request for ${SHA:0:12}"

while read -r number head; do
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
  head_tree="$(api "repos/$GH_REPO/git/commits/$head" .tree.sha)" || gh_error
  if [ "$head_tree" != "$tree" ]; then
    echo "PR #$number: its head ${head:0:12} has other files than ${SHA:0:12} (it was behind its base)"
    continue
  fi
  found="$(passed "$head")" || gh_error
  [ -z "$found" ] || skip "the same files passed this workflow in PR #$number ($found)"
  echo "PR #$number: no successful run of $workflow for its head ${head:0:12}"
done <<< "$heads"

run_tests "no successful run of $workflow for these files"
