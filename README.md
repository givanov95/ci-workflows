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
