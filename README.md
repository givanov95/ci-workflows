# ci-workflows

Reusable [GitHub Actions](https://docs.github.com/actions/using-workflows/reusing-workflows)
workflows for my Laravel + Vite apps and PHP packages. Define CI once here, call it from
every repo with a version tag — no copy-pasted YAML drifting across projects.

This is the **authoritative, enforced** quality gate (it can't be skipped like a local
`--no-verify`). Pair it with branch protection that requires the CI check to pass before merge.

## Workflows

### `laravel-app.yml` — Laravel + Inertia/Vite applications

Composer install → `key:generate` → Vite build → `php artisan test`.

| Input | Default | Description |
| --- | --- | --- |
| `php-version` | `8.4` | PHP version. |
| `node-version` | `20` | Node version for the asset build. |
| `build` | `true` | Run `npm ci` + `npm run build`. |
| `run-tests` | `true` | Run `php artisan test`. |
| `timeout-minutes` | `60` | Cancel the job if it runs longer than this. |

> Assumes the project's `phpunit.xml` uses an in-memory SQLite DB (the default in these
> projects). A suite that needs MySQL would require a service container — extend as needed.

### `php-package.yml` — PHP packages / libraries

Composer install → optional PHPStan → PHPUnit, across a PHP version matrix.

| Input | Default | Description |
| --- | --- | --- |
| `php-versions` | `["8.3", "8.4"]` | JSON array of PHP versions (matrix). |
| `phpstan` | `false` | Run `vendor/bin/phpstan analyse`. |
| `test-command` | `vendor/bin/phpunit` | Test command. |
| `timeout-minutes` | `30` | Cancel a matrix job that runs longer than this. |

### `board-sync.yml` — keep GitHub Project cards in step with PRs and pushes

Moves the card of every issue a PR or push refers to (`Fixes|Closes|Resolves #N` in the PR title,
body or commits, or in the pushed commits). Cards only move **forward**, so re-runs and
out-of-order events are harmless.

| Event | Card goes to |
| --- | --- |
| PR opened / reopened / ready for review | In review |
| PR merged into `dev` | Ready to ship |
| push to `staging` (only with `staging-environment: true`) | Staging / QA |
| push to `main` | Done |

| Input | Default | Description |
| --- | --- | --- |
| `project-number` | – (required) | The board number (the N in `.../projects/N`). |
| `project-owner` | repository owner | User or organization that owns the board. |
| `staging-environment` | `false` | `true` only if a push to `staging` really deploys a staging environment. |
| `app-client-id` | empty | Client ID of the GitHub App that moves the cards (see below). Empty = use `PROJECT_TOKEN`. |
| `issue` | empty | **Add mode** (see below): an issue number of this repository to put on the board (`12`, `#12` or the issue URL). Empty = the event mode above. |
| `column` | empty | Add mode: column to move the card to, forward only (e.g. `New`, `Ready`). Empty = leave it to the board. |
| `priority` | empty | Add mode: option of the board's `Priority` field (e.g. `P2`), set only when the card has none. |

The default `GITHUB_TOKEN` cannot reach a Project board, so the job needs one of two tokens. Without
either, the workflow prints a notice and stays green.

**GitHub App (recommended; the board must be owned by an organization).** Create an App in the
organization (no webhook) with **Organization permissions → Projects: Read and write** and
**Repository permissions → Issues: Read-only, Pull requests: Read-only**, and install it on the
repositories that call this workflow. Pass its **Client ID** as `app-client-id` and its private key
(PEM) as the secret **`BOARD_APP_KEY`** of each calling repo. The job then mints a 1-hour
installation token for the board owner with only those three permissions and revokes it at the end
(`actions/create-github-app-token`, pinned by commit SHA). It takes precedence over `PROJECT_TOKEN`;
`app-client-id` without the secret fails the job with a clear error (except on a Dependabot run, see
below). No personal token and no access to your other repositories is involved.

