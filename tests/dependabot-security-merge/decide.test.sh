#!/usr/bin/env bash
#
# Checks the "Decide" step of .github/workflows/dependabot-security-merge.yml.
#
# The step's script is lifted out of the workflow and run exactly as Actions runs a `run:` block
# (bash -e) with `gh` stubbed, so nothing here touches GitHub. fixtures/kit-*.commit.txt are the
# real commit messages of the two multi-dependency Dependabot PRs that the gate wrongly left for
# manual review (givanov95/laravel-starter-kit #37 and #38).
#
#   tests/dependabot-security-merge/decide.test.sh
#
# Needs bash, jq and python3 with PyYAML.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
workflow="$here/../../.github/workflows/dependabot-security-merge.yml"
fixtures="$here/fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$workflow" > "$work/decide.sh" <<'PY'
import sys
import yaml

steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["merge"]["steps"]
print(next(step for step in steps if step.get("id") == "decide")["run"])
PY

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# `gh pr view <url> --json labels,body,commits` and `gh api repos/.../contents/<file> --jq .content`.
case "$1 $2" in
    "pr view")
        jq -n --rawfile commit "$FIXTURE_COMMIT" --arg labels "${FIXTURE_LABELS:-dependencies}" \
            '{labels: ($labels | split(",") | map({name: .})), body: "", commits: [{messageBody: $commit}]}'
        ;;
    api*)
        case "$2" in
            *dependabot.yml*) base64 < "$FIXTURE_DEPENDABOT" | tr -d '\n'; echo ;;
            *) exit 1 ;;
        esac
        ;;
    *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$work/bin/gh"

# A commit message in the shape Dependabot writes: one "Updates `name` from A to B" line per dependency.
commit() {
    local file="$work/commit.$RANDOM.txt" line
    {
        printf 'Bumps [x](https://example.test/x) to 2.0.0.\n\n'
        for line in "$@"; do printf '%s\n' "$line"; done
        printf '\n---\nupdated-dependencies:\n- dependency-name: x\n  dependency-version: 2.0.0\n  dependency-type: direct:production\n...\n'
    } > "$file"
    echo "$file"
}

passed=0
failed=0

