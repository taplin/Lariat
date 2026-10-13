# Lariat

A Swift reimplementation of the Lasso web-scripting language and server (`lariat-server`) — still in active development and not yet production-ready, though validated against real code from multiple production e-commerce sites.

> **Formerly `Perfect-Lasso`.** The project was renamed to Lariat in October 2026. GitHub redirects the old `taplin/Perfect-Lasso` URL here, so existing clones and links keep working, and the `v0.1.0`–`v0.3.0` tags are unchanged.

This repo has no pre-built binary releases yet — you build it from source, against your own toolchain and Homebrew setup. That turns out to be simple: builds are proven to work from a completely standalone clone, with no other repos or sibling checkouts required nearby.

## Releases

See the [GitHub Releases page](https://github.com/taplin/Lariat/releases) for what's changed in each version. As of this release, both **macOS and Linux** are fully validated — build and the complete 1110-test suite pass clean on both, verified from a clean rebuild in a Linux container. The three Lariat-internal Linux gaps and one real cross-platform bug found along the way are documented in the release notes.

## Trying it against your own site

If you have an existing Lasso site and are curious how much of it this server already handles, the best way to find out is to actually point it at your own code and see what breaks — that's exactly how this project has been developed and tested so far. If you hit something that doesn't render correctly, crashes, or is simply unimplemented, please [open an issue](https://github.com/taplin/Lariat/issues) with what you found — real-world Lasso source is what this project improves against, and reports of what's still fragile or missing are the most useful thing you can contribute right now.

## Requirements

- **Xcode 27 or later** (Swift 6.4 toolchain, confirmed working). `Package.swift` declares a `swift-tools-version: 6.2` minimum, but only Xcode 27 has been verified.
- **macOS 12.0 (Monterey) or later at runtime**, on either Apple Silicon or Intel. `Package.swift` declares this as the deployment target across the whole dependency graph; Intel support has been verified via real cross-compilation (`swift build --triple x86_64-apple-macosx12.0`), not just assumed from the code. See [`Documentation/macos-deployment-targets.md`](Documentation/macos-deployment-targets.md) for the full findings. If you're on older Intel hardware Apple no longer supports past macOS 10.15/11, native support for that was attempted and set aside as too much ongoing maintenance burden for one hardware tier — see that document's Verdict section. The recommended path there is [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher) to get the machine onto 12.0+, where this project already just works.
- **[Homebrew](https://brew.sh)**, with one formula installed:

  ```bash
  brew install mysql-client
  ```

  That's the only Homebrew package this needs. `libxml2` and `zlib` — the other two C libraries this project links against — resolve against macOS's own system copies automatically; you don't need to install anything for them, and having either one *also* installed via Homebrew for an unrelated project is fine too — both dependencies (`Perfect-XML`, `Perfect-NIO`) skip `pkg-config` for these on macOS specifically so a Homebrew copy can never collide with the SDK's own bundled headers. (Older pins predating that fix could still hit a "conflicting types" build failure — see [`Documentation/libxml2-pkgconfig-collision.md`](Documentation/libxml2-pkgconfig-collision.md) if you ever do.)

## Build

```bash
git clone https://github.com/taplin/Lariat.git
cd Lariat
swift build -c release --product lariat-server
```

The built binary's exact location varies by SwiftPM version — always ask it directly rather than assuming a path:

```bash
swift build -c release --show-bin-path
```

## Run

At minimum, `lariat-server` needs to know what directory to serve:

```bash
LASSO_SITE_ROOT=/path/to/your/lasso/site \
"$(swift build -c release --show-bin-path)/lariat-server"
```

It starts listening on `http://localhost:8181` by default and prints a short startup banner confirming the site root, port, and which optional subsystems (datasources, sessions, admin console) are active.

## Configuration

Everything is environment-variable- or config-file-driven — no source edits, no compiled-in paths. The full reference, including:

- `LASSO_SERVER_PORT`, `LASSO_RENDER_EXTENSIONS`, `LASSO_STARTUP_PATH`
- `LASSO_DATASOURCE_CONFIG_PATH` — a JSON file for MySQL/FileMaker datasource aliases, credentials, and SMTP relay/DKIM settings (recommended over passing credentials as bare env vars)
- crawl-report and sitemap-discovery options

is documented in [`Documentation/lariat-server.md`](Documentation/lariat-server.md)'s "Configuration" section.

For the optional browser-based operations dashboard (live datasource switching, log tailing, zero-downtime restart), see [`Documentation/admin-console.md`](Documentation/admin-console.md).

**One startup requirement worth knowing up front**: if you configure SMTP with DKIM signing, the server does a hard (not just a warning) permission check on the DKIM private key file at startup — it refuses to boot if that file is group- or world-readable. `chmod 600` it first.

## Using a specific release instead of `main`

`main` moves — if you'd rather build against a stable, known-working snapshot, check the [Releases page](https://github.com/taplin/Lariat/releases) for a tagged version and either:

```bash
git clone --branch vX.Y.Z https://github.com/taplin/Lariat.git
```

or download that tag's "Source code" archive directly from its Release page, unpack it, and build the same way as above. Each tagged release commits a known-good `Package.resolved`, so you get the exact dependency versions that were verified working at that point — not whatever the tracked `main` branches of this project's dependencies have drifted to since.

(Maintainers: see [`Documentation/releasing.md`](Documentation/releasing.md) for the release-cutting process itself.)
