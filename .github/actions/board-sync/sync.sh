#!/usr/bin/env bash
# Board sync (see action.yml). The only copy of the logic: .github/workflows/board-sync.yml runs this action.
#
# Two modes:
#   event mode (ISSUE empty) - the issues a PR / push refers to (Fixes #N) move forward to the column
#                              of the event (In review, Ready to ship, Staging / QA, Done)
#   add mode   (ISSUE=<N>)   - issue N of this repository is put on the board (idempotent: a card
#                              that is already there stays where it is), optionally moved forward to
#                              COLUMN and given PRIORITY when it has none yet
set -euo pipefail
notice() { echo "::notice title=Board sync::$*"; }
ISSUE="${ISSUE:-}"
OWNER="${PROJECT_OWNER:-$REPO_OWNER}"

# Dependabot runs get only Dependabot secrets (no board key), and its PRs quote upstream release
# notes, whose "Fixes #N" point at issues of another repository.
if [ "${ACTOR:-}" = 'dependabot[bot]' ] || [ "${PR_AUTHOR:-}" = 'dependabot[bot]' ]; then
  notice "Dependabot run - skipping (no cards moved)."
  exit 0
fi

# Add mode is a side task of a job that has done its work (e.g. opened an issue), so a missing
# board key is a notice to add the card by hand, not a failure. An installation token of the App is
# minted for the board owner and cannot see an issue of another owner's repository (a personal repo
# on an organization board), so that, too, is left to a human.
if [ -n "$ISSUE" ]; then
  [[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || { echo "::error title=Board sync::issue must be an issue number, not '$ISSUE'."; exit 1; }
  BY_HAND="put issue #$ISSUE on the board $OWNER #$PROJECT_NUMBER by hand if it is not there (board.sh add $ISSUE)"
  if [ -n "${APP_CLIENT_ID:-}" ]; then
    if [ "$(printf '%s' "$REPO_OWNER" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')" ]; then
      notice "$REPO is not a repository of $OWNER, so the GitHub App cannot see its issues - $BY_HAND."; exit 0
    fi
    if [ "${HAS_APP_KEY:-}" != true ]; then notice "No GitHub App private key (BOARD_APP_KEY) - $BY_HAND."; exit 0; fi
  elif [ -z "${PROJECT_TOKEN:-}" ]; then
    notice "No board token - $BY_HAND."; exit 0
  fi
fi

if [ -n "${APP_CLIENT_ID:-}" ] && [ "${HAS_APP_KEY:-}" != true ]; then
  echo "::error title=Board sync::app-client-id is set but the GitHub App private key is missing (board-sync.yml: pass it with secrets: BOARD_APP_KEY; the action: app-private-key)."
  exit 1
fi

if [ -z "${PROJECT_TOKEN:-}" ]; then
  notice "No board token (neither a GitHub App via app-client-id + BOARD_APP_KEY nor PROJECT_TOKEN) - skipping (no cards moved)."
  exit 0
fi

# ---- 1. what happened -> target column + the text to search for issue refs ----
norm() { tr '[:upper:]' '[:lower:]' | sed -E 's/[^[:alnum:] ]+/ /g; s/ +/ /g; s/^ //; s/ $//'; }
rank() { # normalized column name -> flow rank (-1 = unknown)
  case "$1" in
    new) echo 0;; backlog) echo 1;; ready|planned) echo 2;; "in progress") echo 3;;
    "in review") echo 4;; "ready to ship"|"ready for testing") echo 5;;
    staging|"staging qa") echo 6;; done) echo 7;; *) echo -1;;
  esac
}
TEXT=""
# Commits by Dependabot (incl. the squash commit of its PR, also inside a later dev -> main PR or
# push) quote upstream release notes, so they are left out.
BOT='(.author.login // "") == "dependabot[bot]" or (.commit.author.name // "") == "dependabot[bot]"'
add_commits() { # $1: JSON array of commits -> their messages, without Dependabot's, appended to TEXT
  local commits="$1" skipped
  echo "$commits" | jq -e 'type == "array"' >/dev/null 2>&1 || commits='[]'
  skipped="$(echo "$commits" | jq "map(select($BOT)) | length")"
  [ "$skipped" -eq 0 ] || notice "$skipped Dependabot commit(s) ignored."
  TEXT="$TEXT"$'\n'"$(echo "$commits" | jq -r ".[] | select(($BOT) | not) | .commit.message")"
}
if [ -n "$ISSUE" ]; then # add mode: the issue asked for, the column / priority asked for
  ISSUES="$ISSUE"
  TARGET="$(printf '%s' "${COLUMN:-}" | norm)"
  if [ -n "$TARGET" ] && [ "$(rank "$TARGET")" -lt 0 ]; then
    echo "::error title=Board sync::column '${COLUMN:-}' is not a column of the flow (New, Backlog, Ready, In progress, In review, Ready to ship, Staging / QA, Done)."
    exit 1
  fi
  PRIORITY_NAME="$(printf '%s' "${PRIORITY:-}" | norm)"
