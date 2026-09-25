# GoldenNugget (Mobile)
Unlock your device fullest potential without pc!
# Quick start
1st Grab latest release\
2nd install localdevvpn from app store\
3rd Disable Find My\
and 4 sideload programm via: Livecontainer, Alt/SideStore or ILoader

# Building

```sh
scripts/build-ipa.sh Release      # -> build/PoC.ipa (unsigned)
```

Source layout and the conventions that matter live in `Nugget/Core/PoCEngine.swift`.

`Package.swift` is the single source of truth for which files the `PoC` target
compiles. After adding or removing a file under `Nugget/`, reconcile the Xcode
project:

```sh
scripts/sync-pbxproj-sources.py           # rewrite project.pbxproj
scripts/sync-pbxproj-sources.py --check   # report drift, change nothing
scripts/typecheck.sh                      # swiftc gate, 0 errors to pass
```

Both scripts take the source list from `swift package describe`, so they cannot
disagree about what is in the target.
