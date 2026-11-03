#!/usr/bin/env bash
#
# Checks .github/actions/deploy-release/release.sh, the two steps of the deploy-release action.
# `gh`, `curl` and `sleep` are stubbed, so nothing here touches the network or GitHub.
#
#   tests/deploy-release/release.test.sh
#
# Needs bash and jq.
#
# gh stub: `gh api <path> [--jq F]` answers $STUB/<path with / -> _>.json (through jq when --jq is
# given); <...>.fail = exit 1 with that stderr; a missing file = HTTP 422 (unknown commit).
# `gh release create` is logged, and fails with $STUB/release.fail when that file exists.
# curl stub: the body is $STUB/version.body; without it, a 404 (exit 22).

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root="$here/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

script="$root/.github/actions/deploy-release/release.sh"

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB/calls"
if [ "$1 $2" = "release create" ]; then
    [ -f "$STUB/release.fail" ] && { cat "$STUB/release.fail" >&2; exit 1; }
    exit 0
fi
[ "$1" = api ] || { echo "unexpected gh call: $*" >&2; exit 99; }
shift; path=; filter=
while [ $# -gt 0 ]; do
    case "$1" in
        --jq) filter=$2; shift 2 ;;
        --paginate) shift ;;
        -*) echo "unexpected flag $1" >&2; exit 99 ;;
        *) path=$1; shift ;;
    esac
