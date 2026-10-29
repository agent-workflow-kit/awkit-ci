# awkit-ci

Shared CI for the [agent-workflow-kit](https://github.com/agent-workflow-kit) repositories:
reusable GitHub Actions workflows, the thin caller files every repo copies, and the
`pr-merge` helper the maintainer uses to merge pull requests.

It implements the process in architecture sections 18.3 and 18.6 to 18.8 and design
guide sections 13 to 17 (in `awkit-docs`): Conventional Commit PR titles, squash-only
merges, automatic releases with python-semantic-release, and hardened CI where every
third-party action is pinned by commit SHA.

## Contents

| Path | Purpose |
|---|---|
| `.github/workflows/python-ci.yml` | Reusable CI for the Python tool repos |
| `.github/workflows/docs-ci.yml` | Reusable CI for `awkit-docs` (and for awkit-ci itself) |
| `.github/workflows/pr-title.yml` | Reusable Conventional Commit PR-title check |
| `.github/workflows/release.yml` | Reusable release job (python-semantic-release) |
| `.github/workflows/scorecard.yml` | Reusable OpenSSF Scorecard analysis |
| `.github/workflows/self-*.yml` | awkit-ci's own CI, PR-title check and release |
| `templates/` | Caller files copied into every repo (see [Caller files](#caller-files)) |
| `scripts/pr-merge` | Guard-check, wait for checks, then squash-merge a PR |
| `.pymarkdown.json` | Shared markdown lint configuration (identical in every repo; YAML front matter enabled for skill files) |
| `.psr-templates/CHANGELOG.md.j2` | python-semantic-release changelog template (one line per commit title) |

## Reusable workflows

All reusable workflows are `on: workflow_call`, run on `ubuntu-latest`, default every
job to `contents: read` (or less), and check out with `persist-credentials: false`.

### python-ci.yml

Called by the `ci` job of each Python repo.

| Input | Type | Default | Meaning |
|---|---|---|---|
| `python-versions` | string (JSON array) | `'["3.12","3.13"]'` | Python versions for the `verify` matrix |
| `link-excludes` | string (newline-separated regexes) | localhost and `https://github.com/agent-workflow-kit/` | Extra lychee excludes |

No secrets. Jobs:

| Job | What it does | Runs when |
|---|---|---|
| `changes` | Decides whether the change is docs-only (every changed file is `*.md` or under `docs/`) | always |
| `verify` | `uv sync --python <version>` then `make verify`, per matrix version | code changed |
| `schemas` | Every `schemas/**/*.json` declares and is a valid draft 2020-12 schema; `config.example.yaml` validates against `schemas/config.json` (check-jsonschema) | code changed |
| `markdown` | `pymarkdown --config .pymarkdown.json scan -r .` | always |
| `links` | lychee on `**/*.md` | always |
| `dependency-review` | `actions/dependency-review-action` | pull requests only |
| `workflow-lint` | actionlint (release binary, pinned by version and SHA-256) and zizmor (`--format=github`) on `.github/` | always |
| `ci-ok` | Fails if any job above failed or was cancelled (skipped is fine) | always |

`markdown` runs even for docs-only changes because `make verify` (which also lints
markdown) is skipped then.

### docs-ci.yml

Called by the `ci` job of `awkit-docs`, and by awkit-ci's own CI.

| Input | Type | Default | Meaning |
|---|---|---|---|
| `link-excludes` | string | as in python-ci | Extra lychee excludes |
| `extra-workflow-files` | string (space-separated paths or globs) | `""` | Extra workflow files for actionlint and zizmor (awkit-ci passes its `templates/`) |

No secrets. Jobs: `markdown`, `links`, `shell-lint` (shellcheck on `*.sh` and on
shell scripts under `scripts/`), `workflow-lint`, and `ci-ok`.

### pr-title.yml

No inputs, no secrets. Job `pr-title` runs `amannn/action-semantic-pull-request` with
types `feat, fix, perf, chore, refactor, build, docs, test, ci, style`,
`requireScope: false` and `wip: false`. It only reads the PR title through the API and
never checks out PR code, so callers can safely trigger it with `pull_request_target`.

### release.yml

No inputs. Secrets (both required):

| Secret | Caller passes | Meaning |
|---|---|---|
| `app-id` | `${{ secrets.RELEASE_APP_ID }}` | Release GitHub App client ID (the numeric app ID also works) |
| `app-private-key` | `${{ secrets.RELEASE_APP_PRIVATE_KEY }}` | Release GitHub App private key (PEM) |

Job `release` (only on `refs/heads/main`, `concurrency` group per repository, never
cancelled):

1. Mints a token from the release GitHub App with `contents: write`.
2. Checks out full history with that token.
3. Runs `uvx --from "python-semantic-release==10.7.0" semantic-release version` with
   `GH_TOKEN` set to the app token. When the commits since the last tag warrant a
   release, PSR bumps `project.version`, updates `CHANGELOG.md`, runs the repo's
   `build_command`, commits `chore(release): vX.Y.Z` as the app's bot user, tags
   `vX.Y.Z`, pushes and creates the GitHub Release.
4. If a release was made, runs `semantic-release publish --tag vX.Y.Z` to upload
   `dist/*` to that release.

The caller's GITHUB_TOKEN stays read-only; all writes use the app token, and the app is
the only bypass actor of the `main` ruleset.

### scorecard.yml

No inputs, no secrets. Job `scorecard` runs `ossf/scorecard-action` with
`publish_results: true`, keeps the SARIF as an artifact and uploads it to code
scanning. The caller job must grant `contents: read`, `actions: read`,
`security-events: write` and `id-token: write`. The Scorecard API verifies this
workflow file, so it must keep to the
[workflow restrictions](https://github.com/ossf/scorecard-action#workflow-restrictions)
(no top-level `env`/`defaults`, no workflow-level write permissions, only approved
actions in the job).

## Caller files

Copy these from `templates/` into each repo unchanged (except where noted):

| Template | Destination | Notes |
|---|---|---|
| `templates/ci.yml` | `.github/workflows/ci.yml` | Python repos |
| `templates/awkit-docs/ci.yml` | `.github/workflows/ci.yml` | awkit-docs (calls `docs-ci.yml`) |
| `templates/pr-title.yml` | `.github/workflows/pr-title.yml` | every repo |
| `templates/scorecard.yml` | `.github/workflows/scorecard.yml` | every repo |
| `templates/dependabot.yml` | `.github/dependabot.yml` | Python repos (`uv` and `github-actions`) |
| `templates/awkit-docs/dependabot.yml` | `.github/dependabot.yml` | awkit-docs (`github-actions` only) |
| `templates/pull_request_template.md` | `.github/pull_request_template.md` | every repo |
| `.pymarkdown.json` | `.pymarkdown.json` | every repo |

Callers reference the reusable workflows by release tag, for example
`uses: agent-workflow-kit/awkit-ci/.github/workflows/python-ci.yml@v0.1.0`.

The `ci` caller runs on every pull request and on pushes to `main`. A newer push to a
PR cancels the older run; runs on `main` are never cancelled. Its `release` job needs
`ci` and runs only on pushes to `main`.

## Required status checks

Configure these exact names as required checks in each repo's `main` ruleset:

| Repo | Required checks |
|---|---|
| Python repos and awkit-docs | `ci / ci-ok`, `pr-title / pr-title` |
| awkit-ci | `ci / ci-ok`, `pr-title / pr-title` |

`ci-ok` always reports (it runs with `if: always()`), so docs-only changes, which skip
`verify` and `schemas`, still satisfy the ruleset. Do not require the individual jobs.

## Versioning

awkit-ci is released like every other repo: squash-merged Conventional Commit PR titles
drive python-semantic-release (the `release` job in `self-ci.yml`, after CI), which tags `vX.Y.Z`, updates
`CHANGELOG.md` and creates a GitHub Release (no build artifacts). `pyproject.toml` only
carries the version and the PSR configuration; awkit-ci is not a Python package.

- A change that callers must react to (a renamed input, secret or check, a new required
  permission) is a breaking interface change: before 1.0 a `feat` commit whose title
  names the break (never `!` before 1.0), and from 1.0 on a `!` commit; the title
  becomes the changelog line (details go in the PR body). awkit-ci is not in the
  interface registry: callers reference awkit-ci by tag and Dependabot bumps them.
  Never hand-edit `CHANGELOG.md` or the version.
- `CHANGELOG.md` gets one `## vX.Y.Z (date)` section per release with one line per
  commit, the commit title, rendered by `.psr-templates/CHANGELOG.md.j2` (lint-clean;
  PSR's built-in template groups by type and breaks the markdown lint's blank-line
  rules after the second release).
- awkit-ci's own Dependabot updates use `chore(deps)`, so each action-pin bump releases a
  patch that callers then pick up.

## How callers stay current (Dependabot)

Each repo's `.github/dependabot.yml` enables the `github-actions` ecosystem weekly.
Dependabot treats `uses: agent-workflow-kit/awkit-ci/.github/workflows/<file>.yml@vX.Y.Z`
like any action reference: when awkit-ci publishes a newer tag, it opens one grouped PR
(titled `ci(deps): ...`, so it does not trigger a release) bumping every awkit-ci ref
in the repo. A 7-day cooldown delays brand-new versions. Python dependency updates
(`uv` ecosystem) are grouped by dependency type: runtime bumps use `chore(deps): ...`,
which releases a patch; dev-only bumps use `test(deps-dev): ...`, which does not.

## Bootstrap order

The caller workflows cannot run until the refs they use exist, so set things up in
this order:

1. Create the `agent-workflow-kit` org's release GitHub App with repository permission
   **Contents: read and write** (and metadata read), install it on all repos, and add
   two organization secrets available to all repos:
   - `RELEASE_APP_ID`: the app's client ID (or app ID)
   - `RELEASE_APP_PRIVATE_KEY`: a private key generated for the app (PEM)
2. Push awkit-ci and get the tag `v0.1.0`. With the initial commit titled
   `feat: initial scaffold`, the first `release` job run (in `self-ci.yml`) releases `0.0.0` to
   `v0.1.0` (bumping `pyproject.toml` and `CHANGELOG.md`). If the release app is not
   ready yet, tag the commit `v0.1.0` by hand; later tags come from the release job.
   Until `agent-workflow-kit/awkit-ci@v0.1.0` exists, every caller's CI fails to
   resolve its reusable workflows, and zizmor's online audits fail on callers.
3. Push the other repos with their caller files.
4. Configure the `main` ruleset in each repo: PR required, the required checks above,
   no force pushes or deletions, 0 approvals, the release app as the only bypass actor.
   Set merges to squash only with head-branch deletion, and the squash commit message
   to the PR title with a blank body. python-semantic-release reads only the squash
   commit's title (`parse_squash_commits = false`), so the PR title alone decides the
   version bump and the changelog line.

## Merging: scripts/pr-merge

```sh
scripts/pr-merge <repo-dir | owner/repo> <pr-number>
```

1. Resolves `owner/repo` (from a clone or worktree directory, or as given).
2. Runs the local private-content guard, `guard pr <owner/repo> <pr>`: from
   `$AWKIT_GUARD` if set, else `guard` on `PATH`. If a guard is configured and fails
   (or `$AWKIT_GUARD` does not point at an executable) it stops. If none is installed it
   warns and continues. Prefer `AWKIT_GUARD`, since an unrelated program called `guard`
   may be on `PATH`.
3. Waits for every check: `gh pr checks <pr> --watch --fail-fast`.
4. Squash-merges and deletes the branch: `gh pr merge <pr> --squash --delete-branch`,
   only if the PR head is still the commit the guard checked. It never uses `--admin`.

It exits 0 after merging, 1 on any failure, 2 on usage errors. It needs `gh`,
authenticated with permission to merge.

## Local checks

`make verify` runs, through `uvx` at pinned versions: actionlint (with shellcheck) on
`.github/workflows/` and `templates/`, zizmor (offline unless `GH_TOKEN` is set),
pymarkdown, shellcheck on `scripts/`, and check-jsonschema on the workflows (GitHub
workflow schema) and the Dependabot files (Dependabot schema). It needs only
[uv](https://docs.astral.sh/uv/) and `make`.

## License

MIT. See [LICENSE](LICENSE).
