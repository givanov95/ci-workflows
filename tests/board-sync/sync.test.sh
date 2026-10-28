#!/usr/bin/env bash
#
# Checks the board-sync script: the "Work out the target column and move the cards" step of
# .github/workflows/board-sync.yml and its copy .github/actions/board-sync/sync.sh. Every case runs
# against both, so the two cannot drift apart. `gh` is stubbed, so nothing here touches GitHub.
#
#   tests/board-sync/sync.test.sh
#
# Needs bash, jq and python3 with PyYAML.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root="$here/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/board-sync.yml" > "$work/workflow.sh" <<'PY'
import sys
import yaml

steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["sync"]["steps"]
print(next(step for step in steps if step.get("name", "").startswith("Work out"))["run"])
PY
cp "$root/.github/actions/board-sync/sync.sh" "$work/action.sh"

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Every call is logged to $CALLS; a moved card is logged as "moved <N>".
echo "gh $*" >> "$CALLS"
[ "$1" = api ] || { echo "unexpected gh call: $*" >&2; exit 2; }
path=$2; shift 2
filter=.; content=; item=
while [ $# -gt 0 ]; do
    case "$1" in
        --jq) filter=$2; shift ;;
        -f|-F) case "$2" in c=*) content=${2#c=} ;; i=*) item=${2#i=} ;; query=*) query=${2#query=} ;; esac; shift ;;
    esac
    shift
done
answer() { jq -r "$filter" "$1"; }
case "$path" in
    graphql)
        case "$query" in
            *updateProjectV2ItemFieldValue*) echo "moved ${item#ITEM_NODE_}" >> "$CALLS"; echo '{}' ;;
            *addProjectV2ItemById*)
                jq -n --arg id "ITEM_$content" '{data: {addProjectV2ItemById: {item: {id: $id, status: {name: "In progress"}}}}}' ;;
            *projectV2*)
                jq -n '{data: {repositoryOwner: {projectV2: {id: "P", field: {id: "F", options: [
                    {id: "o1", name: "🆕 New"}, {id: "o2", name: "🏗 In progress"}, {id: "o3", name: "👀 In review"},
                    {id: "o4", name: "Ready to ship"}, {id: "o5", name: "✅ Done"}]}}}}}' ;;
            *) echo "unexpected query: $query" >&2; exit 2 ;;
        esac ;;
    repos/*/issues/*) jq -n --arg n "${path##*/}" '{node_id: ("NODE_" + $n)}' > "$CALLS.issue"; answer "$CALLS.issue" ;;
    repos/*/pulls/*/commits*) answer "$FIXTURE_PR_COMMITS" ;;
    repos/*/compare/*) [ -n "${FIXTURE_COMPARE:-}" ] || exit 1; answer "$FIXTURE_COMPARE" ;;
    repos/*/commits/*) answer "$FIXTURE_COMMIT" ;;
    *) echo "unexpected gh api $path" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/gh"

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────
human='{"author": {"login": "givanov95"}, "commit": {"author": {"name": "Georgi Ivanov"}, "message": "fix(x): a fix\n\nFixes #5"}}'
# the squash commit of a Dependabot PR: upstream release notes with their own "Fixes #N"
bot='{"author": {"login": "dependabot[bot]"}, "commit": {"author": {"name": "dependabot[bot]"}, "message": "chore(deps): bump x from 1.0.0 to 1.1.0 (#21)\n\nRelease notes\n- Fix a crash (fixes #7)\n- Closes #8"}}'
# a Dependabot commit whose email is not linked to an account (no .author)
bot_unlinked='{"author": null, "commit": {"author": {"name": "dependabot[bot]"}, "message": "Bumps y.\n\nResolves #9"}}'

echo "$human" > "$work/human.json"
echo "$bot" > "$work/bot.json"
jq -n --argjson h "$human" --argjson b "$bot" --argjson u "$bot_unlinked" '{commits: [$h, $b, $u]}' > "$work/compare-mixed.json"
jq -n --argjson b "$bot" --argjson u "$bot_unlinked" '{commits: [$b, $u]}' > "$work/compare-bot.json"
echo '[]' > "$work/no-commits.json"
echo '{"commits": null}' > "$work/compare-null.json"
echo '{"message": "Not Found"}' > "$work/not-found.json"
# the commits of a dev -> main release PR: a human fix and the squash commit of a Dependabot PR
jq -n --argjson b "$bot" '[{author: {login: "givanov95"}, commit: {author: {name: "Georgi Ivanov"}, message: "fix(y): another\n\nFixes #6"}}, $b]' > "$work/release-pr-commits.json"

pr_event() { # pr_event <title> <body> -> path of an event payload
    local file="$work/event.$RANDOM.json"
    jq -n --arg t "$1" --arg b "$2" '{pull_request: {title: $t, body: $b}}' > "$file"
    echo "$file"
}
human_pr=$(pr_event 'fix(x): a fix' 'Closes #5')
bot_pr=$(pr_event 'chore(deps): bump x' $'Release notes\n- fixes #7')

passed=0
failed=0

# expect <name> <exit code> <moved issues, space separated or "-"> [VAR=value ...]
#   VAR=value overrides the environment of the step; NO_GH=1 also asserts `gh` was never called and
#   NOTICE=<text> that this notice was printed.
expect() {
    local name=$1 want_rc=$2 want_moved=$3 script rc moved
    shift 3
    for script in workflow action; do
        : > "$work/calls"
        env -i PATH="$work/bin:$PATH" CALLS="$work/calls" GITHUB_EVENT_PATH="$human_pr" \
            GH_TOKEN=x PROJECT_TOKEN=board-token APP_CLIENT_ID= HAS_APP_KEY=false ACTOR=givanov95 PR_AUTHOR= \
            EVENT_NAME=push REPO=o/r REPO_OWNER=o REF_NAME=main SHA=abc BEFORE=def \
            PR_NUMBER= PR_ACTION= PR_BASE= PR_MERGED= PR_DRAFT= PROJECT_NUMBER=1 PROJECT_OWNER= STAGING_ENV=false \
            FIXTURE_COMPARE="$work/compare-mixed.json" FIXTURE_COMMIT="$work/human.json" \
            FIXTURE_PR_COMMITS="$work/no-commits.json" NO_GH= NOTICE= \
            "$@" bash -e "$work/$script.sh" > "$work/log" 2>&1
        rc=$?
        moved=$(sed -n 's/^moved //p' "$work/calls" | sort -n | tr '\n' ' ' | sed 's/ $//')
        local errors=()
        [ "$rc" = "$want_rc" ] || errors+=("exit $rc, expected $want_rc")
        [ "${moved:--}" = "$want_moved" ] || errors+=("moved '${moved:--}', expected '$want_moved'")
        if env "$@" bash -c '[ -n "${NO_GH:-}" ]' && [ -s "$work/calls" ]; then errors+=("gh was called"); fi
        if grep -q 'integer expression\|parse error' "$work/log"; then errors+=("shell/jq error in the log"); fi
        local notice
        notice=$(env "$@" bash -c 'printf %s "${NOTICE:-}"')
        if [ -n "$notice" ] && ! grep -qF "$notice" "$work/log"; then errors+=("no notice '$notice'"); fi

        if [ ${#errors[@]} -eq 0 ]; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            echo "FAIL [$script]: $name — ${errors[*]}"
            sed 's/^/    | /' "$work/log"
            sed 's/^/    gh| /' "$work/calls"
        fi
    done
}

# ── Dependabot runs: a green no-op, whatever the token setup ──────────────────────────────────
expect 'Dependabot PR opened, App id without key'   0 - EVENT_NAME=pull_request PR_ACTION=opened PR_DRAFT=false PR_BASE=main \
    ACTOR='dependabot[bot]' PR_AUTHOR='dependabot[bot]' APP_CLIENT_ID=Iv00 HAS_APP_KEY=false PROJECT_TOKEN= \
    GITHUB_EVENT_PATH="$bot_pr" NO_GH=1 NOTICE='Dependabot run'
expect 'Dependabot PR merged into dev by a human'   0 - EVENT_NAME=pull_request PR_ACTION=closed PR_MERGED=true PR_BASE=dev \
    ACTOR=givanov95 PR_AUTHOR='dependabot[bot]' APP_CLIENT_ID=Iv00 HAS_APP_KEY=true \
    GITHUB_EVENT_PATH="$bot_pr" NO_GH=1 NOTICE='Dependabot run'
expect 'actor is Dependabot'                        0 - ACTOR='dependabot[bot]' NO_GH=1 NOTICE='Dependabot run'

# ── push: Dependabot commits are ignored (the actor is the merger, never Dependabot) ─────────
expect 'push to main, human + Dependabot commits'   0 5 NOTICE='2 Dependabot commit(s) ignored'
expect 'push to main by github-actions[bot]'        0 5 ACTOR='github-actions[bot]'
expect 'push to main, only Dependabot commits'      0 - FIXTURE_COMPARE="$work/compare-bot.json" NOTICE='no Fixes/Closes/Resolves'
expect 'new branch, its only commit is Dependabot'  0 - BEFORE=0000000000000000000000000000000000000000 \
    FIXTURE_COMMIT="$work/bot.json" NOTICE='1 Dependabot commit(s) ignored'
expect 'new branch, a human commit'                 0 5 BEFORE=0000000000000000000000000000000000000000
expect 'compare fails, falls back to the commit'    0 - FIXTURE_COMPARE= FIXTURE_COMMIT="$work/bot.json"
expect 'compare fails, human commit'                0 5 FIXTURE_COMPARE=

expect 'compare returns no commit list'             0 - FIXTURE_COMPARE="$work/compare-null.json" NOTICE='no Fixes/Closes/Resolves'

# ── PR: Dependabot commits inside a human PR are ignored too ─────────────────────────────────
expect 'release PR dev -> main with a Dependabot commit' 0 '5 6' EVENT_NAME=pull_request PR_ACTION=opened PR_DRAFT=false PR_BASE=main \
    FIXTURE_PR_COMMITS="$work/release-pr-commits.json" NOTICE='1 Dependabot commit(s) ignored'
expect 'PR commits cannot be read'                  0 5 EVENT_NAME=pull_request PR_ACTION=opened PR_DRAFT=false PR_BASE=main \
    FIXTURE_PR_COMMITS="$work/not-found.json"

# ── unchanged behaviour ──────────────────────────────────────────────────────────────────────
expect 'human PR opened'                            0 5 EVENT_NAME=pull_request PR_ACTION=opened PR_DRAFT=false PR_BASE=main
expect 'human PR, App id without key fails'         1 - EVENT_NAME=pull_request PR_ACTION=opened PR_DRAFT=false PR_BASE=main \
    APP_CLIENT_ID=Iv00 HAS_APP_KEY=false NO_GH=1
expect 'no token is a green no-op'                  0 - PROJECT_TOKEN= NO_GH=1 NOTICE='No board token'

echo "sync.test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
