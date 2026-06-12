import Foundation

enum RevealStyle: String, CaseIterable {
    /// Expand the hidden section in the menu bar itself.
    case inline
    /// Show hidden icons in a drop-down panel below the Tuck icon.
    case panel
}

final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    enum Key {
        static let revealStyle = "revealStyle"
        static let autoCollapseSeconds = "autoCollapseSeconds"
        static let startCollapsed = "startCollapsed"
        static let showSeparator = "showSeparator"
        static let isFirstLaunch = "isFirstLaunch"
        static let didSeedPositions = "didSeedPositions"
        static let panelIconsPerRow = "panelIconsPerRow"
        static let pinnedItems = "pinnedItems"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.revealStyle: RevealStyle.panel.rawValue,
            Key.autoCollapseSeconds: 15.0,
            Key.startCollapsed: true,
            Key.showSeparator: true,
            Key.isFirstLaunch: true,
            Key.panelIconsPerRow: 10,
        ])
    }

    /// Maximum icons per row in the drop-down panel.
    var panelIconsPerRow: Int {
        get { max(1, d.integer(forKey: Key.panelIconsPerRow)) }
        set { d.set(newValue, forKey: Key.panelIconsPerRow) }
    }

    /// Identity keys of icons pinned as proxies next to the Tuck button.
    var pinnedItems: [String] {
        get { d.stringArray(forKey: Key.pinnedItems) ?? [] }
        set { d.set(newValue, forKey: Key.pinnedItems) }
    }

    var revealStyle: RevealStyle {
        get { RevealStyle(rawValue: d.string(forKey: Key.revealStyle) ?? "") ?? .panel }
        set { d.set(newValue.rawValue, forKey: Key.revealStyle) }
    }

    /// 0 means "never auto-collapse".
    var autoCollapseSeconds: Double {
        get { d.double(forKey: Key.autoCollapseSeconds) }
        set { d.set(newValue, forKey: Key.autoCollapseSeconds) }
    }

    var startCollapsed: Bool {
        get { d.bool(forKey: Key.startCollapsed) }
        set { d.set(newValue, forKey: Key.startCollapsed) }
    }

    var showSeparator: Bool {
        get { d.bool(forKey: Key.showSeparator) }
        set { d.set(newValue, forKey: Key.showSeparator) }
    }

    var isFirstLaunch: Bool {
        get { d.bool(forKey: Key.isFirstLaunch) }
        set { d.set(newValue, forKey: Key.isFirstLaunch) }
    }

    var didSeedPositions: Bool {
        get { d.bool(forKey: Key.didSeedPositions) }
        set { d.set(newValue, forKey: Key.didSeedPositions) }
    }
}