else # event mode
case "$EVENT_NAME" in
  pull_request)
    if { [ "$PR_ACTION" = opened ] || [ "$PR_ACTION" = reopened ] || [ "$PR_ACTION" = ready_for_review ]; } \
       && [ "$PR_DRAFT" != true ]; then
      TARGET="in review"
    elif [ "$PR_ACTION" = closed ] && [ "$PR_MERGED" = true ] && [ "$PR_BASE" = dev ]; then
      TARGET="ready to ship"
    else
      notice "pull_request $PR_ACTION (base $PR_BASE, draft=$PR_DRAFT) - nothing to do."; exit 0
    fi
    TEXT="$(jq -r '.pull_request.title // "", .pull_request.body // ""' "$GITHUB_EVENT_PATH")"
    add_commits "$(gh api "repos/$REPO/pulls/$PR_NUMBER/commits?per_page=100" 2>/dev/null || true)"
    ;;
  push)
    case "$REF_NAME" in
      main) TARGET="done" ;;
      staging)
        if [ "$STAGING_ENV" != true ]; then notice "no staging environment - skipping."; exit 0; fi
        TARGET="staging" ;;
      *) notice "push to $REF_NAME - nothing to do."; exit 0 ;;
    esac
    if [ -z "${BEFORE:-}" ] || [ "$BEFORE" = 0000000000000000000000000000000000000000 ]; then
      COMMITS="$(gh api "repos/$REPO/commits/$SHA" --jq '[.]')"
    else
      COMMITS="$(gh api "repos/$REPO/compare/$BEFORE...$SHA" --jq '.commits' 2>/dev/null \
                 || gh api "repos/$REPO/commits/$SHA" --jq '[.]')"
    fi
    add_commits "$COMMITS"
    ;;
  *) notice "event $EVENT_NAME is not handled."; exit 0 ;;
esac

ISSUES="$(printf '%s\n' "$TEXT" \
  | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+' | grep -oE '[0-9]+$' | sort -un || true)"
if [ -z "$ISSUES" ]; then notice "no Fixes/Closes/Resolves #N found - nothing to move."; exit 0; fi
PRIORITY_NAME=""
fi # event mode

# ---- 2. the board, its Status field and the target option (by name) ----
gql() { GH_TOKEN="$PROJECT_TOKEN" gh api graphql "$@"; }

BOARD="$(gql -f o="$OWNER" -F n="$PROJECT_NUMBER" -f query='
  query($o:String!,$n:Int!){repositoryOwner(login:$o){
    ... on User{projectV2(number:$n){id field(name:"Status"){... on ProjectV2SingleSelectField{id options{id name}}}}}
    ... on Organization{projectV2(number:$n){id field(name:"Status"){... on ProjectV2SingleSelectField{id options{id name}}}}}}}')"
PROJECT_ID="$(echo "$BOARD" | jq -r '.data.repositoryOwner.projectV2.id // empty')"
FIELD_ID="$(echo "$BOARD" | jq -r '.data.repositoryOwner.projectV2.field.id // empty')"
[ -n "$PROJECT_ID" ] && [ -n "$FIELD_ID" ] || { echo "::error::Project #$PROJECT_NUMBER of $OWNER or its Status field was not found (check the GitHub App installation / PROJECT_TOKEN and the project number)."; exit 1; }

OPTION_ID=""
[ -z "$TARGET" ] || while IFS=$'\t' read -r id name; do
  n="$(printf '%s' "$name" | norm)"
  if [ "$n" = "$TARGET" ] || { [ "$TARGET" = "ready to ship" ] && [ "$n" = "ready for testing" ]; } \
     || { [ "$TARGET" = staging ] && { [ "$n" = "staging qa" ] || [ "$n" = staging ]; }; }; then
    OPTION_ID="$id"; break
  fi
done < <(echo "$BOARD" | jq -r '.data.repositoryOwner.projectV2.field.options[]|[.id,.name]|@tsv')
[ -z "$TARGET" ] || [ -n "$OPTION_ID" ] || { echo "::error::No '$TARGET' column on the board."; exit 1; }
TARGET_RANK="$(rank "$TARGET")"

