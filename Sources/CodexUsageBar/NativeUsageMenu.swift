import AppKit
import UsageCore

/// A status-item menu whose structure remains stable while it is tracking.
@MainActor
final class NativeUsageMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    private let monitor: UsageMonitor
    private let preferences: Preferences

    private let headingItem = NativeUsageMenu.sectionHeader("Codex Usage")
    private let primaryUsageItem = NativeUsageMenu.informationalItem("Connecting to Codex…")
    private let primaryResetItem = NativeUsageMenu.informationalItem("")
    private let secondaryUsageItem = NativeUsageMenu.informationalItem("")
    private let secondaryResetItem = NativeUsageMenu.informationalItem("")
    private let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
    private let freshnessItem = NativeUsageMenu.informationalItem("")
    private let errorItem = NativeUsageMenu.informationalItem("")
    private let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let loginMessageItem = NativeUsageMenu.informationalItem("")
    private let otherModelsItem = NSMenuItem(title: "Other Models", action: nil, keyEquivalent: "")
    private let otherModelsMenu = NSMenu(title: "Other Models")
    private let noOtherModelsItem = NativeUsageMenu.informationalItem("No other usage limits")
    private let usedItem = NSMenuItem(title: "Used", action: #selector(showUsed), keyEquivalent: "")
    private let remainingItem = NSMenuItem(title: "Remaining", action: #selector(showRemaining), keyEquivalent: "")
    private var otherModelSlots: [NSMenuItem] = []

    init(monitor: UsageMonitor, preferences: Preferences) {
        self.monitor = monitor
        self.preferences = preferences
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        buildMenu()

        update()
    }

    func update() {
        let now = Date()
        let mode = preferences.showRemaining ? "remaining" : "used"
        let snapshot = monitor.snapshot

        if let windows = snapshot?.mainBucket?.displayWindows, let primary = windows.first {
            setTitle(usageTitle(for: primary, mode: mode), on: primaryUsageItem, style: .primary)
            setTitle(primary.resetDescription(now: now), on: primaryResetItem, style: .secondary)
            primaryUsageItem.isHidden = false
            primaryResetItem.isHidden = false
            if let secondary = windows.dropFirst().first {
                setTitle(usageTitle(for: secondary, mode: mode), on: secondaryUsageItem, style: .primary)
                setTitle(secondary.resetDescription(now: now), on: secondaryResetItem, style: .secondary)
                secondaryUsageItem.isHidden = false
                secondaryResetItem.isHidden = false
            } else {
                secondaryUsageItem.isHidden = true
                secondaryResetItem.isHidden = true
            }
        } else {
            setTitle(monitor.errorMessage == nil
                ? (monitor.isRefreshing ? "Connecting to Codex…" : "Usage unavailable")
                : "Codex usage unavailable", on: primaryUsageItem, style: .primary)
            primaryResetItem.isHidden = true
            secondaryUsageItem.isHidden = true
            secondaryResetItem.isHidden = true
        }

        let stale = monitor.isStale(at: now)
        setTitle((stale ? "Stale · " : "") + monitor.freshness(at: now), on: freshnessItem, style: .secondary)
        let errorText = monitor.errorMessage ?? ""
        setTitle(errorText.count > 72 ? String(errorText.prefix(69)) + "…" : errorText, on: errorItem, style: .error)
        errorItem.toolTip = errorText
        errorItem.isHidden = monitor.errorMessage == nil

        refreshItem.title = monitor.isRefreshing ? "Refreshing…" : "Refresh Now"
        refreshItem.isEnabled = !monitor.isRefreshing
        displayItem.title = preferences.showRemaining ? "Display: Remaining" : "Display: Used"
        usedItem.state = preferences.showRemaining ? .off : .on
        remainingItem.state = preferences.showRemaining ? .on : .off
        launchAtLoginItem.state = preferences.loginEnabled ? .on : .off
        setTitle(preferences.loginMessage ?? "", on: loginMessageItem, style: .secondary)
        loginMessageItem.isHidden = preferences.loginMessage == nil

        updateOtherModels(snapshot: snapshot, mode: mode, now: now)
    }

    func menuWillOpen(_ menu: NSMenu) {
        preferences.reloadLoginStatus()
        update()
        Task { [weak self] in
            guard let self else { return }
            await self.monitor.refresh()
            self.update()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        update()
    }

    private func buildMenu() {
        menu.addItem(headingItem)
        menu.addItem(primaryUsageItem)
        menu.addItem(primaryResetItem)
        menu.addItem(secondaryUsageItem)
        menu.addItem(secondaryResetItem)
        menu.addItem(freshnessItem)
        menu.addItem(errorItem)
        menu.addItem(.separator())

        let displayMenu = NSMenu(title: "Display")
        usedItem.target = self
        remainingItem.target = self
        displayMenu.addItem(usedItem)
        displayMenu.addItem(remainingItem)
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        otherModelsItem.submenu = otherModelsMenu
        otherModelsMenu.autoenablesItems = false
        otherModelsMenu.addItem(noOtherModelsItem)
        menu.addItem(otherModelsItem)
        menu.addItem(.separator())

        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = [.command]
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Open Codex", action: #selector(openCodexApp), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(.separator())

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(loginMessageItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Codex Usage Bar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    private func updateOtherModels(snapshot: UsageSnapshot?, mode: String, now: Date) {
        let others = snapshot?.buckets.filter { $0.id != "codex" } ?? []
        otherModelsItem.isHidden = others.isEmpty
        noOtherModelsItem.isHidden = !others.isEmpty

        var rows: [(title: String, style: TextStyle)] = []
        for entry in others {
            rows.append((entry.bucket.displayName, .heading))
            if entry.bucket.windows.isEmpty {
                rows.append(("  Usage unavailable", .secondary))
            } else {
                for window in entry.bucket.windows {
                    rows.append(("  " + usageTitle(for: window, mode: mode), .primary))
                    rows.append(("  " + window.resetDescription(now: now), .secondary))
                }
            }
        }
        while otherModelSlots.count < rows.count {
            let item = Self.informationalItem("")
            item.isHidden = true
            otherModelSlots.append(item)
            otherModelsMenu.addItem(item)
        }
        for (index, item) in otherModelSlots.enumerated() {
            guard index < rows.count else {
                item.isHidden = true
                continue
            }
            setTitle(rows[index].title, on: item, style: rows[index].style)
            item.isHidden = false
        }
    }

    private func usageTitle(for window: UsageWindow, mode: String) -> String {
        guard let used = window.percentage else { return "\(window.label) · Usage unavailable" }
        let value = preferences.showRemaining ? 100 - used : used
        return "\(window.label) · \(Int(value.rounded()))% \(mode)"
    }

    @objc private func showUsed() {
        preferences.showRemaining = false
        update()
    }

    @objc private func showRemaining() {
        preferences.showRemaining = true
        update()
    }

    @objc private func refreshNow() {
        Task { [weak self] in
            guard let self else { return }
            await self.monitor.refresh()
            self.update()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        preferences.setLogin(!preferences.loginEnabled)
        update()
    }

    @objc private func openCodexApp() {
        openCodex()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private static func informationalItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        return informationalItem(title)
    }

    private enum TextStyle {
        case heading, primary, secondary, error
    }

    private func setTitle(_ title: String, on item: NSMenuItem, style: TextStyle) {
        let attributes: [NSAttributedString.Key: Any]
        switch style {
        case .heading:
            attributes = [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        case .primary:
            attributes = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        case .secondary:
            attributes = [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        case .error:
            attributes = [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.systemRed]
        }
        item.title = title
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}
