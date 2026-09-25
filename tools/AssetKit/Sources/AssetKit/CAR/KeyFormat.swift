import Foundation

/// kThemeRenditionAttribute IDs for CoreUI 970 (StorageVersion 17, Xcode 26).
///
/// Values determined by dumping the KEYFORMAT block of an actool-produced
/// Assets.car (`xcrun assetutil --info`). Older CoreUI versions used a
/// different numbering; do not rely on writeups that predate Xcode 14.
enum AttributeID: UInt32 {
    case element = 1
    case part = 2
    case appearance = 7
    case localization = 8
    case dimension2 = 9
    case dimension1 = 10
    case scale = 12
    case localizationLegacy = 13
    case attribute14 = 14
    case subtype = 15
    case subtypeLegacy = 16
    case identifier = 17
    case attribute18 = 18
    case attribute19 = 19
    case attribute24 = 24
}

/// Attribute order CoreUI 970 emits in `KEYFORMAT` (and which the rendition key
/// tuple positions mirror exactly). Order is significant: CoreUI reads a
/// rendition key positionally, using this list to name each slot, and
/// binary-searches the packed keys by raw byte comparison.
///
/// Local patch: the list below was 9 attributes in the order
/// (appearance, localization, scale, idiom, subtype, dimension2, identifier,
/// element, part). Dumping `KEYFORMAT` out of actool-produced catalogs shows
/// the real order starts with the *identity* triple — element, part,
/// identifier — and is 11 entries long for an app-icon catalog:
///
///     count = 11, attrs = [7, 1, 2, 17, 9, 10, 14, 12, 24, 19, 18]
///
/// The old order shifted every field, so no rendition in the catalog was
/// resolvable. The list is per-catalog rather than universal — other actool
/// catalogs in the same SDK carry 12 attributes (adding a localization slot at
/// 8) or 13 (dropping appearance) — so this mirrors the app-icon shape, which
/// is the one this writer has to produce.
let v1KeyFormat: [AttributeID] = [
    .appearance,
    .element,
    .part,
    .identifier,
    .dimension2,
    .dimension1,
    .attribute14,
    .scale,
    .attribute24,
    .attribute19,
    .attribute18,
]

/// `kfmt` block payload.
enum KeyFormatBlock {
    static let magic: UInt32 = 0x6B666D74 // 'kfmt' as LE multi-char constant

    static func data(attributes: [AttributeID] = v1KeyFormat) -> Data {
        var w = ByteWriter()
        w.writeLE(magic)
        w.writeLE(UInt32(0))                            // version
        w.writeLE(UInt32(attributes.count))             // maximumRenditionKeyTokenCount
        for attr in attributes {
            w.writeLE(attr.rawValue)
        }
        return w.data
    }
}