**`PROJECT_TOKEN` (legacy; the only option for a *user-owned* board).** A *classic* personal access
token with the **`project`** scope
(`https://github.com/settings/tokens/new?scopes=project,repo&description=gws-board-sync`);
fine-grained tokens and GitHub Apps do not support user-owned boards. For **private repositories** the
token also needs **`repo`**: with `project` alone GitHub answers `Could not resolve to a node with the
global id` because the token cannot see the issue. That is access to every private repository of the
account, so prefer the App. Use a 1-year expiry and keep the token only in the secrets of the repos
that call this workflow; only the `Move cards` job reads it.

Columns are found by name (emoji ignored): In review, Ready to ship (or Ready for Testing),
Staging / QA (or Staging), Done.

**Dependabot.** A run whose actor or PR author is `dependabot[bot]` (including a Dependabot PR merged
by a human) moves nothing: Dependabot runs get only Dependabot secrets, so there is no board key, and
Dependabot PRs quote upstream release notes whose `Fixes #N` point at another repository.
`board-sync.yml` skips such a run at job level, without a runner (not in add mode, see below); the composite action prints a
notice and stays green. Commits authored by Dependabot (also the squash commit of its PR) are ignored
on a push and in the commits of a PR for the same reason. Callers need no `if:` for Dependabot.
On a Dependabot run the job of `board-sync.yml` is therefore *skipped*, not *success*: a caller job
with `needs:` on it is skipped too unless it has its own `if: always()` (or checks `needs.<job>.result`).

This relies on Dependabot's commits reaching `main` as they are: a fast-forward or a merge commit,
as `/gws:ship` does. If a `dev` → `main` PR were squash-merged, GitHub would join the messages of all
its commits, Dependabot's release notes included, into one commit authored by the person merging,
and those references would count.

For a repo that deploys, call it from the deploy workflow so a card moves only after the deploy
succeeded (`needs: deploy`), and add a small `board.yml` for the PR events:

```yaml
# deploy workflow (push to staging / main)
  board:
    needs: deploy
    permissions: { contents: read, issues: read, pull-requests: read }
    uses: givanov95/ci-workflows/.github/workflows/board-sync.yml@<full commit SHA> # v1.8.0
    with:
      project-number: 1                    # staging-environment: true if it has one
      app-client-id: Iv23xxxxxxxxxxxxxxxx  # the GitHub App's Client ID (not a secret)
    secrets: { BOARD_APP_KEY: "${{ secrets.BOARD_APP_KEY }}" }
```

```yaml
# .github/workflows/board.yml
name: Board
on:
  pull_request:
    types: [opened, reopened, ready_for_review, closed]
jobs:
  board:
    permissions: { contents: read, issues: read, pull-requests: read }
    uses: givanov95/ci-workflows/.github/workflows/board-sync.yml@<full commit SHA> # v1.8.0
    with:
      project-number: 1
      app-client-id: Iv23xxxxxxxxxxxxxxxx
    secrets: { BOARD_APP_KEY: "${{ secrets.BOARD_APP_KEY }}" }
```

A repo with no deploy (a package) can skip the deploy workflow and add `push: branches: [main]` to
`board.yml` instead.

**Add mode — put an issue on the board.** `gh issue create` (or `GITHUB_TOKEN`) never adds an issue
to a board, and the board has no "Auto-add to project". A job that opens an issue (e.g. a scheduled
security audit) passes its number as `issue`: the event is then ignored, and the issue goes on the
board with the same token setup. The add is idempotent — an issue that is already there keeps its
card and column, so a weekly re-run is harmless; a new card gets New from the board's own "Item
added" workflow. `column` moves the card **forward only** (like every other move; after the add it
waits 8 s for that "Item added" workflow first — a board workflow slower than that can still put a
new card back in New), and `priority` is set only on a card that has none, so
a re-run never undoes a human's decision. Columns and priorities are found by name, emoji ignored; a
column outside the flow or a priority the board does not have fails before anything is added, as
do a number that is not an issue of this repository, a missing board and a failed add.

