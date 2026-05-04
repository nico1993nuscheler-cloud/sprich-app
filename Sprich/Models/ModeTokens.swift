import SwiftUI

// MARK: - Sprich Design Tokens
//
// Source of truth: `~/Code/Sprich/.tmp/design-handoff/.../colors_and_type.css`
// from Claude Design 2026-05-01 handoff. These hex values are the canonical
// brand palette — keep this file in sync with that CSS, not vice versa.
//
// IMPORTANT: Mode accent colors are *product-UI only*. Marketing/landing copy
// uses ink + forest + cream as the visible palette; modes only show inside
// the recording overlay and Settings provider rows.

extension Color {
    // Mode accents (product-UI only)
    static let modeLiteral = Color(red: 0x59 / 255.0, green: 0xD9 / 255.0, blue: 0xA6 / 255.0)
    static let modeFormal  = Color(red: 0x8C / 255.0, green: 0x73 / 255.0, blue: 0xF2 / 255.0)
    static let modeCustom  = Color(red: 0xF2 / 255.0, green: 0xA6 / 255.0, blue: 0x59 / 255.0)

    // Brand neutrals
    static let sprichInk       = Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x18 / 255.0)
    static let sprichInk2      = Color(red: 0x4A / 255.0, green: 0x4A / 255.0, blue: 0x46 / 255.0)
    static let sprichInk3      = Color(red: 0x8A / 255.0, green: 0x8A / 255.0, blue: 0x82 / 255.0)
    static let sprichForest    = Color(red: 0x1F / 255.0, green: 0x5F / 255.0, blue: 0x4B / 255.0)
    static let sprichForestDk  = Color(red: 0x17 / 255.0, green: 0x47 / 255.0, blue: 0x38 / 255.0)
    static let sprichCream     = Color(red: 0xFA / 255.0, green: 0xFA / 255.0, blue: 0xF7 / 255.0)
    static let sprichCreamAlt  = Color(red: 0xF5 / 255.0, green: 0xF3 / 255.0, blue: 0xEE / 255.0)
    static let sprichBorder    = Color(red: 0xE8 / 255.0, green: 0xE5 / 255.0, blue: 0xDE / 255.0)
    static let sprichBorderStr = Color(red: 0xC9 / 255.0, green: 0xC5 / 255.0, blue: 0xBC / 255.0)

    // Live-recording dot — explicitly out of the brand palette so it never gets
    // confused with the success/error semantic colors. Matches the landing HUD
    // exactly: var(--rec-dot) is hard-coded to #FF4A3D in hud.jsx.
    static let sprichRecordDot = Color(red: 0xFF / 255.0, green: 0x4A / 255.0, blue: 0x3D / 255.0)
}

extension TranscriptionMode {
    /// Mode accent color for the recording overlay + provider rows in Settings.
    var accentColor: Color {
        switch self {
        case .literal: return .modeLiteral
        case .formal:  return .modeFormal
        case .custom:  return .modeCustom
        }
    }

    /// Foreground color (text + iconography) for content rendered ON TOP of
    /// `accentColor` — e.g. the mode label + dot inside the overlay's mode
    /// sub-pill. Picked per-mode for AA-readable contrast:
    ///
    /// - Literal mint (#59D9A6, L≈82)  → ink (#1A1A18, L≈10) — high contrast ✓
    /// - Formal lavender (#8C73F2, L≈58) → cream (#FAFAF7, L≈98) — ink reads
    ///   muddy on the saturated purple; cream pops cleanly
    /// - Custom peach (#F2A659, L≈73)  → ink (#1A1A18, L≈10) — high contrast ✓
    var accentForeground: Color {
        switch self {
        case .literal: return .sprichInk
        case .formal:  return .sprichCream
        case .custom:  return .sprichInk
        }
    }
}
