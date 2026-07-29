# Build failure: conflicting libxml2 declarations on recent macOS

**Status: fixed at the source.** As of the fix described below, `Perfect-XML`'s
`libxml2` system-library target no longer consults `pkg-config` on macOS at
all, so this collision can no longer happen there regardless of what's
installed via Homebrew — no manual remedy is needed on a fresh clone that
picks up the fix. The manual remedies further down remain useful if you're
pinned to an older `Perfect-XML` commit that predates it, or for the
equivalent Linux case where `pkg-config` is still genuinely required.

The same collision applied to `zlib` (Perfect-NIO's `CZlib` target, also
bundled directly by recent SDKs) and got the identical fix there — see
[`Perfect-NIO` PR #2](https://github.com/taplin/Perfect-NIO/pull/2).

**Symptom**: `swift build`/`swift run` fails while building the `libxml2`
system-library module (pulled in transitively via `Perfect-XML` →
`Perfect-FileMaker`), with errors like:

```
error: expected ';' after top level declarator
XMLPUBVAR xmlMallocFunc xmlMalloc LIBXML_API_DEPRECATED_MEMORY_ALLOCATION_FUNCTIONS;

error: conflicting types for '__oldXMLWDcompatibility'
error: conflicting types for '__xmlDefaultSAXHandler'
error: could not build module 'libxml2'
```

with notes pointing at TWO different `libxml2` header locations in the
same build — one under
`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/libxml2/`
(Apple's own bundled copy) and one under something like
`/usr/local/opt/libxml2/include/libxml2/` (a Homebrew-installed copy).

## Root cause

Recent macOS/Xcode Command Line Tools SDKs (observed starting around the
macOS 26.x line) now bundle their own copy of libxml2's headers directly
in the SDK. If a Homebrew-installed `libxml2` is **also** present and
visible to the build (most commonly because its `pkgconfig` directory is
on `PKG_CONFIG_PATH`, often added automatically by Homebrew's own
post-install instructions when `libxml2` was installed for some other,
unrelated project), Clang's module system ends up mixing declarations
from both copies in the same module build. A handful of deprecated
libxml2 symbols (`__oldXMLWDcompatibility`, `__xmlDefaultSAXHandler`,
`__xmlDefaultSAXLocator`, `__xmlParserDebugEntities`,
`__xmlParserVersion`) are declared slightly differently between the two
versions, producing the "conflicting types" errors above.

**This is an environment/toolchain collision, not a Perfect-Lasso or
Perfect-XML code issue.** Confirmed by:

- Diffing the exact `Perfect-XML` commit pinned by the `v0.2.1` release's
  `Package.resolved` against current `main` — the `libxml2` wrapper
  (`Sources/libxml2/libxml2.h`, `module.modulemap`, and the
  `.systemLibrary` target in `Package.swift`) is byte-for-byte identical
  between them. Nothing has changed there.
- A machine with **no** Homebrew `libxml2` installed at all builds clean
  against the SDK's bundled copy alone, with zero extra flags — exactly
  what this project's own README already says should happen ("`libxml2`
  and `zlib`... resolve against macOS's own system copies automatically;
  you don't need to install anything for them").

## Fix

### Structural fix (upstream, in Perfect-XML)

`Perfect-XML`'s `libxml2` system-library target (`Sources/libxml2` in
[`Perfect-XML`](https://github.com/taplin/Perfect-XML)) now omits
`pkgConfig` entirely on macOS. Verified empirically: with a synthetic
competing `libxml-2.0.pc` on `PKG_CONFIG_PATH`, the pre-fix manifest passed
its `-I` path straight into the module compile (`swift build -v` shows
`-I/.../include/libxml2` from the fake prefix); the fixed manifest never
does, on any macOS machine, regardless of what Homebrew has installed.
`pkg-config` + the `apt` provider is retained on Linux, where there's no
SDK-bundled copy and it's genuinely required.

Picking up the fix just requires `Perfect-XML` resolving to a commit at or
after it (all these dependencies track `branch: "main"`, so `swift package
update` is enough — no version bump needed). No Homebrew uninstall, no
`PKG_CONFIG_PATH` surgery, no wrapper scripts required.

### Manual remedies (for pre-fix commits, or the Linux-equivalent case)

Homebrew's `libxml2` is genuinely not needed to build Perfect-Lasso — the
SDK's own bundled copy is sufficient. The safest fix removes the
collision without disturbing anything else `PKG_CONFIG_PATH` is used for
(notably `mysql-client`, which Perfect-Lasso's `Perfect-MySQL` dependency
**does** need resolved via `pkg-config` — do not blank out
`PKG_CONFIG_PATH` entirely, that trades this failure for a `mysqlclient`
resolution failure instead).

**Option 1 — uninstall Homebrew's `libxml2`, if nothing else needs it:**

```bash
brew uses --installed libxml2
```

If that comes back empty (nothing else on your machine depends on it):

```bash
brew uninstall libxml2
```

**Option 2 — keep it installed, but exclude it from `PKG_CONFIG_PATH` just
for this build** (use this if something else on your machine genuinely
needs the Homebrew `libxml2`):

```bash
# Strip libxml2's pkgconfig directory out of PKG_CONFIG_PATH for this
# command only -- everything else already on the path (e.g. mysql-client's
# entry) is preserved unchanged.
PKG_CONFIG_PATH="$(echo "$PKG_CONFIG_PATH" | tr ':' '\n' | grep -v "$(brew --prefix libxml2)" | paste -sd: -)" \
  swift build -c release --product lasso-perfect-server
```

Repeat the same `PKG_CONFIG_PATH="..." ` prefix for `swift test`/`swift
run` if needed. If you do this often, wrap it in a shell function or
alias scoped to this project rather than editing `PKG_CONFIG_PATH`
globally in your shell profile — a global edit would also hide Homebrew's
`libxml2` from any other project on the same machine that legitimately
wants the newer version.

## Why not just clear `PKG_CONFIG_PATH` entirely?

`Perfect-MySQL`'s `Package.swift` also resolves `libmysqlclient` via
`.systemLibrary(pkgConfig: "mysqlclient", providers: [.brew(["mysql-client"])])`
— genuinely needed, per this README's own Requirements section. Blanking
`PKG_CONFIG_PATH` entirely would fix the libxml2 collision by breaking
mysql-client resolution instead. Option 2 above only removes libxml2's
entry, leaving mysql-client's intact.
