import Foundation

/// Packed rendition key matching `v1KeyFormat` (CoreUI 970, 11 attributes).
///
/// Encoded as a sequence of little-endian `UInt16` tokens, one per attribute,
/// in the order declared by `KEYFORMAT`. The pair `(attributeID, attributeValue)`
/// is implicit: the position in the tuple selects which attribute the token
/// belongs to. Total size is 22 bytes (11 × u16).
///
/// Local patch: the slot order was wrong. CoreUI reads a rendition key
/// *positionally*, using `KEYFORMAT` to name each slot, so a key whose fields
/// are in a different order is not misread — it decodes to entirely different
/// attributes. The previous order
/// (appearance, localization, scale, idiom, subtype, dimension2, identifier,
/// element, part) put `localization` where CoreUI expects `element`, `scale`
/// where it expects `part`, and so on, so every rendition in the catalog was
/// unresolvable and SpringBoard fell back to the loose PNGs. The order below
/// is what actool actually emits for an app-icon catalog, read out of
/// `KEYFORMAT` in actool-produced `Assets.car` files (Xcode 26 / CoreUI 970):
///
///     count = 11, attrs = [7, 1, 2, 17, 9, 10, 14, 12, 24, 19, 18]
///
/// Note that actool's list is per-catalog, not fixed: other catalogs in the
/// same SDK carry 12 or 13 attributes (some add a localization slot at 8, some
/// drop appearance entirely). This mirrors the app-icon case, which is the
/// shape this writer has to match.
struct RenditionKey: Hashable, Sendable {
    /// attr 7
    var appearance: UInt16
    /// attr 1
    var element: UInt16
    /// attr 2
    var part: UInt16
    /// attr 17
    var identifier: UInt16
    /// attr 9
    var dimension2: UInt16
    /// attr 10
    var dimension1: UInt16
    /// attr 14 — never set by actool for bitmaps; carries a 0.
    var attribute14: UInt16
    /// attr 12
    var scale: UInt16
    /// attr 24
    var attribute24: UInt16
    /// attr 19
    var attribute19: UInt16
    /// attr 18
    var attribute18: UInt16

    /// CoreUI element IDs that v1 emits. Values dumped from reference
    /// `Assets.car` produced by actool (Xcode 26 / CoreUI 970).
    enum Element: UInt16 {
        /// Element used by both `.image` (imageset) and `.appIcon` bitmap
        /// renditions. The category is differentiated by `Part` below.
        case bitmap = 85
    }

    /// CoreUI part IDs that v1 emits.
    enum Part: UInt16 {
        /// Used by SpringBoard's icon-render pipeline for the classic
        /// `.appiconset` bitmaps. Confirmed against actool output: the
        /// appearance-0 app-icon bitmaps of a real app carry `part = 220`
        /// with `layout = 12` and the source filename as the rendition name.
        /// (The `245` / `layout 1019` pairs seen in the same catalogs are
        /// Icon Composer *iconstacks* — `AppIcon.iconstack` — which are the
        /// modern dark/tinted mechanism and are not what a `.appiconset`
        /// compiles to.)
        case appIcon = 220
        /// Used by UIImage(named:) for generic `.imageset` assets.
        case image = 181
        /// Slot for preserved-source vector renditions (SVG). Reference
        /// `actool` output places the SVG source rendition under this part
        /// rather than `image`; bitmap variants rasterised from the SVG
        /// (which `UIImage(named:)` actually returns) live under `image`.
        case vectorSource = 42
    }

    init(rendition: Rendition) {
        self.appearance = (rendition.appearance?.darkLuminosity == true) ? 1 : 0
        self.identifier = UInt16(FacetKeys.nameHash(rendition.name) & 0xFFFF)
        self.scale = rendition.scale?.rawValueByte ?? 0
        // The remaining slots stay zero: this writer emits no localization,
        // no vector-source renditions and no multi-dimension bitmaps.
        self.attribute14 = 0
        self.attribute24 = 0
        self.attribute19 = 0
        self.attribute18 = 0
        self.dimension1 = 0
        switch rendition.body {
        case .bitmap(let body):
            self.element = Element.bitmap.rawValue
            switch body.kind {
            case .appIcon:
                self.part = Part.appIcon.rawValue
                // Dimension2 is the appicon "Icon Index" slot. v1 only
                // emits one logical icon size per appiconset, so this is
                // always 1.
                self.dimension2 = 1
            case .image:
                self.part = Part.image.rawValue
                // Generic image assets don't use Dimension2 at all.
                self.dimension2 = 0
            }
        case .color:
            self.element = 0
            self.part = 0
            self.dimension2 = 0
        case .preservedSource(let body):
            self.element = Element.bitmap.rawValue
            self.dimension2 = 0
            switch body.format {
            case .svg:
                // SVG source renditions occupy the dedicated vector-source
                // part; bitmap variants rasterised from the SVG (when the
                // compiler emits them) would use Part.image instead.
                self.part = Part.vectorSource.rawValue
            case .jpeg:
                // JPEG sits in the generic-image lookup category — CoreUI
                // decodes the JPG body itself at runtime and returns the
                // resulting bitmap from UIImage(named:).
                self.part = Part.image.rawValue
            }
        }
    }

    init(
        appearance: UInt16 = 0,
        element: UInt16 = 0,
        part: UInt16 = 0,
        identifier: UInt16 = 0,
        dimension2: UInt16 = 0,
        dimension1: UInt16 = 0,
        attribute14: UInt16 = 0,
        scale: UInt16 = 0,
        attribute24: UInt16 = 0,
        attribute19: UInt16 = 0,
        attribute18: UInt16 = 0
    ) {
        self.appearance = appearance
        self.element = element
        self.part = part
        self.identifier = identifier
        self.dimension2 = dimension2
        self.dimension1 = dimension1
        self.attribute14 = attribute14
        self.scale = scale
        self.attribute24 = attribute24
        self.attribute19 = attribute19
        self.attribute18 = attribute18
    }

    func encode() -> Data {
        var w = ByteWriter()
        w.writeLE(appearance)
        w.writeLE(element)
        w.writeLE(part)
        w.writeLE(identifier)
        w.writeLE(dimension2)
        w.writeLE(dimension1)
        w.writeLE(attribute14)
        w.writeLE(scale)
        w.writeLE(attribute24)
        w.writeLE(attribute19)
        w.writeLE(attribute18)
        return w.data
    }

    static func decode(_ data: Data) -> RenditionKey? {
        guard data.count == 22 else { return nil }
        func u16(_ offset: Int) -> UInt16 {
            let lo = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            let hi = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
            return lo | (hi << 8)
        }
        return RenditionKey(
            appearance: u16(0),
            element: u16(2),
            part: u16(4),
            identifier: u16(6),
            dimension2: u16(8),
            dimension1: u16(10),
            attribute14: u16(12),
            scale: u16(14),
            attribute24: u16(16),
            attribute19: u16(18),
            attribute18: u16(20)
        )
    }
}
