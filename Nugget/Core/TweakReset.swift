import Foundation

/// A page that can be reset on the device, mirroring the entries
/// `src/utils/pages.py:get_resettable_pages` hands to the reference's reset
/// dialog.
///
/// The reference builds that list as `[StatusBar, Springboard, InternalOptions,
/// Daemons]` and drops `StatusBar` on iOS 27, where the Speakeasy flags it
/// writes are not writable.
///
/// **This port has no Status Bar page**, so the group is not offered at all:
/// nothing in the catalog writes `/Library/SpringBoard/statusBarOverrides`
/// (`TweakFileLocation` has no case for it — the only mention in the app is a
/// skip-prefix in `ProtectiveBackup`). The other three map one-to-one, in the
/// reference's order.
///
/// The name is `Page` in the reference and carries the same meaning — a
/// *feature area*, not a navigation destination. `AppDestination` is this app's
/// navigation enum and would be the wrong thing to reuse: it holds Daemons but
/// not Springboard or Internal, which are sections of the Tweaks page.
enum ResetPage: String, CaseIterable, Identifiable, Sendable {
    case springboard
    case internalOptions
    case daemons

    var id: String { rawValue }

    /// `Page.getPageName()` — "Internal", not "Internal Options", because that
    /// is the string the reference's checkbox carries.
    var title: String {
        switch self {
        case .springboard: return "Springboard"
        case .internalOptions: return "Internal"
        case .daemons: return "Daemons"
        }
    }

    /// The files this page's reset writes, in the order the reference appends
    /// them, for the sheet's "what this will touch" line and the run log.
    ///
    /// `internalOptions` carries seven files while the catalog's Internal
    /// section only uses six of them: the reference nulls
    /// `.GlobalPreferences.plist` in HomeDomain as well, and no tweak in this
    /// port writes that copy. It is kept because the reference clears it, and
    /// dropping it would make this a *different* reset rather than a port of
    /// the same one.
    var locations: [TweakFileLocation] {
        switch self {
        case .springboard:
            return [.springboard, .uikit]
        case .internalOptions:
            return [.globalPreferences, .globalPreferencesHomeDomain, .appStore,
                    .backboardd, .coreMotion, .pasteboard, .notes]
        case .daemons:
            return [.disabledDaemons]
        }
    }
}

/// Builds the file set a page reset restores.
///
/// A port of `device_manager._reset_tweaks`
/// (`src/devicemanagement/device_manager.py:1106-1245`): no psysbackup capture,
/// no reading of the device's current values — the run writes a fixed set of
/// files that put the named pages back to stock.
///
/// ## No psysbackup, on either branch
///
/// The reference's iOS 27 branch captures the device's original plists with
/// psysbackup first and restores *those*, which is what makes its reset a real
/// "put back what was there" rather than "write the same values again". This
/// port has no capture and no materialiser, so it does what the reference
/// itself does when its capture is unavailable — its `plistlib.dumps({})`
/// fallback, which is a documented, deliberate path rather than a degraded one:
///
/// > Restore a valid empty plist instead of a zero-byte file: on iOS 26.2+ a
/// > truncated plist (e.g. an empty com.apple.springboard.plist) makes
/// > SpringBoard crash at boot, which sends the device into a boot loop. An
/// > empty dict parses fine and makes the system fall back to its default
/// > values.
///
/// So the two branches differ in exactly one thing, and it is the nulled
/// file's *bytes*:
///
/// | branch | nulled file written as | why |
/// |---|---|---|
/// | iOS 26 and below | 0 bytes | the original Nugget's behaviour, and a daemon reading an empty file falls back to its defaults |
/// | iOS 27+ | `plistlib.dumps({})` — a valid, empty XML plist | a 0-byte plist is a *truncated* plist there, and that is the boot loop above |
///
/// The daemons file is the stock dict on both, and neither branch reads
/// anything back from the device first.
///
/// ## The two kinds of file
///
/// * **Nulled** — 0 bytes or an empty dict, per the table above.
///   `NullifyFileTweak`'s trick, which this port already ships for the
///   ScreenTime daemon: the daemon that reads the file falls back to its
///   defaults.
/// * **Daemons** — the *stock* `disabled.plist`, a six-key dict. Not empty and
///   not "the tweaks off": launchd's own file on a stock device disables five
///   of these, so an empty dict would leave `otpaird`, `bootpd`, `dhcp6d`,
///   `magicswitchd.companion` and `relevanced` *enabled* where the factory
///   device has them off, and a reset would be a way to break pairing.
///
/// The owner/group the reference passes for that file (`owner=0, group=0`) need
/// no special case here: `/var/db/…` maps to `DatabaseDomain`, whose
/// `TweakRowProfile` is measured at `0/0`.
enum TweakReset {
    /// What one file of the reset gets written as. Carried rather than derived
    /// from `contents.count`, because the iOS 27 variant is 43 bytes of XML and
    /// the log must not describe that as "not nulled".
    enum Kind: String, Sendable {
        /// 0 bytes, the iOS 26 null.
        case zeroBytes = "0 bytes"
        /// `plistlib.dumps({})`, the iOS 27 null.
        case emptyPlist = "empty plist"
        /// The stock six-key `disabled.plist`.
        case stockDaemons = "stock daemons"
    }

