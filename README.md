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
| `php-version` | `8.3` | PHP version. |
| `node-version` | `20` | Node version for the asset build. |
| `build` | `true` | Run `npm ci` + `npm run build`. |
| `run-tests` | `true` | Run `php artisan test`. |

> Assumes the project's `phpunit.xml` uses an in-memory SQLite DB (the default in these
> projects). A suite that needs MySQL would require a service container — extend as needed.

### `php-package.yml` — PHP packages / libraries

Composer install → optional PHPStan → PHPUnit, across a PHP version matrix.

| Input | Default | Description |
| --- | --- | --- |
| `php-versions` | `["8.3"]` | JSON array of PHP versions (matrix). |
| `phpstan` | `false` | Run `vendor/bin/phpstan analyse`. |
| `test-command` | `vendor/bin/phpunit` | Test command. |

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

Secret **`PROJECT_TOKEN`**: a *classic* personal access token with the **`project`** scope
(`https://github.com/settings/tokens/new?scopes=project,repo&description=gws-board-sync`). The default
`GITHUB_TOKEN` cannot reach a user-owned board, and fine-grained tokens do not support them.
For **private repositories** the token also needs **`repo`**: with `project` alone GitHub answers
`Could not resolve to a node with the global id` because the token cannot see the issue. (A
public-only setup can stay on `project`.) Use a 1-year expiry and keep the token only in the
secrets of the repos that call this workflow; only the `Move cards` job reads it. Without the
secret the workflow prints a notice and stays green.
Columns are found by name (emoji ignored): In review, Ready to ship (or Ready for Testing),
Staging / QA (or Staging), Done.

For a repo that deploys, call it from the deploy workflow so a card moves only after the deploy
succeeded (`needs: deploy`), and add a small `board.yml` for the PR events:

```yaml
# deploy workflow (push to staging / main)
  board:
    needs: deploy
    permissions: { contents: read, issues: read, pull-requests: read }
    uses: givanov95/ci-workflows/.github/workflows/board-sync.yml@v1
    with: { project-number: 6 }            # staging-environment: true if it has one
    secrets: { PROJECT_TOKEN: "${{ secrets.PROJECT_TOKEN }}" }
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
    uses: givanov95/ci-workflows/.github/workflows/board-sync.yml@v1
    with: { project-number: 6 }
    secrets: { PROJECT_TOKEN: "${{ secrets.PROJECT_TOKEN }}" }
```

A repo with no deploy (a package) can skip the deploy workflow and add `push: branches: [main]` to
`board.yml` instead.

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

## Versioning

Reference a major tag and it tracks the latest compatible release:

- `@v1` — moving major tag (recommended for convenience).
- `@v1.2.3` — exact release (more reproducible).
- `@<sha>` — pinned commit (most secure).

When this repo is **public**, any repo can call its workflows. If you ever make it private,
enable *Settings → Actions → Access* on this repo to allow your other repos to use it.

## Which workflow per project

| Type | Workflow | Examples |
| --- | --- | --- |
| Laravel app | `laravel-app.yml` | gwebsolutions, slavelia, task, laravel-shop, laravel-starter* |
| PHP package | `php-package.yml` | laravel-translations, laravel-attachments, laravel-data-table, typed-http, laravel-git-hooks |

## License

MIT © Georgi Ivanov
