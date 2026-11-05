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
M=9999999999999999999999999999999999999999   # the branch before the push (event.before), A's first parent
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
runs_key() { echo "${P}_actions_workflows_${WF}_runs?head_sha=$1&event=$2&status=success&per_page=20"; }
runs() { file "$(runs_key "$1" "$2").json" "{\"workflow_runs\":$3}"; }   # runs <sha> <event> <json array>
# run <id> <event> [repo] [actor]
run() { printf '{"id":%s,"event":"%s","html_url":"https://github.com/acme/app/actions/runs/%s","head_repository":{"full_name":"%s"},"actor":{"login":"%s"}}' "$1" "$2" "$1" "${3:-$R}" "${4:-someone}"; }
commit() { file "${P}_git_commits_$1.json" "{\"sha\":\"$1\",\"tree\":{\"sha\":\"$2\"},\"parents\":[${3:+{\"sha\":\"$3\"\}}]}"; }  # commit <sha> <tree> [parent]
compare() { file "${P}_compare_$1...$2?per_page=1.json" "{\"status\":\"$3\"}"; }
pulls() { file "${P}_commits_${A}_pulls.json" "$1"; }
pr() { printf '{"number":%s,"merged_at":%s,"head":{"sha":"%s"},"base":{"ref":"%s"}}' "$1" "$2" "$3" "${4:-main}"; }  # pr <n> <merged_at> <head> [base]
MERGED='"2026-11-05T10:00:00Z"'
# a PR #12 of A: head H with A's files, containing M, nothing for A itself
pr_setup() { runs "$A" push '[]'; commit "$A" "$T" "$M"; commit "$H" "$T"; compare "$M" "$H" ahead; pulls "[$(pr 12 "$MERGED" "$H")]"; }