# add mode with a priority: the board's Priority field and the option (by name, emoji ignored)
PRI_FIELD_ID=""; PRI_OPTION_ID=""
if [ -n "$PRIORITY_NAME" ]; then
  PRI="$(gql -f o="$OWNER" -F n="$PROJECT_NUMBER" -f query='
    query($o:String!,$n:Int!){repositoryOwner(login:$o){
      ... on User{projectV2(number:$n){field(name:"Priority"){... on ProjectV2SingleSelectField{id options{id name}}}}}
      ... on Organization{projectV2(number:$n){field(name:"Priority"){... on ProjectV2SingleSelectField{id options{id name}}}}}}}')"
  PRI_FIELD_ID="$(echo "$PRI" | jq -r '.data.repositoryOwner.projectV2.field.id // empty')"
  [ -n "$PRI_FIELD_ID" ] || { echo "::error::The board has no single-select Priority field."; exit 1; }
  while IFS=$'\t' read -r id name; do
    if [ "$(printf '%s' "$name" | norm)" = "$PRIORITY_NAME" ]; then PRI_OPTION_ID="$id"; break; fi
  done < <(echo "$PRI" | jq -r '.data.repositoryOwner.projectV2.field.options[]|[.id,.name]|@tsv')
  [ -n "$PRI_OPTION_ID" ] || { echo "::error::No priority '${PRIORITY:-}' on the board."; exit 1; }
fi

# ---- 3. move every referenced card forward ----
RC=0
for N in $ISSUES; do
  NODE_ID="$(gh api "repos/$REPO/issues/$N" --jq 'select(.pull_request|not)|.node_id' 2>/dev/null || true)"
  if [ -z "$NODE_ID" ]; then
    # asked for explicitly in add mode: that is an error, not a stray reference
    if [ -n "$ISSUE" ]; then echo "::error::#$N is not an issue of $REPO (or it cannot be read with github-token)."; RC=1; continue; fi
    notice "#$N is not an issue of $REPO - skipped."; continue
  fi

  # idempotent: returns the existing card when the issue is already on the board
  ITEM="$(gql -f p="$PROJECT_ID" -f c="$NODE_ID" -f query='
    mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id
      status:fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}' 2>&1)" || {
    echo "::error::Could not add the card of #$N. If this says 'Could not resolve to a node', the token cannot see the issue: a GitHub App needs Issues and Pull requests (read) on the repository, a classic PAT needs the scope repo as well as project."
    echo "$ITEM" | head -3; RC=1; continue; }
  ITEM_ID="$(echo "$ITEM" | jq -r '.data.addProjectV2ItemById.item.id // empty')"
  [ -n "$ITEM_ID" ] || { echo "::error::Could not add/find the card of #$N."; RC=1; continue; }
  CUR="$(echo "$ITEM" | jq -r '.data.addProjectV2ItemById.item.status.name // ""')"
  [ -z "$ISSUE" ] || notice "issue #$N is on the board $OWNER #$PROJECT_NUMBER"

  if [ -n "$PRI_OPTION_ID" ]; then
    # only a card without a priority gets one: a re-run must not undo a human's decision
    CUR_PRI="$(gql -f i="$ITEM_ID" -f query='query($i:ID!){node(id:$i){... on ProjectV2Item{priority:fieldValueByName(name:"Priority"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}' \
               | jq -r '.data.node.priority.name // ""')"
    if [ -n "$CUR_PRI" ]; then
      notice "#$N keeps its priority '$CUR_PRI'."
    else
      gql -f p="$PROJECT_ID" -f i="$ITEM_ID" -f f="$PRI_FIELD_ID" -f o="$PRI_OPTION_ID" -f query='
        mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' >/dev/null
      echo "#$N: priority '${PRIORITY:-}'"
    fi
  fi
  [ -n "$TARGET" ] || continue

  if [ -z "$CUR" ]; then
    # just added: the board's own "Item added" workflow sets New a moment later - let it finish first
    sleep 8
    CUR="$(gql -f i="$ITEM_ID" -f query='query($i:ID!){node(id:$i){... on ProjectV2Item{status:fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}' \
           | jq -r '.data.node.status.name // ""')"
  fi

  CUR_RANK="$(rank "$(printf '%s' "$CUR" | norm)")"
  if [ "$CUR_RANK" -ge "$TARGET_RANK" ]; then
    notice "#$N stays in '$CUR' (already at or past '$TARGET')."; continue
  fi
  gql -f p="$PROJECT_ID" -f i="$ITEM_ID" -f f="$FIELD_ID" -f o="$OPTION_ID" -f query='
    mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' >/dev/null
  echo "#$N: '${CUR:-none}' -> '$TARGET'"
done
exit "$RC"
