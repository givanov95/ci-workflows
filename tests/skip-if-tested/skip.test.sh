#!/usr/bin/env bash
#
# Checks .github/actions/skip-if-tested/skip.sh, the step of the skip-if-tested action.
# `gh` is stubbed, so nothing here touches the network or GitHub.
#
#   tests/skip-if-tested/skip.test.sh
#
# Needs bash and jq.
#
# gh stub: `gh api <path> --jq F` answers $STUB/<path with / -> _>.json through jq;
# <...>.fail = exit 1 with that stderr; a missing file = HTTP 404.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root="$here/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

script="$root/.github/actions/skip-if-tested/skip.sh"

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB/calls"
[ "$1" = api ] || { echo "unexpected gh call: $*" >&2; exit 99; }
shift; path=; filter=.
while [ $# -gt 0 ]; do
    case "$1" in
        --jq) filter=$2; shift 2 ;;
        -*) echo "unexpected flag $1" >&2; exit 99 ;;
        *) path=$1; shift ;;
    esac
done
key="$STUB/${path//\//_}"
[ -f "$key.fail" ] && { cat "$key.fail" >&2; exit 1; }
[ -f "$key.json" ] || { echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -r "$filter" "$key.json"
STUB
chmod +x "$work/bin/gh"

R=acme/app
P=repos_acme_app
WF=ci.yml
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the pushed commit
H=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # head of its merged PR
T=1111111111111111111111111111111111111111   # tree of A
U=2222222222222222222222222222222222222222   # another tree
RUN=900                                      # this run

passed=0
failed=0
n=0
stub=
new_case() { n=$((n+1)); name=$1; stub="$work/case$n"; mkdir -p "$stub"; : > "$stub/calls"; errors=(); }
file() { printf '%s' "$2" > "$stub/$1"; }                         # file <name> <content>
runs() { file "${P}_actions_workflows_${WF}_runs?head_sha=$1&status=success&per_page=10.json" "{\"workflow_runs\":$2}"; }
run() { printf '{"id":%s,"event":"%s","html_url":"https://github.com/acme/app/actions/runs/%s"}' "$1" "$2" "$1"; }
tree() { file "${P}_git_commits_$1.json" "{\"sha\":\"$1\",\"tree\":{\"sha\":\"$2\"}}"; }
pulls() { file "${P}_commits_${A}_pulls.json" "$1"; }
pr() { printf '{"number":%s,"merged_at":%s,"head":{"sha":"%s"}}' "$1" "$2" "$3"; }

# step [VAR=value ...] - runs the script as the action does; rc, log and outputs are kept
step() {
    : > "$stub/output"
    env -i PATH="$work/bin:$PATH" STUB="$stub" RUNNER_TEMP="$work" GITHUB_OUTPUT="$stub/output" \
        GH_TOKEN=x GH_REPO="$R" EVENT=push SHA="$A" RUN_ID="$RUN" \
        WORKFLOW_REF="$R/.github/workflows/$WF@refs/heads/main" \
        "$@" bash "$script" > "$stub/log" 2>&1
    rc=$?
}
want() { # want <description> <test> [args]
    local d=$1; shift
    "$@" || errors+=("$d")
}
rc_is() { [ "$rc" = "$1" ]; }
log_has() { grep -qF -- "$1" "$stub/log"; }
output_is() { grep -qxF -- "$1" "$stub/output"; }
one_skip() { [ "$(grep -c '^skip=' "$stub/output")" = 1 ]; }
called() { grep -qF -- "$1" "$stub/calls"; }
not_called() { ! called "$1"; }
done_case() {
    if grep -q 'integer expression\|parse error\|unbound variable\|command not found\|syntax error' "$stub/log"; then errors+=("shell/jq error in the log"); fi
    one_skip || errors+=("exactly one skip= output")
    if [ ${#errors[@]} -eq 0 ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $name — ${errors[*]} (exit $rc)"
        sed 's/^/    | /' "$stub/log"
        sed 's/^/    out| /' "$stub/output"
        sed 's/^/    calls| /' "$stub/calls"
    fi
}

# ── events ───────────────────────────────────────────────────────────────────────────────────
for event in pull_request workflow_dispatch schedule merge_group; do
    new_case "$event -> tests run, no GitHub call"
    step EVENT="$event"
    want 'exit 0' rc_is 0
    want 'skip=false' output_is 'skip=false'
    want 'the reason' log_has "not a push ($event)"
    want 'no GitHub call' not_called 'gh '
    done_case
done

# ── a) the same commit ───────────────────────────────────────────────────────────────────────
new_case 'the same commit passed this workflow (fast-forward) -> skip'
runs "$A" "[$(run 501 push)]"
step
want 'exit 0' rc_is 0
want 'skip=true' output_is 'skip=true'
want 'names the run' log_has 'actions/runs/501'
want 'a notice' log_has '::notice'
want 'stops there' not_called "git/commits/$A"
done_case

new_case 'only this run itself for the commit -> not a match, goes on to the PR'
runs "$A" "[$(run "$RUN" push)]"; tree "$A" "$T"; pulls '[]'
step
want 'skip=false' output_is 'skip=false'
want 'looked for the PR' called "commits/$A/pulls"
done_case

new_case 'the workflow is read from WORKFLOW_REF (a reusable caller, .yaml)'
WF=deploy.yaml
runs "$A" "[$(run 502 push)]"
step WORKFLOW_REF="$R/.github/workflows/deploy.yaml@refs/heads/staging"
want 'skip=true' output_is 'skip=true'
want 'asked for deploy.yaml runs' called 'actions/workflows/deploy.yaml/runs'
done_case
WF=ci.yml

# ── b) the merged PR ─────────────────────────────────────────────────────────────────────────
new_case 'merged PR with the same files passed -> skip'
runs "$A" '[]'; tree "$A" "$T"; tree "$H" "$T"
pulls "[$(pr 12 '"2026-11-05T10:00:00Z"' "$H")]"
runs "$H" "[$(run 410 pull_request)]"
step
want 'exit 0' rc_is 0
want 'skip=true' output_is 'skip=true'
want 'names the PR' log_has 'PR #12'
want 'names the run' log_has 'actions/runs/410'
done_case

new_case 'merged PR that was behind its base (other files) -> tests run'
runs "$A" '[]'; tree "$A" "$T"; tree "$H" "$U"
pulls "[$(pr 13 '"2026-11-05T10:00:00Z"' "$H")]"
runs "$H" "[$(run 411 pull_request)]"
step
want 'skip=false' output_is 'skip=false'
want 'says why' log_has 'it was behind its base'
want 'no runs asked for the PR head' not_called "head_sha=$H"
done_case

new_case 'merged PR with the same files but no successful run -> tests run'
runs "$A" '[]'; tree "$A" "$T"; tree "$H" "$T"
pulls "[$(pr 14 '"2026-11-05T10:00:00Z"' "$H")]"
runs "$H" '[]'
step
want 'skip=false' output_is 'skip=false'
want 'says so' log_has 'no successful run'
done_case

new_case 'an open (not merged) PR of the commit does not count'
runs "$A" '[]'; tree "$A" "$T"; tree "$H" "$T"
pulls "[$(pr 15 null "$H")]"
runs "$H" "[$(run 412 pull_request)]"
step
want 'skip=false' output_is 'skip=false'
want 'no merged PR' log_has 'no merged pull request'
done_case

new_case 'a direct push without a PR -> tests run'
runs "$A" '[]'; tree "$A" "$T"; pulls '[]'
step
want 'exit 0' rc_is 0
want 'skip=false' output_is 'skip=false'
done_case

new_case 'two merged PRs: the second one matches -> skip'
C=cccccccccccccccccccccccccccccccccccccccc
runs "$A" '[]'; tree "$A" "$T"; tree "$C" "$U"; tree "$H" "$T"
pulls "[$(pr 16 '"2026-11-04T10:00:00Z"' "$C"),$(pr 17 '"2026-11-05T10:00:00Z"' "$H")]"
runs "$H" "[$(run 413 pull_request)]"
step
want 'skip=true' output_is 'skip=true'
want 'names PR 17' log_has 'PR #17'
done_case

# ── never skip on doubt ──────────────────────────────────────────────────────────────────────
new_case 'runs cannot be read (no actions: read) -> warning, tests run'
file "${P}_actions_workflows_${WF}_runs?head_sha=$A&status=success&per_page=10.fail" 'gh: Resource not accessible by integration (HTTP 403)'
step
want 'exit 0' rc_is 0
want 'skip=false' output_is 'skip=false'
want 'a warning with the reason' log_has 'Resource not accessible'
want 'stops there' not_called "git/commits/$A"
done_case

new_case 'the PRs cannot be read (no pull-requests: read) -> warning, tests run'
runs "$A" '[]'; tree "$A" "$T"
file "${P}_commits_${A}_pulls.fail" 'gh: Resource not accessible by integration (HTTP 403)'
step
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has '::warning'
done_case

new_case 'the PR head tree cannot be read -> warning, tests run (no skip after it)'
runs "$A" '[]'; tree "$A" "$T"
pulls "[$(pr 18 '"2026-11-05T10:00:00Z"' "$H")]"
step
want 'skip=false' output_is 'skip=false'
want 'names the failing call' log_has "git/commits/$H"
done_case

new_case 'the runs of the PR head cannot be read -> warning, tests run'
runs "$A" '[]'; tree "$A" "$T"; tree "$H" "$T"
pulls "[$(pr 19 '"2026-11-05T10:00:00Z"' "$H")]"
file "${P}_actions_workflows_${WF}_runs?head_sha=$H&status=success&per_page=10.fail" 'gh: Server Error (HTTP 500)'
step
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has 'Server Error'
done_case

new_case 'no full SHA -> warning, tests run'
step SHA=abc
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has '::warning'
want 'no GitHub call' not_called 'gh '
done_case

new_case 'no workflow in WORKFLOW_REF -> warning, tests run'
step WORKFLOW_REF=
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has 'cannot read the workflow file'
done_case

new_case 'no run id -> warning, tests run'
step RUN_ID=
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has 'RUN_ID'
done_case

echo "skip.test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