Add mode is a side task of a job that has done its work, so where the event mode fails, it only
prints a notice to add the card by hand (`board.sh add <N>`) and stays green: no token at all, an
`app-client-id` without its key (e.g. a repo without the `BOARD_APP_KEY` secret), and a GitHub App
whose board owner (`project-owner`) is not the repository's owner — the installation token is minted
for the board owner and cannot see an issue of a personal repository, so the token is not even
minted. A `PROJECT_TOKEN` (classic PAT with `repo`) does try such an issue. The Dependabot skip
of the event mode does not apply: an explicitly given issue is added on any run that has a token.
The job needs `issues: read` (the node id of the issue is read with `github-token`).

```yaml
# a step of the job that opened the issue (the action; board-sync.yml takes the same inputs)
      - name: Board
        if: steps.audit.outputs.issue != ''
        uses: givanov95/ci-workflows/.github/actions/board-sync@<full commit SHA> # vX.Y.Z
        with:
          project-owner: gwebsolutions-dev
          project-number: 1
          issue: ${{ steps.audit.outputs.issue }}
          app-client-id: Iv23xxxxxxxxxxxxxxxx
          app-private-key: ${{ secrets.BOARD_APP_KEY }}   # empty in a repo without it: a notice
          # column: Ready
          # priority: P1
```

### `post-deploy-check.yml` — health gate after a deploy

