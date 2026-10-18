// SPDX-License-Identifier: GPL-2.0-or-later
// Shared app-library colors, status indicators, and Android runtime details.
import SwiftUI
import UIKit

// MARK: - palette

enum Console {
    /// A colour for each appearance.
    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// The page: black, or near-white.
    static let page = adaptive(dark: .black, light: UIColor(white: 0.965, alpha: 1))
    /// Cards and wells on the page.
    static let card = adaptive(dark: UIColor(white: 0.11, alpha: 1), light: UIColor(white: 0.905, alpha: 1))
    /// One step up from a card: buttons beside Play.
    static let raised = adaptive(dark: UIColor(white: 0.16, alpha: 1), light: UIColor(white: 0.865, alpha: 1))
    /// An unselected chip.
    static let chip = adaptive(dark: UIColor(white: 1, alpha: 0.12), light: UIColor(white: 0, alpha: 0.07))
    static let hairline = adaptive(dark: UIColor(white: 1, alpha: 0.08), light: UIColor(white: 0, alpha: 0.08))
    /// Text, and the fill of what is selected: white in dark, black in light.
    static let text = adaptive(dark: .white, light: .black)
    /// What sits on `text` as a fill: the selected chip's label, Play's label.
    static let onText = adaptive(dark: .black, light: .white)
    static let textDim = adaptive(dark: UIColor(white: 1, alpha: 0.6), light: UIColor(white: 0, alpha: 0.55))
}

/// How an item runs, as a dot and a word: from this iPhone's own record first, then the compatibility list.
struct ItemStatus: Equatable {
    let label: String
    let color: Color

    static let plays = ItemStatus(label: "Plays", color: .green)
    static let opens = ItemStatus(label: "Opens", color: .orange)
    static let broken = ItemStatus(label: "Broken", color: .red)
    static let protected = ItemStatus(label: "Protected", color: .gray)
}

extension LibraryItem {
    /// The platform line over the title on Home.
    var platformName: String {
        switch self {
        case .app: return "Android · Emulator"
        case .game: return "Android"
        }
    }

    /// The dot: green Plays, orange Opens, red Broken. Nothing when nobody knows.
    @MainActor var status: ItemStatus? {
        if case .game(let g) = self, let r = GameStatusStore.shared.status(g.id)?.result {
            switch r {
            case .plays: return .plays
            case .crashed: return .opens
            case .failed: return .broken
            }
        }
        switch CompatibilityStore.shared.entry(packageName)?.status {
        case .works?: return .plays
        case .opens?: return .opens
        case .broken?: return .broken
        case .protected?: return .protected
        case nil: return nil
        }
    }

    /// "Last played 2 hours ago", or nothing for what was never opened from Husk.
    var lastPlayedText: String? {
        guard let date = lastUsed else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        let ago = date.timeIntervalSinceNow > -60 ? "just now" : rel.localizedString(for: date, relativeTo: Date())
        return (isGame ? "Last played " : "Last opened ") + ago
    }

    /// When it was added to Husk, from its folder: what "Recently added" sorts by. Read once per item and kept, since Home
    /// redraws often and a folder's creation date does not change.
    @MainActor var addedDate: Date? {
        if let known = AddedDates.cache[id] { return known }
        let path: String
        switch self {
        case .game(let g): path = TranslationLayer.root.appendingPathComponent(g.id).path
        default: return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let date = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
        AddedDates.cache[id] = .some(date)
        return date
    }
}

@MainActor private enum AddedDates {
    static var cache: [String: Date?] = [:]
}

struct StatusDot: View {
    let status: ItemStatus
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(status.color).frame(width: size, height: size)
    }
}

// MARK: - chips

/// A platform chip: white fill when selected, a dark well otherwise.
struct ConsoleChip: View {
    let title: String
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .foregroundStyle(selected ? Console.onText : Console.text.opacity(0.85))
                .padding(.horizontal, compact ? 11 : 14)
                .frame(height: compact ? 28 : 32)
                .background(selected ? Console.text : Console.chip, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
