# Cutting a release

Maintainer runbook for tagging a `lariat-server` release and publishing its source tarball, per `Documentation/release-target-plan.md`'s build-from-source distribution model. Not needed by anyone just building/running this project — see the root [`README.md`](../README.md) for that.

## Prerequisite — pushed to GitHub

`taplin/Lariat` is public and live, matching every sibling Perfect-Resurrection library. `origin` is already configured; `main` is pushed and tracked.

## Version scheme

`vMAJOR.MINOR.PATCH`, starting at `v0.1.0` — matches this project's own consistently honest "early, functional, not yet battle-hardened" framing (see the root README). Check what's already tagged before picking the next version:

```bash
git tag -l 'v*' | sort -V | tail -5
# once the repo is on GitHub:
gh release list --repo taplin/Lariat
```

## Pre-flight checks (every time, before tagging)

This repo has no CI yet, so these are the only verification gate — don't skip them:

1. **Clean, on `main`**: `git status --short` empty, `git branch --show-current` is `main`.
2. **Build and test pass locally**:
   ```bash
   swift build
   swift test
   ```
3. **`Package.resolved` reflects the dependency state you actually want pinned.** This matters more here than in most repos: several dependencies (`Perfect-CRUD`, `Perfect-MySQL`, `Perfect-NIO`, `Perfect-Session`, `Perfect-FileMaker`, `Perfect-FileMaker-AdminAPI`) are declared as `branch: "main"` in `Package.swift` — it's the *committed* `Package.resolved` entry, not whatever those siblings' `main` branches have moved to since, that a source tarball built later will actually use. Decide whether you want this release pinned to what's already committed, or to pick up each sibling's latest:
   ```bash
   swift package resolve   # updates Package.resolved to each dependency's current branch tip
   git diff Package.resolved
   ```
   Review the diff (if any), and commit it *before* tagging — a release should never be tagged with an uncommitted or accidental `Package.resolved` change.
4. **A standalone-clone build check** — this is the exact class of "only works because of my local checkout" mistake the whole build-from-source effort exists to avoid, so verify it directly rather than trusting the working copy you've been developing in:
   ```bash
   rm -rf /tmp/release-verify && git clone --no-local . /tmp/release-verify
   cd /tmp/release-verify && git checkout main
   swift build -c release --product lariat-server
   ```
   (`--no-local` forces a real clone over the git protocol layer even for a local path, rather than a hardlink-optimized copy that could hide a real remote-fetch issue.)
5. **Review documentation, not just code — before tagging, not after.** Read this repo's own `README.md` top-to-bottom and confirm it's still accurate against what's actually shipping (version/feature claims, platform requirements, anything this release's commits changed). If this release touched or bumped a dependency (a `branch: "main"`-tracked sibling in `Package.swift`), skim that sibling's own `README.md` too for claims that might now be stale (a deployment-target bump, a new capability, a removed one) — dependency repos drift silently since their own doc updates don't show up in this repo's diff. **Why this is here**: `v0.2.1` (2026-07-23) was an entire extra release cut solely to fix a README that had been stale since before `v0.2.0`, plus a docs-only pointer this repo's own README should have gotten in `v0.2.0` in the first place — both were catchable in one pre-flight read, and doing that read one release earlier would have meant one release instead of two.

