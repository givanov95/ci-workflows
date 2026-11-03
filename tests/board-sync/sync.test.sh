#!/usr/bin/env bash
#
# Checks .github/actions/board-sync/sync.sh, the board-sync script of both the composite action and
# .github/workflows/board-sync.yml (which runs that action), in event mode and in add mode (ISSUE).
# `gh` and `sleep` are stubbed, so nothing here touches GitHub.
#
#   tests/board-sync/sync.test.sh
#
# Needs bash and jq.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root="$here/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

script="$root/.github/actions/board-sync/sync.sh"

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Every call is logged to $CALLS with the token it used; a moved card is logged as "moved <N>", a
# priority that was set as "priority <N> <option id>".
echo "[token=$GH_TOKEN] gh $*" >> "$CALLS"
[ "$1" = api ] || { echo "unexpected gh call: $*" >&2; exit 2; }
path=$2; shift 2
filter=.; content=; item=; field=; option=
while [ $# -gt 0 ]; do
    case "$1" in
        --jq) filter=$2; shift ;;
        -f|-F) case "$2" in c=*) content=${2#c=} ;; i=*) item=${2#i=} ;; f=*) field=${2#f=} ;; o=*) option=${2#o=} ;; query=*) query=${2#query=} ;; esac; shift ;;
    esac
    shift
done
answer() { jq -r "$filter" "$1"; }
# FIXTURE_ADD_STATUS: status of the card the add returns ("-" = none: a card just added);
# FIXTURE_LATER_STATUS: its status when read again; FIXTURE_CUR_PRIORITY: its priority
case "$path" in
    graphql)
        case "$query" in
            *updateProjectV2ItemFieldValue*)
                if [ "$field" = PF ]; then echo "priority ${item#ITEM_NODE_} $option" >> "$CALLS"; else echo "moved ${item#ITEM_NODE_}" >> "$CALLS"; fi
                echo '{}' ;;
            *addProjectV2ItemById*)
                [ -z "${FIXTURE_ADD_FAIL:-}" ] || { echo "gh: Could not resolve to a node with the global id of '$content'" >&2; exit 1; }
                jq -n --arg id "ITEM_$content" --arg s "${FIXTURE_ADD_STATUS:-In progress}" \
                    '{data: {addProjectV2ItemById: {item: {id: $id, status: (if $s == "-" then null else {name: $s} end)}}}}' ;;
            *'node(id:'*Priority*)
                jq -n --arg p "${FIXTURE_CUR_PRIORITY:-}" '{data: {node: {priority: (if $p == "" then null else {name: $p} end)}}}' ;;
            *'node(id:'*)
                jq -n --arg s "${FIXTURE_LATER_STATUS:-}" '{data: {node: {status: (if $s == "" then null else {name: $s} end)}}}' ;;
            *Priority*)
                jq -n '{data: {repositoryOwner: {projectV2: {field: {id: "PF", options: [
                    {id: "p0", name: "🔥 P0"}, {id: "p1", name: "P1"}, {id: "p2", name: "P2"}]}}}}}' ;;
            *projectV2*)
                [ -z "${FIXTURE_NO_BOARD:-}" ] || { echo '{"data": {"repositoryOwner": {"projectV2": null}}}'; exit 0; }
                jq -n '{data: {repositoryOwner: {projectV2: {id: "P", field: {id: "F", options: [
                    {id: "o1", name: "🆕 New"}, {id: "o6", name: "📋 Ready"}, {id: "o2", name: "🏗 In progress"},
                    {id: "o3", name: "👀 In review"}, {id: "o4", name: "Ready to ship"}, {id: "o5", name: "✅ Done"}]}}}}}' ;;
            *) echo "unexpected query: $query" >&2; exit 2 ;;
        esac ;;
    repos/*/issues/*)
        # FIXTURE_PR_NUMBERS: numbers that are pull requests, not issues
        jq -n --arg n "${path##*/}" --arg prs " ${FIXTURE_PR_NUMBERS:-} " \
            '{node_id: ("NODE_" + $n)} + (if ($prs | contains(" \($n) ")) then {pull_request: {}} else {} end)' > "$CALLS.issue"
        answer "$CALLS.issue" ;;
    repos/*/pulls/*/commits*) answer "$FIXTURE_PR_COMMITS" ;;
    repos/*/compare/*) [ -n "${FIXTURE_COMPARE:-}" ] || exit 1; answer "$FIXTURE_COMPARE" ;;
    repos/*/commits/*) answer "$FIXTURE_COMMIT" ;;
    *) echo "unexpected gh api $path" >&2; exit 2 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$CALLS"\n' > "$work/bin/sleep"
chmod +x "$work/bin/gh" "$work/bin/sleep"

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
#   VAR=value overrides the environment of the step; NO_GH=1 also asserts `gh` was never called,
#   NOTICE=<text> that this text was printed, CALLED=<text> / NOT_CALLED=<text> that the call log
#   has / has not this text. Every GraphQL call must use the board token.
expect() {
    local name=$1 want_rc=$2 want_moved=$3 rc moved notice errors=()
    shift 3
    : > "$work/calls"
    env -i PATH="$work/bin:$PATH" CALLS="$work/calls" GITHUB_EVENT_PATH="$human_pr" \
        GH_TOKEN=x PROJECT_TOKEN=board-token APP_CLIENT_ID= HAS_APP_KEY=false ACTOR=givanov95 PR_AUTHOR= \
        EVENT_NAME=push REPO=o/r REPO_OWNER=o REF_NAME=main SHA=abc BEFORE=def \
        PR_NUMBER= PR_ACTION= PR_BASE= PR_MERGED= PR_DRAFT= PROJECT_NUMBER=1 PROJECT_OWNER= STAGING_ENV=false \
        ISSUE= COLUMN= PRIORITY= \
        FIXTURE_COMPARE="$work/compare-mixed.json" FIXTURE_COMMIT="$work/human.json" \
        FIXTURE_PR_COMMITS="$work/no-commits.json" NO_GH= NOTICE= CALLED= NOT_CALLED= \
        "$@" bash "$script" > "$work/log" 2>&1
    rc=$?
    moved=$(sed -n 's/^moved //p' "$work/calls" | sort -n | tr '\n' ' ' | sed 's/ $//')
    [ "$rc" = "$want_rc" ] || errors+=("exit $rc, expected $want_rc")
    [ "${moved:--}" = "$want_moved" ] || errors+=("moved '${moved:--}', expected '$want_moved'")
    if env "$@" bash -c '[ -n "${NO_GH:-}" ]' && [ -s "$work/calls" ]; then errors+=("gh was called"); fi
    if grep -q 'integer expression\|parse error' "$work/log"; then errors+=("shell/jq error in the log"); fi
    notice=$(env "$@" bash -c 'printf %s "${NOTICE:-}"')
    if [ -n "$notice" ] && ! grep -qF "$notice" "$work/log"; then errors+=("no notice '$notice'"); fi
    called=$(env "$@" bash -c 'printf %s "${CALLED:-}"')
    if [ -n "$called" ] && ! grep -qF -- "$called" "$work/calls"; then errors+=("no call '$called'"); fi
    called=$(env "$@" bash -c 'printf %s "${NOT_CALLED:-}"')
    if [ -n "$called" ] && grep -qF -- "$called" "$work/calls"; then errors+=("called '$called'"); fi
    if grep 'api graphql' "$work/calls" | grep -qv 'token=board-token'; then errors+=("GraphQL without the board token"); fi

    if [ ${#errors[@]} -eq 0 ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $name — ${errors[*]}"
        sed 's/^/    | /' "$work/log"
        sed 's/^/    gh| /' "$work/calls"
    fi
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

# ── add mode: put one issue on the board (the event does not matter) ─────────────────────────
app=(EVENT_NAME=schedule APP_CLIENT_ID=Iv00 HAS_APP_KEY=true ISSUE=12)
expect 'add: a card already on the board stays put'      0 - "${app[@]}" \
    CALLED='-f c=NODE_12' NOT_CALLED=sleep NOTICE='issue #12 is on the board o #1'
expect 'add: a new card, no column -> left to the board' 0 - "${app[@]}" FIXTURE_ADD_STATUS=- \
    CALLED=addProjectV2ItemById NOT_CALLED=sleep
expect 'add: issue node id with github-token'            0 - "${app[@]}" CALLED='gh api repos/o/r/issues/12 --jq'
expect 'add: column Ready on a new card'                 0 12 "${app[@]}" COLUMN='📋 Ready' FIXTURE_ADD_STATUS=- \
    FIXTURE_LATER_STATUS='🆕 New' CALLED='sleep 8'
expect 'add: column New, card in progress -> forward only' 0 - "${app[@]}" COLUMN=new NOTICE="stays in 'In progress'"
expect 'add: a column outside the flow'                  1 - "${app[@]}" COLUMN=Blocked NO_GH=1 NOTICE='is not a column of the flow'
expect 'add: priority on a card without one'             0 - "${app[@]}" PRIORITY=P2 CALLED='priority 12 p2'
expect 'add: priority by name, emoji ignored'            0 - "${app[@]}" PRIORITY=p0 CALLED='priority 12 p0'
expect 'add: a card with a priority keeps it'            0 - "${app[@]}" PRIORITY=P2 FIXTURE_CUR_PRIORITY=P1 \
    NOT_CALLED='priority 12' NOTICE="keeps its priority 'P1'"
expect 'add: column and priority on a new card'          0 12 "${app[@]}" PRIORITY=P1 COLUMN=Ready FIXTURE_ADD_STATUS=- \
    FIXTURE_LATER_STATUS=New CALLED='priority 12 p1'
expect 'add: an unknown priority fails before the add'   1 - "${app[@]}" PRIORITY=P9 NOT_CALLED=addProjectV2ItemById \
    NOTICE="No priority 'P9'"
expect 'add: no token -> add it by hand'                 0 - "${app[@]}" APP_CLIENT_ID= PROJECT_TOKEN= NO_GH=1 NOTICE='board.sh add 12'
expect 'add: App id without key -> add it by hand'       0 - "${app[@]}" HAS_APP_KEY=false PROJECT_TOKEN= NO_GH=1 NOTICE='board.sh add 12'
expect 'add: App, repo of another owner -> by hand'      0 - "${app[@]}" PROJECT_OWNER=gwebsolutions-dev NO_GH=1 \
    NOTICE='cannot see its issues'
expect 'add: App, owner in another letter case'          0 - "${app[@]}" PROJECT_OWNER=O CALLED=addProjectV2ItemById
expect 'add: PAT, repo of another owner -> tries'        0 - "${app[@]}" APP_CLIENT_ID= HAS_APP_KEY=false \
    PROJECT_OWNER=gwebsolutions-dev CALLED='-f o=gwebsolutions-dev'
expect 'add: a pull request number fails'                1 - "${app[@]}" FIXTURE_PR_NUMBERS=12 NOT_CALLED=addProjectV2ItemById \
    NOTICE='#12 is not an issue of o/r'
expect 'add: the board is not found'                     1 - "${app[@]}" FIXTURE_NO_BOARD=1 NOT_CALLED=addProjectV2ItemById
expect 'add: the add fails'                              1 - "${app[@]}" FIXTURE_ADD_FAIL=1 NOTICE='Could not add the card of #12'
expect 'add: not a number'                               1 - "${app[@]}" ISSUE='12; x' NO_GH=1
expect 'add: Dependabot run'                             0 - "${app[@]}" ACTOR='dependabot[bot]' NO_GH=1 NOTICE='Dependabot run'
expect 'add: a PR event does not move PR references'     0 - "${app[@]}" EVENT_NAME=pull_request PR_ACTION=opened PR_DRAFT=false \
    PR_BASE=main NOT_CALLED='pulls/'

echo "sync.test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