# step [VAR=value ...] - runs the script as the action does; rc, log and outputs are kept
step() {
    : > "$stub/output"
    env -i PATH="$work/bin:$PATH" STUB="$stub" RUNNER_TEMP="$work" GITHUB_OUTPUT="$stub/output" \
        GH_TOKEN=x GH_REPO="$R" EVENT=push SHA="$A" RUN_ID="$RUN" REF_NAME=main BEFORE="$M" \
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
new_case 'the same commit passed a push run (fast-forward) -> skip'
runs "$A" push "[$(run 501 push)]"
step
want 'exit 0' rc_is 0
want 'skip=true' output_is 'skip=true'
want 'names the run' log_has 'actions/runs/501'
want 'a notice' log_has '::notice'
want 'stops there' not_called "commits/$A/pulls"
want 'asks for push runs only' called "head_sha=$A&event=push&status=success"
done_case

new_case 'only this run itself for the commit -> not a match, goes on to the PR'
runs "$A" push "[$(run "$RUN" push)]"; pulls '[]'
step
want 'skip=false' output_is 'skip=false'
want 'looked for the PR' called "commits/$A/pulls"
done_case

new_case 'a push run of the commit from Dependabot does not count'
runs "$A" push "[$(run 503 push "$R" 'dependabot[bot]')]"; pulls '[]'
step
want 'skip=false' output_is 'skip=false'
done_case

new_case 'the workflow is read from WORKFLOW_REF (.yaml, another branch)'
WF=deploy.yaml
runs "$A" push "[$(run 502 push)]"
step WORKFLOW_REF="$R/.github/workflows/deploy.yaml@refs/heads/staging"
want 'skip=true' output_is 'skip=true'
want 'asked for deploy.yaml runs' called 'actions/workflows/deploy.yaml/runs'
done_case
WF=ci.yml

# ── b) the merged PR ─────────────────────────────────────────────────────────────────────────
new_case 'merged PR, same files, contains the base, passed -> skip'
pr_setup; runs "$H" pull_request "[$(run 410 pull_request)]"
step
want 'exit 0' rc_is 0
want 'skip=true' output_is 'skip=true'
want 'names the PR' log_has 'PR #12'
want 'names the run' log_has 'actions/runs/410'
want 'asks for pull_request runs' called "head_sha=$H&event=pull_request&status=success"
done_case

new_case 'merged PR whose head is the base itself (identical) -> skip'
pr_setup; compare "$M" "$H" identical; runs "$H" pull_request "[$(run 420 pull_request)]"
step
want 'skip=true' output_is 'skip=true'
done_case

new_case 'merged PR that was behind its base (other files) -> tests run'
pr_setup; commit "$H" "$U"; runs "$H" pull_request "[$(run 411 pull_request)]"
step
want 'skip=false' output_is 'skip=false'
want 'says why' log_has 'it was behind its base'
want 'no runs asked for the PR head' not_called "head_sha=$H"
done_case

new_case 'same files but the head does not contain the base (tested against another base) -> tests run'
pr_setup; compare "$M" "$H" diverged; runs "$H" pull_request "[$(run 412 pull_request)]"
step
want 'skip=false' output_is 'skip=false'
want 'says why' log_has 'tested against another base'
want 'no runs asked for the PR head' not_called "head_sha=$H"
done_case

new_case 'merged PR with the same files but no successful run -> tests run'
pr_setup; runs "$H" pull_request '[]'
step
want 'skip=false' output_is 'skip=false'
want 'says so' log_has 'no successful pull_request run'
done_case

new_case 'a Dependabot PR run does not count'
pr_setup; runs "$H" pull_request "[$(run 413 pull_request "$R" 'dependabot[bot]')]"
step
want 'skip=false' output_is 'skip=false'
done_case

new_case 'a fork PR run does not count'
pr_setup; runs "$H" pull_request "[$(run 414 pull_request someone/app)]"
step
want 'skip=false' output_is 'skip=false'
done_case

new_case 'a dispatch run in the pull_request answer does not count'
pr_setup; runs "$H" pull_request "[$(run 415 workflow_dispatch)]"
step
want 'skip=false' output_is 'skip=false'
done_case

new_case 'an open (not merged) PR of the commit does not count'
pr_setup; pulls "[$(pr 15 null "$H")]"; runs "$H" pull_request "[$(run 416 pull_request)]"
step
want 'skip=false' output_is 'skip=false'
want 'no merged PR' log_has 'no pull request merged into main'
want 'no extra call for the tree' not_called "git/commits/$A"
done_case

new_case 'a direct push without a PR -> tests run, no tree asked for'
runs "$A" push '[]'; pulls '[]'
step
want 'exit 0' rc_is 0
want 'skip=false' output_is 'skip=false'
want 'no tree call' not_called "git/commits/$A"
done_case

new_case 'two merged PRs: the second one matches -> skip'
C=cccccccccccccccccccccccccccccccccccccccc
pr_setup; commit "$C" "$U"
pulls "[$(pr 16 "$MERGED" "$C"),$(pr 17 "$MERGED" "$H")]"
runs "$H" pull_request "[$(run 417 pull_request)]"
step
want 'skip=true' output_is 'skip=true'
want 'names PR 17' log_has 'PR #17'
done_case

# ── never skip on doubt ──────────────────────────────────────────────────────────────────────
new_case 'runs cannot be read (no actions: read) -> warning, tests run'
file "$(runs_key "$A" push).fail" 'gh: Resource not accessible by integration (HTTP 403)'
step
want 'exit 0' rc_is 0
want 'skip=false' output_is 'skip=false'
want 'a warning with the reason' log_has 'Resource not accessible'
want 'stops there' not_called "commits/$A/pulls"
done_case

new_case 'the PRs cannot be read (no pull-requests: read) -> warning, tests run'
runs "$A" push '[]'
file "${P}_commits_${A}_pulls.fail" 'gh: Resource not accessible by integration (HTTP 403)'
step
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has '::warning'
done_case

new_case 'the PR head tree cannot be read -> warning, tests run (no skip after it)'
pr_setup; rm "$stub/${P}_git_commits_$H.json"; runs "$H" pull_request "[$(run 418 pull_request)]"
step
want 'skip=false' output_is 'skip=false'
want 'names the failing call' log_has "git/commits/$H"
done_case

new_case 'the comparison fails -> warning, tests run'
pr_setup; rm "$stub/${P}_compare_$M...$H?per_page=1.json"; runs "$H" pull_request "[$(run 419 pull_request)]"
step
want 'skip=false' output_is 'skip=false'
want 'names the failing call' log_has "compare/$M...$H"
done_case

new_case 'the runs of the PR head cannot be read -> warning, tests run'
pr_setup; file "$(runs_key "$H" pull_request).fail" 'gh: Server Error (HTTP 500)'
step
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has 'Server Error'
done_case

new_case 'a new branch (before = zeros) and a commit without a parent -> tests run'
pr_setup; commit "$A" "$T"; runs "$H" pull_request "[$(run 421 pull_request)]"
step BEFORE=0000000000000000000000000000000000000000
want 'skip=false' output_is 'skip=false'
want 'says so' log_has 'no base commit'
done_case

new_case 'a new branch (before = zeros) falls back to the first parent -> skip'
pr_setup; runs "$H" pull_request "[$(run 422 pull_request)]"
step BEFORE=0000000000000000000000000000000000000000
want 'skip=true' output_is 'skip=true'
want 'compared with the parent' called "compare/$M...$H"
done_case

new_case 'rebase merge: the first parent is a rewritten commit, before is in the head -> skip'
Q=7777777777777777777777777777777777777777
pr_setup; commit "$A" "$T" "$Q"; runs "$H" pull_request "[$(run 423 pull_request)]"
step
want 'skip=true' output_is 'skip=true'
want 'compared with before, not the parent' not_called "compare/$Q"
done_case

new_case 'a PR merged into another branch does not count (push to staging of a PR head to main)'
pr_setup; pulls "[$(pr 24 "$MERGED" "$H" main)]"; runs "$H" pull_request "[$(run 424 pull_request)]"
step REF_NAME=staging
want 'skip=false' output_is 'skip=false'
want 'says so' log_has 'no pull request merged into staging'
done_case

new_case 'a branch name with + and @ works (compared in the shell)'
pr_setup; pulls "[$(pr 25 "$MERGED" "$H" 'release+1@x')]"; runs "$H" pull_request "[$(run 425 pull_request)]"
step REF_NAME='release+1@x'
want 'skip=true' output_is 'skip=true'
done_case

new_case 'no branch name -> warning, tests run'
step REF_NAME=
want 'skip=false' output_is 'skip=false'
want 'a warning' log_has 'REF_NAME'
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

new_case 'a bad repository name -> warning, tests run'
step GH_REPO='acme/app" or true'
want 'skip=false' output_is 'skip=false'
want 'no GitHub call' not_called 'gh '
done_case

echo "skip.test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
