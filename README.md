# GoldenNugget (Mobile)
Unlock your device fullest potential without pc!
# Quick start
1st Grab latest release\
2nd install localdevvpn from app store\
3rd Disable Find My\
and 4 sideload programm via: Livecontainer, Alt/SideStore or ILoader

# Building

The app binary is `GoldenNuggetMobile`, and `CFBundleExecutable` in
`layout/Applications/GoldenNuggetMobile.app/Info.plist` has to agree with the
SwiftPM product name in `Package.swift` — a mismatch fails the xtool build at
the signing step with `Can't parse BundleExecute file!`.

xtool (works on Linux and macOS, driven by `xtool.yml`):

```sh
xtool dev build -c release -i     # -> xtool/GoldenNuggetMobile.ipa
```

Xcode (macOS only, driven by `GoldenNuggetMobile.xcodeproj`):

```sh
scripts/build-ipa.sh Release      # -> build/GoldenNuggetMobile.ipa (unsigned)
```

Source layout and the conventions that matter live in
`Nugget/Core/GoldenNuggetEngine.swift`.

`Package.swift` is the single source of truth for which files the
`GoldenNuggetMobile` target compiles. After adding or removing a file under
`Nugget/`, reconcile the Xcode project:

```sh
scripts/sync-pbxproj-sources.py           # rewrite project.pbxproj
scripts/sync-pbxproj-sources.py --check   # report drift, change nothing
scripts/typecheck.sh                      # swiftc gate, 0 errors to pass
```

That script reconciles **sources only**. A SwiftPM *product* the app depends on
(`.product(name:package:)` in `Package.swift`) has to be mirrored by hand in
`project.yml` **and** in `project.pbxproj` (`packageProductDependencies` plus a
`XCSwiftPackageProductDependency` object) — XcodeGen is not installed here, so
`project.pbxproj` cannot be regenerated from `project.yml` and the three files
have to agree. The app depends on two products of the vendored package today:
`Minimuxer` and `ZIPFoundation` (the latter for `.tendies` packs, which are ZIPs).

Both scripts take the source list from `swift package describe`, so they cannot
disagree about what is in the target.