    /// One file the reset will write.
    struct Target: Identifiable, Sendable {
        let location: TweakFileLocation
        let contents: Data
        let kind: Kind
        var id: String { location.rawValue }
    }

    struct Plan {
        let targets: [Target]
        let payloads: [TweakPayload]
        /// Locations with no backup-domain prefix — refused rather than injected
        /// as a row the device never produced (the compiler's rule, same reason).
        let skipped: [(label: String, reason: String)]
        /// Whether the two `skip_setup` files join this reset — the reference's
        /// `add_skip_setup` gate, reproduced exactly. See `plan(pages:ios27:)`.
        let skipSetupAllowed: Bool
    }

    /// `default_daemons` from `_reset_tweaks`, verbatim: the contents of
    /// `/var/db/com.apple.xpc.launchd/disabled.plist` on a stock device. `true`
    /// means launchd keeps the service disabled, which is how the factory
    /// device ships for all of these except the embedded FTP proxy, which is
    /// present but explicitly not disabled.
    static let stockDisabledDaemons: [String: Bool] = [
        "com.apple.magicswitchd.companion": true,
        "com.apple.security.otpaird": true,
        "com.apple.dhcp6d": true,
        "com.apple.bootpd": true,
        "com.apple.ftp-proxy-embedded": false,
        "com.apple.relevanced": true,
    ]

    /// Build the payload set for `pages`.
    ///
    /// - Parameter ios27: which null to write. Passed in rather than read from
    ///   the device here, because the caller has already read the version for
    ///   its own format fork and re-reading it would be a second handshake — and
    ///   two reads of the same fact is how the apply path once put a 27.0
    ///   device on the 26 branch.
    ///
    /// The reference appends the daemons file inside the page loop and writes
    /// every nulled file after the loop, so the restore carries the non-null
    /// file first; the order is kept here because it is free and a diff against
    /// the reference should not have to explain a difference. The two
    /// `skip_setup` files are appended *after* all of these — the reference calls
    /// `add_skip_setup` after the null loop, so they are last in its file list
    /// too.
    static func plan(pages: Set<ResetPage>, ios27: Bool) -> Plan {
        // `ResetPage.allCases` order, not the caller's `Set` order: `Set` has
        // none, and a payload list that reorders between two runs of the same
        // request makes the log harder to read than it needs to be.
        let ordered = ResetPage.allCases.filter { pages.contains($0) }
        let nullContents = ios27 ? TweakCompiler.serialisePlist([:]) : Data()
        let nullKind: Kind = ios27 ? .emptyPlist : .zeroBytes

        var targets: [Target] = []
        var payloads: [TweakPayload] = []
        var skipped: [(label: String, reason: String)] = []

        func add(_ location: TweakFileLocation, _ contents: Data, _ kind: Kind) {
            // Every location above has a prefix rule in `TweakDomainMap`, so this
            // cannot fail for these three pages — but a row injected with no
            // domain is a row no device ever produced, so it is refused rather
            // than written.
            guard let dest = TweakDomainMap.split(path: location.rawValue) else {
                skipped.append((location.rawValue, "no backup-domain prefix matches this location"))
                return
            }
            targets.append(Target(location: location, contents: contents, kind: kind))
            payloads.append(TweakPayload(domain: dest.domain,
                                         relativePath: dest.relativePath,
                                         contents: contents))
        }

        for page in ordered {
            for location in page.locations where location == .disabledDaemons {
                add(location, TweakCompiler.serialisePlist(stockDisabledDaemons), .stockDaemons)
            }
        }
        for page in ordered {
            for location in page.locations where location != .disabledDaemons {
                add(location, nullContents, nullKind)
            }
        }

        return Plan(targets: targets, payloads: payloads, skipped: skipped,
                    skipSetupAllowed: skipSetupAllowed(pages: ordered, ios27: ios27))
    }

    /// The reference's `add_skip_setup` gate, reproduced exactly:
    ///
    /// ```python
    /// if self.pref_manager.skip_setup and (restoring_domains
    ///         or (dev_version and Version(dev_version) < Version("27.0"))):
    /// ```
    ///
    /// In the reset path `uses_domains` is assigned in exactly one place — the
    /// Daemons branch — so on **iOS 27 a Springboard-only or Internal-only reset
    /// carries no `skip_setup` files at all**, and only a reset that ticks
    /// Daemons (or any combination containing it) picks them up. On iOS 26 the
    /// version arm is true, so they always ride along. The reference does not
    /// explain the iOS 27 arm; its own comment argues the files are safe
    /// regardless ("they always carry real domains, so they can always ride the
    /// domain delivery"), which makes the flag look like a leftover from the
    /// tweak path. It is kept as written so a diff against the reference is
    /// empty — the trade-off is a Springboard-only reset on iOS 27 leaving the
    /// setup wizard state alone.
    static func skipSetupAllowed(pages: [ResetPage], ios27: Bool) -> Bool {
        let usesDomains = pages.contains(.daemons)
        return usesDomains || !ios27
    }
}

