# Vendored AssetKit

Upstream: <https://github.com/xtool-org/AssetKit>, tag `1.0.0` plus its single
later commit `e763558` ("ci: bump to Swift 6.3 toolchain and Xcode 26.4").
Copied here unmodified except for the patches listed below, so the diff against
upstream stays reviewable. Upstream is MIT (see `LICENSE`), and the vendored
`Sources/CLZFSE` is Apple's reference LZFSE encoder under its own BSD licence
(see `Sources/CLZFSE/LICENSE`).

## Why it is vendored

Upstream cannot express a dark app-icon appearance, so a
`{"appearances": [{"appearance": "luminosity", "value": "dark"}]}` entry in an
`.appiconset` did not become a dark variant of the icon:

- `Sources/AssetKit/Schema/Contents.swift` — `AppIconContents.Image` had no
  `appearances` field at all, while `ImageSetContents.Image` and
  `ColorSetContents.ColorEntry` both had one.
- `Sources/AssetKit/AppIcon/AppIconPlist.swift` — `IconFile` had no appearance,
  so `Sources/AssetKit/Rendition/ImageRenderer.swift` had to pass
  `appearance: nil` for every app-icon file.
- `Sources/AssetKit/XCAssetCompiler.swift` — the loose-PNG loop emitted one file
  per `IconFile`, so a light and a dark entry for the same slot resolved to the
  same output name and the last one written won.

Confirmed against upstream `main` as well, not just the tag: compiling the same
catalog with the unpatched library and with `main` produced byte-identical
`Assets.car` output. There are no other branches, tags or releases, and no
open issue or PR about appearances.

## Patches

1. `Schema/Contents.swift` — added `appearances` to `AppIconContents.Image`,
   mirroring `ImageSetContents.Image` including an explicit `CodingKeys`.
2. `AppIcon/AppIconPlist.swift` — `IconFile.appearance`, filled from
   `image.appearances?.first { $0.darkLuminosity }`. Only base-appearance files
   are added to `CFBundleIconFiles`, since a dark entry resolves to the same
   bundle name and a loose PNG slot holds exactly one image.
3. `Rendition/ImageRenderer.swift` — `appIconRenditions` passes
   `appearance: file.appearance` instead of `nil`. This is the change that
   matters: `PNGSource.renditions` already keys a rendition on
   `context.assetName` plus `context.appearance`, so both variants now register
   under the single asset name `AppIcon` and CoreUI can pick between them by
   luminosity.
4. `XCAssetCompiler.swift` — the loose-PNG loop skips non-base appearances, so
   the bundle-root fallback holds the base artwork, which is what actool writes.
5. `XCAssetCompiler.swift` — added `renditionReport(catalog:)` and
   `RenditionReport`. `Assets.car` is LZFSE-compressed, so there is no way to
   read an appearance facet back out of the compiled bytes on Linux without a
   decoder; this reports the table that went *into* the CAR so
   `tools/assetkit-cli --dump-renditions` can assert the pairing. It does not
   affect the produced bytes.

## Removed

`Tests/` is deleted. Its fixture catalog
(`Tests/AssetKitTests/Fixtures/Test.xcassets`) made xtool try to compile assets
on every build: xtool walks the project tree, and the launch then failed because
it cannot execute actool on Linux. Nothing in the build uses those tests, and
`.build/checkouts/AssetKit/Tests/...` — which SwiftPM recreates on every
resolve — is not picked up, so removing the source tree is enough.

To move to a future upstream release, drop this directory, point
`tools/assetkit-cli/Package.swift` back at the remote, and re-run
`tools/assetkit-cli/.build/release/assetkit-cli --dump-renditions` over
`layout/Applications/GoldenNuggetMobile.app/Assets.xcassets`: the output must
show one asset name with a base and a `luminosity=dark` rendition for every slot.