## Cutting the tag and release

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
gh release create v0.1.0 --generate-notes
```

`--generate-notes` drafts release notes from commits since the previous tag (or the repo's start, for the first release) — read them before publishing; edit if the auto-generated summary is misleading (`gh release edit v0.1.0` opens it in your editor, or use the GitHub web UI).

GitHub automatically attaches "Source code (zip)" and "Source code (tar.gz)" archives to every Release — no separate packaging or upload step is needed for these; that's the whole benefit of the build-from-source model over a pre-built-binary one (see `release-target-plan.md` §2 for why pre-built binaries were investigated and set aside).

## Post-release verification — don't skip this either

Download the actual tarball GitHub just generated (not just re-clone `main`, which isn't necessarily the same content once further commits land) and confirm it builds and runs standalone — this is the literal artifact a user will download, so it's the one that needs verifying directly:

```bash
curl -L -o release-check.tar.gz "https://github.com/taplin/Lariat/archive/refs/tags/v0.1.0.tar.gz"
mkdir release-check && tar -xzf release-check.tar.gz -C release-check --strip-components=1
cd release-check
swift build -c release --product lariat-server
LASSO_SITE_ROOT=/path/to/a/scratch/site \
"$(swift build -c release --show-bin-path)/lariat-server"   # confirm it actually starts and serves a request
```

## If something's wrong after publishing

Prefer a new patch release (`v0.1.1`) over rewriting an already-public tag — someone may already have pulled it. If a release genuinely needs to be pulled (e.g. it doesn't build at all):

```bash
gh release delete v0.1.0 --yes
git push origin :refs/tags/v0.1.0
git tag -d v0.1.0
```

## Changelog

One line per tag, most recent first — full details live in each tag's own GitHub release notes
(`gh release view vX.Y.Z`), this is just a scannable index. Add an entry here as part of cutting
each release, not after the fact.

- **`v0.3.0`** (2026-07-29) — `&&`/`||` are now value-preserving matching real Lasso semantics
  (previously always collapsed to boolean), fixing a real corpus bug where
  `dsinfo->extend(:#rest || staticarray)` silently dropped search criteria. New language support:
  colon-splat call arguments, type reopening (`define ExistingType->method`), a distinct `keyword`
  value type, `delve()`, `dsinfo->inputcolumns` search-criteria translation, `->asstaticarray`.
  Admin console Phase 6: real crawl-report wiring, job history, alert tags. Picks up Perfect-XML's
  and Perfect-NIO's matching macOS libxml2/zlib pkg-config collision fixes. 1128/1128 tests pass on
  both macOS and Linux (`perfect-ci` container).
- **`v0.2.3`** (2026-07-27) — dependency-only patch, no Lariat source changes. Pulls in
  Perfect-CRUD's ADR-0001 connection pooling (`DatabaseConnectionPool`) and async execution
  boundary, plus its `CRUDTableStructure()` visibility fix (was `internal`, broke every host
  module's documented `AdminConsoleDelegate.registeredModels()` implementation); Perfect-NIO's
  matching pool-based `Routes.db(pool:)`/`.table(pool:)` overloads and admin-console model-schema
  browser slice; Perfect-MySQL's and Perfect-FileMaker-AdminAPI's own latest `main`.
- **`v0.2.2`** (2026-07-26) — Linux support fully working, not in-progress. 1110/1110 tests pass on
  both macOS and Linux from a clean rebuild; closed the three Linux gaps deferred since `v0.2.0`
  plus a first-ever `lariat-server` executable build/test pass on Linux, which turned up
  several more fixes and one real (not Linux-specific) cross-platform bug in `LassoFileSystemIncludeLoader`.
- **`v0.2.1-legacy10.15`** (2026-07-24, prerelease) — legacy macOS 10.15/11 build attempt,
  concluded and not recommended for use: a `libmysqlclient` symbol 10.15/11's system `libc++`
  doesn't export is a full launch blocker, on top of an already-known `URLSession.data(for:)` gap.
  Native support for that hardware tier isn't being pursued further; see the root README's
  Requirements section for the recommended OpenCore Legacy Patcher path instead.
- **`v0.2.1`** (2026-07-23) — docs-only patch, no code changes. Fixed a README stale since before
  `v0.2.0` (missing release pointer, missing macOS-only validation note) plus a same-day fix to
  `Perfect-FileMaker-AdminAPI`'s own README (a stale `macOS 26+` claim after its deployment target
  had already been lowered to 14.0).
- **`v0.2.0`** (2026-07-23) — the legacy `ds()` datasource API (classic `ds()->database()->sql()->rows`
  object API) now works end-to-end against real third-party corpus code; read path only
  (`add`/`update`/`delete`/`execsql` on the `mysqlds` connector intentionally out of scope). Plus
  new language support additions — see the tag's own release notes for the full list.
- **`v0.1.0`** (2026-07-22) — initial tagged release.