Polls a URL (e.g. Laravel's `/up`) until it answers the expected status, retrying while the app restarts.

| Input | Default | Description |
| --- | --- | --- |
| `url` | – (required) | Health URL. |
| `expected-status` | `200` | Status that means healthy. |
| `attempts` / `interval` | `12` / `10` | Tries and seconds between them. |
| `initial-delay` | `0` | Seconds to wait before the first try. |
| `soft` | `false` | Never fail; only set the `healthy` output (`true`/`false`). |
| `timeout-minutes` | `30` | Cancel the check after this long — raise it together with `attempts` and `interval`. |

Use it hard (`needs: deploy`) as the deploy's verdict, and soft **before** the deploy as a baseline:
a rollback should only be attempted when the site was healthy before and is not after.

```yaml
  pre:                      # baseline, in parallel with the tests
    uses: givanov95/ci-workflows/.github/workflows/post-deploy-check.yml@v1
    with: { url: https://example.com/up, attempts: 1, soft: true }

  health:                   # verdict, after the deploy
    needs: deploy
    uses: givanov95/ci-workflows/.github/workflows/post-deploy-check.yml@v1
    with: { url: https://example.com/up, initial-delay: 10 }
```

### `dependabot-security-merge.yml` — merge Dependabot security updates after green tests

A gate + merge step, **not** a test runner: every project has its own CI (databases, asset
build), so the caller runs that as a job and this workflow depends on it (`needs`). It merges a
PR only when **all** of these hold: opened by Dependabot, a **security** update (a PR for an
ecosystem that `dependabot.yml` does not configure for version updates, or one marked as a security
update — version updates are never touched), a semver level in `allowed-update-types`, and the
caller's tests passed. Anything else is left open for a human.

A PR that bumps several dependencies at once (a vulnerable package plus its ancestor, a
`dependabot/…/multi-…` branch) has no `update-type` from `dependabot/fetch-metadata`. For those
the level is read from the `Updates \`name\` from A to B` lines of Dependabot's commit message:
the highest level wins, and if any dependency cannot be read (no such line, pre-release or
non-numeric version, downgrade) the PR stays open. The step is covered by
`tests/dependabot-security-merge/decide.test.sh` (bash, jq, PyYAML; nothing runs it automatically).

| Input | Default | Description |
| --- | --- | --- |
| `allowed-update-types` | `patch,minor` | Semver levels that may be merged automatically. |
| `deploy-workflow` | – | Workflow file to start after the merge (e.g. `deploy.yml`). Leave empty if nothing deploys on push. |

**No token or secret is needed.** The job merges with its own `GITHUB_TOKEN` (the caller grants
`contents: write`, `pull-requests: write`, `actions: write`). A merge made with `GITHUB_TOKEN`
does not trigger `push` workflows, so a project that deploys on push names its workflow in
`deploy-workflow` and the job starts it with `workflow_dispatch` — add `workflow_dispatch:` to
that workflow's `on:`.

```yaml
# .github/workflows/dependabot-automerge.yml
name: Dependabot security auto-merge
on:
  pull_request:
    branches: [main]

concurrency:
  group: dependabot-merge-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  ci:
    if: github.actor == 'dependabot[bot]'
    # ... the project's own test job (same steps as its deploy `ci`)

  merge:
    needs: ci
    permissions:
      contents: write
      pull-requests: write
      actions: write
    uses: givanov95/ci-workflows/.github/workflows/dependabot-security-merge.yml@<commit-sha>  # v1.5.1
    with:
      deploy-workflow: deploy.yml
```

Also enable *Dependabot alerts* and *Dependabot security updates* on the repo
(`gh api -X PUT repos/OWNER/REPO/vulnerability-alerts` and `.../automated-security-fixes`).

## Composite actions — the same work without a job of its own

Every job is billed at least one whole minute, however short. Moving a board card (~10 s) or polling
a health URL in a job of its own therefore costs a full minute each time. The composite actions in
`.github/actions/` do exactly what `board-sync.yml` and `post-deploy-check.yml` do, but as **steps**
of a job that runs anyway (the deploy job), so they cost nothing extra:

| Action | Same as | Inputs |
|---|---|---|
| `.github/actions/board-sync` | `board-sync.yml` | `project-number`, `project-owner`, `staging-environment` (`'true'`/`'false'`), `app-client-id`, `app-private-key` (the `BOARD_APP_KEY` secret), `project-token`; add mode: `issue`, `column`, `priority` |
| `.github/actions/health-check` | `post-deploy-check.yml` | `url`, `expected-status`, `attempts`, `interval`, `initial-delay`, `soft`; output `healthy` |
| `.github/actions/deploy-release` | – (action only) | `version-url`, `expected-sha`, `branch`, `release`, `github-token`; outputs `sha`, `tag`, `release` |
| `.github/actions/skip-if-tested` | – (action only) | `github-token`; outputs `skip`, `reason` |

A deploy job with a baseline, the deploy, the verdict and the cards in one runner:

```yaml
jobs:
  ci-deploy:
    runs-on: ubuntu-latest
    permissions: { contents: read, issues: read, pull-requests: read }
    outputs:   # for a rollback job: needs.ci-deploy.outputs.*
      pre_healthy: ${{ steps.pre.outputs.healthy }}
      deployed: ${{ steps.deploy.outcome == 'success' }}
      healthy: ${{ steps.health.outputs.healthy }}
    steps:
      # ...checkout, tests, build...
      - id: pre
        uses: givanov95/ci-workflows/.github/actions/health-check@<sha> # v1.8.0
        with: { url: https://example.com/up, attempts: 1, soft: true }
      - id: deploy
        run: ssh ... deploy
      - id: health
        uses: givanov95/ci-workflows/.github/actions/health-check@<sha> # v1.8.0
        with: { url: https://example.com/up, initial-delay: 10 }
      - uses: givanov95/ci-workflows/.github/actions/board-sync@<sha> # v1.8.0
        with:
          project-number: 1
          app-client-id: Iv23liy46aBedLh9vZoN
          app-private-key: ${{ secrets.BOARD_APP_KEY }}
```

A board job that would do nothing is cheapest when it never starts: a job-level `if:` that is false
skips the job without a runner. The script only acts on a PR that is opened / reopened / ready for
review and not a draft, or merged into `dev`, and on a push whose commits mention `#N`. A job that
calls `board-sync.yml` only needs to leave out drafts (that workflow skips Dependabot itself); a job
that runs the composite action as a step should leave out Dependabot as well, since the action can
only no-op once its runner is up:

```yaml
on:
  pull_request:
    types: [opened, reopened, ready_for_review]   # + closed only where PRs merge into dev
jobs:
  board:   # calls board-sync.yml
    if: ${{ !github.event.pull_request.draft }}
  # a job that runs .github/actions/board-sync as a step:
  #   if: github.event.pull_request.user.login != 'dependabot[bot]' && !github.event.pull_request.draft
```

The reusable workflows stay for existing callers. The board logic exists once, in
`.github/actions/board-sync/sync.sh`: `board-sync.yml` checks out that action from its own commit
(`job.workflow_repository` at `job.workflow_sha`) and runs it, so a caller pinned to a SHA runs
exactly that code. `tests/board-sync/sync.test.sh` covers the script; `actions-self-test.yml` runs
both actions and `board-sync.yml` on every change to them.

### `deploy-release` — is the site on this commit? Then tag the release

Two steps for the deploy job, right **after** the deploy and its health check and **before** the
board step (board-sync stays last):

- **Version** reads the site's `version.json` — `{"sha": "<short or full SHA>", "deployed_at": "…"}`,
  written by the deploy script on the server — and compares it with the commit this run deployed. A
  **mismatch fails the step**, so the board step after it is skipped and no card goes to Done. A
  *newer* commit that contains the deployed one passes with a warning (the server pulled the branch
  head, which a later push had moved): this commit is live, and Release tags the one that is. No
  answer, no JSON or no valid `sha` fails as well. Runs on every deploy (staging too).
- **Release** — only when `branch` is `main` and `release` is `'true'`: tag + GitHub release
  `vYYYY.MM.DD` (date in Europe/Sofia; a second release that day is `.2`, then `.3` …) on the commit
  the site runs, with the notes of the PRs since the previous release (`--generate-notes`). Nothing
  is created when a date tag already points at that commit (a re-run); `tag` is then that tag.
  **A failed release does not fail the action** — a release must not undo a good deploy: it is an
  error annotation, `release` is `failed` and `tag` empty (`/gws:ship` creates the release when it
  finds none). That is the old `continue-on-error: true` of the Release step, built in. Do **not**
  put `continue-on-error` on the action itself: it would hide a version mismatch too.

| Input | Default | Description |
| --- | --- | --- |
| `version-url` | – (required) | `version.json` of the environment this run deployed (one per branch when the job deploys staging too). |
| `expected-sha` | `workflow_run.head_sha` or `github.sha` | Full SHA of the commit this run deployed. |
| `branch` | `workflow_run.head_branch` or `github.ref_name` | Branch this run deployed; a release is made only for `main`. |
| `release` | `'true'` | `'false'` only checks the version. |
| `github-token` | `github.token` | Reads commits and tags, creates the release. |

| Output | |
| --- | --- |
| `sha` | Full SHA the site runs (the deployed commit, or a newer one that contains it). |
| `tag` | Its release tag (new or already there); empty when no release was made or it failed. |
| `release` | `new`, `existing`, `failed` or `skipped` (not `main`, or `release: 'false'`). |

The defaults cover a deploy started by `push` and by `workflow_run` (which deploys `head_sha` of
`head_branch`, while `github.sha` / `github.ref_name` are the default branch's). The job needs
`contents: write` for the tag and the release (`contents: read` is enough with `release: 'false'`)
and the deploy workflow a `concurrency` group, or two runs can pick the same tag name. The action has
no checkout and no third-party action (the job holds the deploy key): everything goes through the
GitHub API. A release made with the job's token does not start other workflows. The runner must
reach `version-url` like the health check does; if it cannot (basic auth, Cloudflare Access), leave
the action out and let `/gws:ship` check and tag. The same logic is `plugins/gws/scripts/release.sh`
in `givanov95/claude-flow` (for deploys that do not run on Actions): change both together.
`tests/deploy-release/release.test.sh` covers the script.

```yaml
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  ci-deploy:
    runs-on: ubuntu-latest
    permissions: { contents: write, issues: read, pull-requests: read }   # write: tag + release
    steps:
      # ...tests, build, deploy, health check...
      - name: Version and release
        uses: givanov95/ci-workflows/.github/actions/deploy-release@<full commit SHA> # vX.Y.Z
        with:
          version-url: ${{ (github.event.workflow_run.head_branch || github.ref_name) == 'main' && 'https://example.com/version.json' || 'https://staging.example.com/version.json' }}
      - uses: givanov95/ci-workflows/.github/actions/board-sync@<full commit SHA> # v1.8.0
        with:
          project-number: 1
          app-client-id: Iv23liy46aBedLh9vZoN
          app-private-key: ${{ secrets.BOARD_APP_KEY }}
```

### `skip-if-tested` — do not run the same tests twice

A repo that tests every pull request and then every push to `main` runs the tests twice on the same
code: a squash merge of a PR that was up to date with `main` gives `main` exactly the files the PR
already tested. A fast-forward `staging` → `main` pushes a commit `staging` already tested. This
action tells the test job so, and the test steps are skipped.

On a **push** (any other event gives `skip=false`) the code counts as tested when a **successful run
of the same workflow file** exists for:

- the **same commit** — a fast-forward promotion; or
- the head of this commit's **merged pull request**, when that head has the **same tree** (the same
  files) as the pushed commit. A PR that was behind its base gives the base a tree nobody tested, so
  the tests run. The same tree also means the same workflow file, so the earlier run checked what
  this one would.

It **never skips on doubt**: a GitHub error, a missing permission or an unexpected answer is a
warning and `skip=false`, and the action never fails the job. No checkout, no third-party action.

Guard the **steps**, not the job: a test job skipped with a job-level `if:` also skips a deploy job
that `needs:` it. The job then still costs about a minute (and starts its `services:`, ~20 s), not
the whole test run:

```yaml
permissions:            # without them the action finds nothing and the tests run
  actions: read         # runs of this workflow
  contents: read        # commit trees
  pull-requests: read   # the merged PR of a commit

jobs:
  tests:
    runs-on: ubuntu-latest
    steps:
      - name: Already tested?
        id: tested
        uses: givanov95/ci-workflows/.github/actions/skip-if-tested@<full commit SHA> # vX.Y.Z
      - uses: actions/checkout@...
        if: steps.tested.outputs.skip != 'true'
      # ...every setup and test step gets the same if: (combine with your own, e.g. !cancelled() && ...)
      - name: Run tests
        if: steps.tested.outputs.skip != 'true'
        run: php artisan test
  deploy:
    needs: tests        # a green tests job, skipped steps or not
```

Only useful where the same workflow runs on `pull_request` **and** on `push`, or on pushes to two
branches of one chain. A repo that tests only on `push` to `main` has nothing to skip.
`tests/skip-if-tested/skip.test.sh` covers the script; `actions-self-test.yml` runs it live.

## Fast test jobs

GitHub bills every job rounded **up** to a whole minute: a test job of 4:03 costs 5 minutes, one of
1:01 costs 2. The organisation's free minutes are shared by all its private repos, so every project
keeps its test job short — also the ones that are under a boundary today, since tests grow:

- **Parallel tests** — `php artisan test --parallel` (needs `brianium/paratest` in `require-dev`;
  Pest has it built in: `vendor/bin/pest --parallel`). Each process gets its own database
  (`<name>_test_1`, …), which the service user must be allowed to create (the `postgres`/`root`
  user of a CI service is). Only for tests that do not share files, cache keys or ports; check
  locally first, and leave it out where it is flaky.
- **Databases in memory** — a throwaway service database needs no durability:
  `options: --tmpfs /var/lib/postgresql/data` (MySQL/MariaDB: `--tmpfs /var/lib/mysql`).
- **Caches** — `ramsey/composer-install` for Composer, `actions/setup-node` with `cache: npm`.
- **Only the steps the tests need** — one `npm ci`, a Vite build only when the tests render it
  (a committed `public/build` needs none), no tools installed that no step uses.
- **Timeouts** — a `timeout-minutes` on the job and on the slow steps, so a hang is cut in minutes,
  not after six hours.
- **One job instead of several** where they share the setup (a matrix of databases as steps of one
  job): every job is billed at least a minute and pays its setup again.
- **Nothing twice** — `skip-if-tested` above where a workflow runs on both `pull_request` and
  `push`; `paths-ignore: ['**.md']` for docs-only changes.

Write the test job's duration before and after into the PR that changes it.

## Usage

Add a tiny caller workflow to the consuming repo.

**Laravel app** — `.github/workflows/ci.yml`:

```yaml
name: CI
on: [push, pull_request]
jobs:
  ci:
    uses: givanov95/ci-workflows/.github/workflows/laravel-app.yml@v1
```

**PHP package** — `.github/workflows/ci.yml`:

```yaml
name: CI
on: [push, pull_request]
jobs:
  ci:
    uses: givanov95/ci-workflows/.github/workflows/php-package.yml@v1
    with:
      php-versions: '["8.3", "8.4"]'
      phpstan: true
```

## Permissions, timeouts and concurrency

The reusable workflows ask for the least they need: `laravel-app.yml` and `php-package.yml` run with
`contents: read` and check out without keeping the token (`persist-credentials: false`),
`post-deploy-check.yml` needs no permissions at all. Every job has a `timeout-minutes` (an input
where a project may need more); the actions they use are pinned by commit SHA, kept current by
Dependabot (`.github/dependabot.yml`).

`concurrency` is **not** set here: whether a newer push should cancel an older run is the caller's
policy (cancelling a deploy half-way is rarely what you want). In the calling workflow:

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true   # only for CI; leave it off for deploys
```

## Versioning

Reference a major tag and it tracks the latest compatible release:

- `@v1` — moving major tag: always the latest 1.x release. Convenient, and fine for the workflows
  that only read (`php-package.yml`, `laravel-app.yml`, `post-deploy-check.yml`). **Not for workflows
  that receive secrets or a write token** (`board-sync.yml`, `dependabot-security-merge.yml`, and
  the actions `board-sync` and `deploy-release`, which run inside the deploy job).
- `@v1.5.1` — exact release (reproducible). Release tags `v*.*.*` are protected by a ruleset: they
  cannot be moved or deleted. The moving `v1` is not covered by it; it is moved by hand to each new
  release.
- `@<sha>` — pinned commit (most secure). Use this, with the release in a comment, for every workflow
  that passes secrets or a write token: whoever can move a tag would otherwise choose the code that
  runs with them. Dependabot's `github-actions` ecosystem keeps such a pin current.

When this repo is **public**, any repo can call its workflows. If you ever make it private,
enable *Settings → Actions → Access* on this repo to allow your other repos to use it. That is not
enough for `board-sync.yml`: it also *checks out* this repo with the caller's `GITHUB_TOKEN`, which
cannot read another private repository, so it would need a token with access passed in as well.

## Which workflow per project

| Type | Workflow | Examples |
| --- | --- | --- |
| Laravel app | `laravel-app.yml` | gwebsolutions, slavelia, task, laravel-shop |
| PHP package | `php-package.yml` | laravel-translations, laravel-attachments, laravel-data-table, typed-http, laravel-git-hooks |

## License

MIT © Georgi Ivanov