# expect <name> <true|false> [VAR=value ...]  — runs Decide and compares its merge= output.
expect() {
    local name=$1 want=$2 got
    shift 2
    : > "$work/out"

    env -i PATH="$work/bin:$PATH" GH_TOKEN=x PR_URL=https://github.com/o/r/pull/1 REPO=o/r BASE=main \
        ECOSYSTEM=npm_and_yarn ALLOWED=patch,minor UPDATE_TYPE= DEPENDENCY_NAMES= \
        FIXTURE_DEPENDABOT="$fixtures/dependabot-actions-only.yml" \
        GITHUB_OUTPUT="$work/out" "$@" bash -e "$work/decide.sh" > "$work/log" 2>&1
    got=$(sed -n 's/^merge=//p' "$work/out")

    if [ "$got" = "$want" ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $name — expected merge=$want, got merge=${got:-<none>}"
        sed 's/^/    | /' "$work/log"
    fi
}

# ── PRs that carry an update-type: behaviour must not change ───────────────────────────────────
c=$(commit 'Updates `a` from 1.2.3 to 1.2.4')
expect 'single dependency, patch'                  true  UPDATE_TYPE=version-update:semver-patch DEPENDENCY_NAMES=a FIXTURE_COMMIT="$c"
expect 'single dependency, minor'                  true  UPDATE_TYPE=version-update:semver-minor DEPENDENCY_NAMES=a FIXTURE_COMMIT="$c"
expect 'single dependency, major'                  false UPDATE_TYPE=version-update:semver-major DEPENDENCY_NAMES=a FIXTURE_COMMIT="$c"
expect 'single dependency, minor but only patch allowed' false UPDATE_TYPE=version-update:semver-minor ALLOWED=patch DEPENDENCY_NAMES=a FIXTURE_COMMIT="$c"
expect 'update-type wins over the commit message'  false UPDATE_TYPE=version-update:semver-major DEPENDENCY_NAMES=a FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4')"
expect 'not a security update (npm is configured)' false UPDATE_TYPE=version-update:semver-patch DEPENDENCY_NAMES=a FIXTURE_COMMIT="$c" FIXTURE_DEPENDABOT="$fixtures/dependabot-npm.yml"

# ── multi-dependency PRs: update-type is empty, the level comes from the commit message ──────
expect 'laravel-starter-kit #37 (patch + patch)'   true  DEPENDENCY_NAMES='@vue/server-renderer, vue' FIXTURE_COMMIT="$fixtures/kit-37.commit.txt"
expect 'laravel-starter-kit #38 (major + major)'   false DEPENDENCY_NAMES='postcss-selector-parser, eslint-plugin-vue' FIXTURE_COMMIT="$fixtures/kit-38.commit.txt"
grep -q 'major' "$work/log" || { failed=$((failed + 1)); echo "FAIL: #38 should be left because of its major bump (log below)"; sed 's/^/    | /' "$work/log"; }

expect 'patch + minor'                             true  DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 2.0.1 to 2.1.0')"
expect 'patch + major'                             false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 2.0.1 to 3.0.0')"
expect 'minor with only patch allowed'             false DEPENDENCY_NAMES='a, b' ALLOWED=patch FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 2.0.1 to 2.1.0')"
expect 'major when majors are allowed'             true  DEPENDENCY_NAMES='a, b' ALLOWED=patch,minor,major FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 2.0.1 to 3.0.0')"
expect 'versions with a leading v'                 true  DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from v1.2.3 to v1.2.4' 'Updates `b` from v2.0.1 to v2.0.2')"
expect 'two-part versions'                         true  DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2 to 1.3' 'Updates `b` from 2.1 to 2.4')"
expect 'two-part major'                            false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2 to 2.0' 'Updates `b` from 2.1 to 2.4')"
expect 'comparison is numeric, not textual'        true  DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.9.0 to 1.10.0' 'Updates `b` from 2.0.9 to 2.0.10')"
expect 'repeated dependency, highest level wins'   false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `a` from 1.2.3 to 2.0.0' 'Updates `b` from 1.0.0 to 1.0.1')"

# ── fail closed: anything that cannot be read leaves the PR for a human ───────────────────────
expect 'a dependency without an Updates line'      false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4')"
expect 'no dependency names reported'              false DEPENDENCY_NAMES='' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4')"
expect 'no Updates lines at all'                   false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit)"
expect 'pre-release target'                        false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 1.0.0 to 1.1.0-beta.1')"
expect 'pre-release source'                        false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 1.0.0-rc.1 to 1.0.0')"
expect 'four-part version'                         false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 1.2.3.4 to 1.2.3.5')"
expect 'non-numeric version'                       false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from dev-main to dev-next')"
expect 'downgrade'                                 false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 2.1.0 to 2.0.9')"
expect 'same version'                              false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 2.1.0 to 2.1.0')"
expect 'a name matches literally, not as a pattern' false DEPENDENCY_NAMES='a.b, c' FIXTURE_COMMIT="$(commit 'Updates `aXb` from 1.0.0 to 1.0.1' 'Updates `c` from 1.0.0 to 1.0.1')"
expect 'a name is not matched as a prefix of another' false DEPENDENCY_NAMES='a, ab' FIXTURE_COMMIT="$(commit 'Updates `ab` from 1.0.0 to 1.0.1')"
expect 'an empty element in the allowed list does not allow an unknown level' false DEPENDENCY_NAMES='a, b' ALLOWED='patch,' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4')"
expect 'a line that is not at the start'           false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' '- Updates `b` from 1.0.0 to 1.0.1')"
expect 'trailing text after the version'           false DEPENDENCY_NAMES='a, b' FIXTURE_COMMIT="$(commit 'Updates `a` from 1.2.3 to 1.2.4' 'Updates `b` from 1.0.0 to 1.0.1 and more')"

echo "decide.test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
