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

The default `GITHUB_TOKEN` cannot reach a Project board, so the job needs one of two tokens. Without
either, the workflow prints a notice and stays green.

**GitHub App (recommended; the board must be owned by an organization).** Create an App in the
organization (no webhook) with **Organization permissions → Projects: Read and write** and
**Repository permissions → Issues: Read-only, Pull requests: Read-only**, and install it on the
repositories that call this workflow. Pass its **Client ID** as `app-client-id` and its private key
(PEM) as the secret **`BOARD_APP_KEY`** of each calling repo. The job then mints a 1-hour
installation token for the board owner with only those three permissions and revokes it at the end
(`actions/create-github-app-token`, pinned by commit SHA). It takes precedence over `PROJECT_TOKEN`;
`app-client-id` without the secret fails the job with a clear error. No personal token and no access
to your other repositories is involved.

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

For a repo that deploys, call it from the deploy workflow so a card moves only after the deploy
succeeded (`needs: deploy`), and add a small `board.yml` for the PR events:

```yaml
# deploy workflow (push to staging / main)
  board:
    needs: deploy
    permissions: { contents: read, issues: read, pull-requests: read }
    uses: givanov95/ci-workflows/.github/workflows/board-sync.yml@<full commit SHA> # v1.4.0
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
    uses: givanov95/ci-workflows/.github/workflows/board-sync.yml@<full commit SHA> # v1.4.0
    with:
      project-number: 1
      app-client-id: Iv23xxxxxxxxxxxxxxxx
    secrets: { BOARD_APP_KEY: "${{ secrets.BOARD_APP_KEY }}" }
```

A repo with no deploy (a package) can skip the deploy workflow and add `push: branches: [main]` to
`board.yml` instead.

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
  that receive secrets or a write token** (`board-sync.yml`, `dependabot-security-merge.yml`).
- `@v1.5.1` — exact release (reproducible). Release tags `v*.*.*` are protected by a ruleset: they
  cannot be moved or deleted. The moving `v1` is not covered by it; it is moved by hand to each new
  release.
- `@<sha>` — pinned commit (most secure). Use this, with the release in a comment, for every workflow
  that passes secrets or a write token: whoever can move a tag would otherwise choose the code that
  runs with them. Dependabot's `github-actions` ecosystem keeps such a pin current.

When this repo is **public**, any repo can call its workflows. If you ever make it private,
enable *Settings → Actions → Access* on this repo to allow your other repos to use it.

## Which workflow per project

| Type | Workflow | Examples |
| --- | --- | --- |
| Laravel app | `laravel-app.yml` | gwebsolutions, slavelia, task, laravel-shop |
| PHP package | `php-package.yml` | laravel-translations, laravel-attachments, laravel-data-table, typed-http, laravel-git-hooks |

## License

MIT © Georgi Ivanov
