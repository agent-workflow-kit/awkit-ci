# CLAUDE.md

Instructions for Claude sessions working on awkit-ci, the shared CI of the
agent-workflow-kit repositories. Read [README.md](README.md) first. The process it
implements is in `awkit-docs`: architecture sections 18.3 and 18.6 to 18.8, design
guide sections 13 to 17.

## Open-source rule

Everything here is public. Never add company names, internal hosts, project keys,
people's names or private tool names, in files, commit messages, PR titles or comments.

## Rules for workflows

- Every third-party action is pinned by its full 40-character commit SHA with a
  `# vX.Y.Z` comment. Never use a tag or branch ref. Look SHAs up with
  `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` (dereference annotated tags via
  `gh api repos/<owner>/<repo>/git/tags/<sha>`). Prefer releases at least a week old.
- Tools run in workflows (zizmor, actionlint, pymarkdownlnt, check-jsonschema,
  shellcheck, lychee) are pinned to exact versions; downloaded binaries are also
  checked against a SHA-256.
- Every job sets minimal `permissions:` (default `contents: read`); checkouts use
  `persist-credentials: false`.
- No `${{ }}` expressions inside `run:` scripts; pass values through `env:`.
- `make verify` must pass: actionlint, zizmor, pymarkdown, shellcheck and
  check-jsonschema all clean. A zizmor finding may only be suppressed with an inline
  `# zizmor: ignore[<rule>] <reason>` that explains why it is acceptable.
- Workflow names, job names, inputs and secrets are an interface. The required checks
  `ci / ci-ok` and `pr-title / pr-title` must keep their names. Changing an input,
  secret, check name or required permission is a breaking interface change and needs
  matching updates to `templates/` and the README.
- A breaking interface change is, before 1.0, a `feat` commit whose title names the break (never `!` before 1.0), and from 1.0 on a `!` commit; the title becomes the changelog line (details go in the PR body). awkit-ci is not in the interface registry: callers reference awkit-ci by tag and Dependabot bumps them. Never hand-edit CHANGELOG.md or the version.
- `templates/` must stay in sync with the caller files in the other repos.
- `scorecard.yml` must keep to the Scorecard workflow restrictions (see README).

## Workflow

- Work in a git worktree on a branch named `<type>/<short-slug>`, never in the main
  checkout (design guide section 17).
- PR titles are Conventional Commit headers; they become the squash commit, the version
  bump and the changelog line (architecture section 18.3). Do not use `!` before 1.0 (a breaking change before then is a `feat` whose title names the break).
- Never use `--no-verify`. Check PR titles, bodies and comments with `guard text` where
  the private-content guard is installed (architecture section 18.7).
- Never merge a PR without the maintainer's explicit instruction for that PR; merges go
  through `scripts/pr-merge` (architecture section 18.6).
- Never hand-edit `CHANGELOG.md` or the version in `pyproject.toml`; the release job
  owns them.