done
key="$STUB/${path//\//_}"
[ -f "$key.fail" ] && { cat "$key.fail" >&2; exit 1; }
# like the real gh: on an HTTP error the body (JSON) goes to stdout, the message to stderr
[ -f "$key.json" ] || { echo '{"message":"No commit found for SHA","status":"422"}'; echo "gh: No commit found for SHA (HTTP 422)" >&2; exit 1; }
if [ -n "$filter" ]; then jq -r "$filter" "$key.json"; else cat "$key.json"; fi
STUB
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB/calls"
[ -f "$STUB/curl.warn" ] && cat "$STUB/curl.warn" >&2
[ -f "$STUB/version.body" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$STUB/version.body"
STUB
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$STUB/calls"\n' > "$work/bin/sleep"
chmod +x "$work/bin/gh" "$work/bin/curl" "$work/bin/sleep"

R=acme/app
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the deployed (expected) commit
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # another commit
TODAY="v$(TZ=Europe/Sofia date +%Y.%m.%d)"
URL=https://app.test/version.json

passed=0
failed=0
n=0
stub=
new_case() { n=$((n+1)); name=$1; stub="$work/case$n"; mkdir -p "$stub"; : > "$stub/calls"; errors=(); }
file() { printf '%s' "$2" > "$stub/$1"; }                                   # file <name> <content>
commit() { file "repos_${R//\//_}_commits_$1.json" "{\"sha\":\"$2\"}"; }   # commit <ref> <full sha>
tags() { file "repos_${R//\//_}_git_matching-refs_tags_v.json" "$1"; }
tagref() { printf '{"ref":"refs/tags/%s","object":{"type":"%s","sha":"%s"}}' "$1" "${3:-commit}" "$2"; }

# step check|tag [VAR=value ...] - runs the script as the action does; rc, log and outputs are kept
step() {
    local cmd=$1; shift
    : > "$stub/output"
    env -i PATH="$work/bin:$PATH" STUB="$stub" RUNNER_TEMP="$work" GITHUB_OUTPUT="$stub/output" \
        GH_TOKEN=x GH_REPO="$R" VERSION_URL="$URL" EXPECTED="$A" SHA="$A" \
        "$@" bash "$script" "$cmd" > "$stub/log" 2>&1
    rc=$?
}
want() { # want <description> <test> [args]
    local d=$1; shift
    "$@" || errors+=("$d")
}
rc_is() { [ "$rc" = "$1" ]; }
log_has() { grep -qF -- "$1" "$stub/log"; }
output_is() { grep -qxF -- "$1" "$stub/output"; }
no_output() { ! grep -q "^$1=" "$stub/output"; }
called() { grep -qF -- "$1" "$stub/calls"; }
not_called() { ! called "$1"; }
done_case() {
    if grep -q 'integer expression\|parse error\|unbound variable\|command not found' "$stub/log"; then errors+=("shell/jq error in the log"); fi
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

# ── check ────────────────────────────────────────────────────────────────────────────────────
new_case 'check: the site runs the expected commit (short sha)'
file version.body "{\"sha\":\"${A:0:7}\",\"deployed_at\":\"2026-11-03T10:00:00Z\"}"
step check
want 'exit 0' rc_is 0
want 'sha = the full expected sha' output_is "sha=$A"
want 'the request gets past a cache' called "$URL?t="
want 'no-cache header' called 'Cache-Control: no-cache'
want 'no GitHub call for an exact match' not_called 'gh api'
done_case

new_case 'check: a URL with a query string gets &t='
file version.body "{\"sha\":\"$A\"}"
step check VERSION_URL="$URL?env=prod"
want 'exit 0' rc_is 0
want '&t=' called "$URL?env=prod&t="
done_case

new_case 'check: a newer commit that contains the expected one -> warning, pass'
file version.body "{\"sha\":\"${B:0:9}\"}"; commit "${B:0:9}" "$B"
file "repos_acme_app_compare_$A...$B.json" '{"status":"ahead"}'
step check
want 'exit 0' rc_is 0
want 'sha = the newer commit' output_is "sha=$B"
want 'a warning' log_has '::warning'
done_case

new_case 'check: an older commit -> mismatch, fails'
file version.body "{\"sha\":\"${B:0:7}\"}"; commit "${B:0:7}" "$B"
file "repos_acme_app_compare_$A...$B.json" '{"status":"behind"}'
step check
want 'exit 1' rc_is 1
want 'names both commits' log_has "the site runs ${B:0:12}, not ${A:0:12} (behind)"
want 'no sha output' no_output sha
done_case

new_case 'check: a diverged commit -> mismatch, fails'
file version.body "{\"sha\":\"${B:0:7}\"}"; commit "${B:0:7}" "$B"
file "repos_acme_app_compare_$A...$B.json" '{"status":"diverged"}'
step check
want 'exit 1' rc_is 1
want 'says diverged' log_has '(diverged)'
done_case

new_case 'check: a sha that is not in the repo -> mismatch, fails'
file version.body '{"sha":"1234567"}'
step check
want 'exit 1' rc_is 1
want 'says it is not in the repo' log_has "which is not in $R"
done_case

new_case 'check: a GitHub error on the deployed commit -> fails with the real reason'
file version.body "{\"sha\":\"${B:0:7}\"}"; file "repos_acme_app_commits_${B:0:7}.fail" 'gh: Bad Gateway (HTTP 502)'
step check
want 'exit 1' rc_is 1
want 'the real reason' log_has 'HTTP 502'
want 'not called a mismatch' bash -c '! grep -q "not in" "$1"' _ "$stub/log"
done_case

new_case 'check: a GitHub error on the compare -> fails with the real reason'
file version.body "{\"sha\":\"${B:0:7}\"}"; commit "${B:0:7}" "$B"
file "repos_acme_app_compare_$A...$B.fail" 'gh: API rate limit exceeded (HTTP 403)'
step check
want 'exit 1' rc_is 1
want 'the real reason' log_has 'HTTP 403'
done_case

new_case 'check: a curl warning on stderr does not spoil the JSON'
file version.body "{\"sha\":\"${A:0:7}\"}"; file curl.warn 'Warning: something'
step check
want 'exit 0' rc_is 0
done_case

new_case 'check: no version.json (404) -> fails after three tries'
step check
want 'exit 1' rc_is 1
want 'says the site does not report' log_has 'does not answer'
want 'three tries' [ "$(grep -c '^curl' "$stub/calls")" = 3 ]
want 'sleeps between them only' [ "$(grep -c '^sleep 5' "$stub/calls")" = 2 ]
done_case

new_case 'check: HTML instead of JSON -> fails'
file version.body '<html>maintenance</html>'
step check
want 'exit 1' rc_is 1
want 'says no valid sha' log_has 'has no valid sha'
done_case

new_case 'check: a sha with other characters is refused'
file version.body '{"sha":"abc; rm"}'
step check
want 'exit 1' rc_is 1
want 'no GitHub call' not_called 'gh api'
done_case

new_case 'check: a JSON array is refused'
file version.body '["aaaaaaa"]'
step check
want 'exit 1' rc_is 1
done_case

new_case 'check: a short expected-sha is refused'
file version.body "{\"sha\":\"${A:0:7}\"}"
step check EXPECTED="${A:0:7}"
want 'exit 1' rc_is 1
want 'says why' log_has 'full 40-character'
want 'no request' not_called 'curl'
done_case

# ── tag ──────────────────────────────────────────────────────────────────────────────────────
new_case 'tag: the first release of the day'
tags "[$(tagref v2026.01.01 "$B")]"
step tag
want 'exit 0' rc_is 0
want "tag = $TODAY" output_is "tag=$TODAY"
want 'release = new' output_is 'release=new'
want 'release with notes on the commit' called "release create $TODAY --repo $R --target $A --title $TODAY --generate-notes"
done_case

new_case 'tag: no tags at all'
tags '[]'
step tag
want 'exit 0' rc_is 0
want "tag = $TODAY" output_is "tag=$TODAY"
done_case

new_case 'tag: the second and third release of the day'
tags "[$(tagref "$TODAY" "$B"),$(tagref "$TODAY.2" cccccccccccccccccccccccccccccccccccccccc)]"
step tag
want 'exit 0' rc_is 0
want "tag = $TODAY.3" output_is "tag=$TODAY.3"
done_case

new_case 'tag: an annotated tag counts for .N'
tags "[$(tagref "$TODAY" dddddddddddddddddddddddddddddddddddddddd tag)]"
step tag
want "tag = $TODAY.2" output_is "tag=$TODAY.2"
done_case

new_case 'tag: other tags (v1.2.3, a date with a suffix) do not count'
tags "[$(tagref v1.2.3 "$A"),$(tagref "$TODAY-rc" "$B")]"
step tag
want "tag = $TODAY" output_is "tag=$TODAY"
want 'release = new' output_is 'release=new'
done_case

new_case 'tag: the commit already has a date tag -> nothing is created (a re-run)'
tags "[$(tagref v2026.01.01 "$A")]"
step tag
want 'exit 0' rc_is 0
want 'tag = the existing one' output_is 'tag=v2026.01.01'
want 'release = existing' output_is 'release=existing'
want 'no release created' not_called 'release create'
done_case

new_case 'tag: gh release create fails -> exit 0, an error annotation, release = failed'
tags '[]'; file release.fail 'HTTP 403: Resource not accessible by integration'
step tag
want 'exit 0' rc_is 0
want 'an error annotation' log_has '::error'
want 'the reason' log_has 'Resource not accessible'
want 'release = failed' output_is 'release=failed'
want 'tag empty' output_is 'tag='
done_case

new_case 'tag: the tags cannot be read -> no release (no duplicate name), release = failed'
file "repos_acme_app_git_matching-refs_tags_v.fail" 'gh: Server Error (HTTP 500)'
step tag
want 'exit 0' rc_is 0
want 'release = failed' output_is 'release=failed'
want 'no release created' not_called 'release create'
done_case

new_case 'tag: no commit (the Version step gave none) -> release = failed'
tags '[]'
step tag SHA=
want 'exit 0' rc_is 0
want 'release = failed' output_is 'release=failed'
want 'no release created' not_called 'release create'
done_case

echo "release.test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
