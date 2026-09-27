import Foundation

/// One file to deliver into the backup: the payload and where it belongs.
///
/// The Swift counterpart of the reference's `FileToRestore`, narrowed to the
/// plist-tweak subset this port covers (GoldenNugget also builds
/// `FileToRestore` for posterboard/icon/status-bar assets — those features are
/// not ported).
///
/// Owner/group are deliberately **not** carried here.  The reference stamps
/// every plist tweak with `Tweak.__init__`'s default `owner=501, group=501`,
/// but the device's own rows disagree per domain — the footnote row is `-2/-2`
/// while a `ManagedPreferencesDomain` row is `501/501`.  The row shape is the
/// device's contract, so it lives in `TweakRowProfile` (one place, measured)
/// and the compiler only says *what* to write.
struct TweakPayload: Equatable {
    let domain: String
    let relativePath: String
    let contents: Data

    var label: String { "\(domain)/\(relativePath)" }
}

/// Turns a tweak selection into the files a restore should carry.
///
/// A port of the *compile* half of `device_manager._apply_tweak_pass`
/// (`src/devicemanagement/device_manager.py:900-1024`): start with an empty
/// `FileLocation → plist` table, let every enabled tweak merge its key in, then
/// serialise each location once and map it to a backup domain.
///
/// The merge is the whole point, not an optimisation: all 98 Liquid Glass
/// tweaks write into the same `.GlobalPreferences.plist`, so emitting one file
/// per tweak would leave only the last one standing.
enum TweakCompiler {
    struct Result {
        let payloads: [TweakPayload]
        /// Locations that produced a file, in write order — for the log.
        let locations: [TweakFileLocation]
        /// Things that were switched on but delivered nothing, and why.
        let skipped: [(label: String, reason: String)]
    }

