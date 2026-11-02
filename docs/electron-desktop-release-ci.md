# Electron Windows release candidate

`.github/workflows/electron-desktop-release.yml` is manual-only. It builds the
private Electron application on a fresh GitHub-hosted Windows x64 runner using
Node.js 22 and .NET SDK 10. It never publishes a release, changes a feed, signs in
to a product account, or requests a signing key.

## Inputs and private source

- `source_tag`: a `qa-*` tag in this repository whose release is still a draft
  with no publication date. The source draft must never be published.
- `source_asset`: the exact plain filename of a ZIP created with
  `git archive --format=zip <commit>`, with `package.json` at its root.
- `source_sha256`: the archive's independently recorded 64-digit SHA-256.

The source ZIP is limited to 512 MiB compressed / 1 GiB expanded and 50,000
entries. Its commit comment must be intact. Duplicate paths, traversal, links
and reparse points are rejected before extraction. Source files and detailed
command output stay under `RUNNER_TEMP` and are removed at job cleanup. No
private repository token is needed. Draft release visibility requires push
access, so this job overrides the workflow's read-only default with
`contents: write` for its temporary `GITHUB_TOKEN`. The token is passed as
`GH_TOKEN` only to the source restoration step. Checkout uses
`persist-credentials: false`, and npm/native build steps receive no token
environment variable or persisted checkout credential. The job has no release
publication or repository mutation command.
Draft lookup uses `gh release view` to resolve a numeric release API URL, validates
its repository path, then checks the draft and publication fields through REST.

The source must define `release:desktop`. The runner exposes the git archive's
commit as `FOCOACH_SOURCE_COMMIT` for build provenance.

## Build and output contract

The job runs, in order:

1. `npm ci --no-audit --no-fund`
2. `npm test`
3. `native/windows/Build.ps1 -CheckPrivateDesktop`
4. `npm run package:win` (including the native broker build)
5. `npm run check:package`
6. `npm run release:desktop -- win32 x64`
7. `node scripts/check-update-package.cjs`

The release script must use the already-packaged
`dist/FoCoach Electron-win32-x64` and produce an NSIS setup, ZIP and
`latest.yml` in `dist/releases/win32-x64`. The update-package check must install
the NSIS setup only into its own temporary directory and launch it with
temporary product data, then verify ASAR, version, updater and feed state.

Artifact `electron-win-x64-release` contains:

- `releases/win32-x64/`: top-level distributables and release metadata only.
  Unpacked application directories and `builder-*` diagnostics are excluded.
- `verification/`: frozen source identifiers, step status/exit codes, numeric
  Node test summary and SHA-256/size inventory for each distributable.
  `source-restore.json` records only success, a fixed restoration stage
  (`lookup`, `download`, `hash`, `archive`, `extract` or `package`), a fixed
  failure code and an allowlisted exception type. Build failures record their
  fixed step name, failure code and exception type. Failed Node tests may also
  include at most 30 bounded TAP `not ok` lines or error codes; stack traces
  and unrelated command output remain private.
  Failed Node tests additionally produce `failed-tests.txt` with bounded TAP
  diagnostic fields (`message`, `error`, `failureType`, `code`, `name`,
  `operator`, `expected` and `actual`). Each failure is limited to 80 lines and
  the report to 64 KiB; fields are limited to 12 lines and individual lines to
  1,024 characters. Stack/source fields and all unrelated command output are
  excluded. These assertions run only against isolated test fixtures.

On failure, only sanitized verification is uploaded. Detailed errors, source
archives and extracted source are never uploaded to the public artifact.
Artifacts expire after seven days. Only this Windows job has `contents: write`
to read the draft; the workflow has no release upload, publication or workflow
dispatch step.