    /// - Parameters:
    ///   - deviceVersion: the device's `ProductVersion`, for the registry's
    ///     `min_version` / `max_version` bounds.  Empty skips those checks, the
    ///     way the reference's `if device_version and spec.min_version` does.
    ///   - isIPhone: `ProductType.hasPrefix("iPhone")`, for `iphone_only` /
    ///     `ipad_only`.
    static func compile(
        selection: TweakSelection,
        deviceVersion: String,
        isIPhone: Bool
    ) -> Result {
        // Insertion-ordered, like Python's dict: the reference iterates
        // `basic_plists.items()` in first-write order and that is the order the
        // files reach the backup.
        var order: [TweakFileLocation] = []
        var plists: [TweakFileLocation: [String: Any]] = [:]
        // Locations to overwrite with a 0-byte file rather than a serialised
        // plist. Upstream's `NullifyFileTweak` does exactly that, and the
        // injector writes `contents` verbatim, so an empty payload is it.
        var nullified: [TweakFileLocation] = []
        var skipped: [(label: String, reason: String)] = []

        // `allWithDaemons`, not `all`: the daemon group specs are not registry
        // rows, and compiling only the registry would drop the launchd
        // `disabled.plist` entirely.
        for spec in TweakCatalog.allWithDaemons where !spec.disabled {
            guard selection.isOn(spec) else { continue }
            guard spec.isCompatible(deviceVersion: deviceVersion, isIPhone: isIPhone) else {
                skipped.append((spec.id, "not compatible with this device / iOS version"))
                continue
            }

            // An `AdvancedPlistTweak` (a spec with a factory) contributes the
            // whole location's dict; the single-key merge below is the other half
            // of the reference's two `apply_tweak` shapes.  The dict comes from
            // the selection so an imported preset's own dict wins over the
            // registry's, exactly as `_apply_tweak` overwrites `tweak.value`.
            //
            // Merged, not assigned. Upstream registers daemons as *one*
            // `AdvancedPlistTweak` whose value holds every label, so a second
            // spec writing the same location has never come up -- until the port
            // modelled one spec per daemon group, all writing
            // `/var/db/com.apple.xpc.launchd/disabled.plist`. Assigning here
            // would leave exactly one group's labels in the file. Key-level
            // precedence is unchanged: a later spec still wins a shared key.
            if spec.writesWholeDict, let multiValues = selection.multiValues(for: spec) {
                if plists[spec.location] == nil { order.append(spec.location) }
                var dict = plists[spec.location] ?? [:]
                for (key, value) in multiValues { dict[key] = value.plistObject }
                plists[spec.location] = dict
                continue
            }

            // `ClearScreenTimeAgentPlist` is a `NullifyFileTweak`: it writes a
            // 0-byte file over the ScreenTime plist instead of serialising one,
            // so it must not fall into the "no plist key" skip below.
            if spec.id == TweakCatalog.screenTimeSpec.id {
                if !nullified.contains(spec.location) { nullified.append(spec.location) }
                if !order.contains(spec.location) { order.append(spec.location) }
                continue
            }

            guard !spec.key.isEmpty else {
                skipped.append((spec.id, "registry entry has no plist key"))
                continue
            }
            if plists[spec.location] == nil { order.append(spec.location) }
            var dict = plists[spec.location] ?? [:]
            dict[spec.key] = selection.value(for: spec).plistObject
            plists[spec.location] = dict
        }

        var payloads: [TweakPayload] = []
        var emitted: [TweakFileLocation] = []

        for location in order {
            if nullified.contains(location) {
                guard let dest = TweakDomainMap.split(path: location.rawValue) else {
                    skipped.append((location.rawValue, "no backup-domain prefix matches this location"))
                    continue
                }
                payloads.append(TweakPayload(domain: dest.domain,
                                             relativePath: dest.relativePath,
                                             contents: Data()))
                emitted.append(location)
                continue
            }
            guard let plist = plists[location] else { continue }
            // Every `FileLocation` has a prefix rule in `TweakDomainMap`, so
            // this cannot fail for the ported catalog — but the reference
            // answers an unmapped path with `(path, "")` (a domain equal to the
            // absolute path), which would inject a row no device ever produced.
            // Refusing instead of reproducing that is deliberate.
            guard let dest = TweakDomainMap.split(path: location.rawValue) else {
                skipped.append((location.rawValue, "no backup-domain prefix matches this location"))
                continue
            }
            payloads.append(TweakPayload(domain: dest.domain,
                                         relativePath: dest.relativePath,
                                         contents: serialisePlist(plist)))
            emitted.append(location)
        }

        // The reference mirrors `.GlobalPreferences.plist` into HomeDomain so a
        // tweak that reads it through the NSGlobalDomain search chain still sees
        // the values after the Phase 3 protective restore
        // (`device_manager.py:1005-1016`).
        //
        // **Deliberate divergence**: the reference writes that mirror
        // *unconditionally*, so a run that touches no GP key would write
        // `plistlib.dumps({})` over the device's real HomeDomain
        // `.GlobalPreferences.plist`.  This port writes the mirror only when
        // there is something to mirror — the stated intent ("also write it to
        // HomeDomain so tweaks that depend on it survive") is preserved, and an
        // empty dict is never used to overwrite a live file.
        if let gp = plists[.globalPreferences], !gp.isEmpty,
           let dest = TweakDomainMap.split(path: TweakFileLocation.globalPreferencesHomeDomain.rawValue) {
            payloads.append(TweakPayload(domain: dest.domain,
                                         relativePath: dest.relativePath,
                                         contents: serialisePlist(gp)))
            emitted.append(.globalPreferencesHomeDomain)
        }

        return Result(payloads: payloads, locations: emitted, skipped: skipped)
    }

    /// `plistlib.dumps(plist)` — XML, the reference's default format.
    ///
    /// Not private: the page reset writes plists too (`TweakReset`), and one
    /// writer for the port is the point of `docs/tweak-port.md` — two of these
    /// drifting apart is how a reset would start writing a format the apply
    /// path never produces.
    static func serialisePlist(_ plist: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: plist,
                                             format: .xml, options: 0)) ?? Data()
    }
}
