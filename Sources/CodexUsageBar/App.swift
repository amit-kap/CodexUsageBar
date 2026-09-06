import AppKit
import Combine
import ServiceManagement
import UsageCore

@main
struct CodexUsageBarMain {
    @MainActor
    static func main() async {
        // Read-only integration check. No GUI, model turn, or stored credentials.
        if CommandLine.arguments.contains("--check") {
            let client = CodexClient()
            do {
                let snapshot = try await client.readUsage()
                for entry in snapshot.buckets {
                    for window in entry.bucket.windows {
                        print("\(entry.bucket.displayName) · \(window.label): \(window.percentage.map { String(format: "%.0f%% used", $0) } ?? "unavailable") · \(window.resetDescription())")
                    }
                }
                client.stop()
                exit(0)
            } catch {
                fputs("Usage check failed: \(error.localizedDescription)\n", stderr)
                client.stop()
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--watch-check") {
            let monitor = UsageMonitor()
            monitor.start()
            for second in 0..<70 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if second == 3 || second == 68 {
                    print("t=\(second + 1)s successful refreshes=\(monitor.refreshCount), main=\(monitor.snapshot?.mainWindow?.percentage.map { String($0) } ?? "unavailable"), error=\(monitor.errorMessage ?? "none")")
                }
            }
            let passed = monitor.refreshCount >= 2
            monitor.stop()
            exit(passed ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var showRemaining: Bool {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "showRemaining") }
    }
    @Published var loginEnabled = false
    @Published var loginMessage: String?
    init() {
        showRemaining = UserDefaults.standard.bool(forKey: "showRemaining")
        reloadLoginStatus()
    }
    func reloadLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            reloadLoginStatus()
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Codex Usage Bar in System Settings → Login Items." : nil
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            reloadLoginStatus()
            loginMessage = "Could not change login startup: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = UsageMonitor()
    let preferences = Preferences()
    private var statusItem: NSStatusItem!
    private var usageMenu: NativeUsageMenu!
    private var subscriptions = Set<AnyCancellable>()
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageTrailing
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.setAccessibilityLabel("Codex usage")
        }
        usageMenu = NativeUsageMenu(monitor: monitor, preferences: preferences)
        // AppKit owns anchoring, material, tracking, keyboard navigation, and dismissal.
        statusItem.menu = usageMenu.menu
        monitor.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.monitor.refresh() }
        }
        updateStatus()
        monitor.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.statusItem.button?.performClick(nil) }
        }
    }

    @objc private func tick() { updateStatus() }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let used = monitor.snapshot?.mainWindow?.percentage
        let percent = used.map { preferences.showRemaining ? 100 - $0 : $0 }
        let text = percent.map { "\(Int($0.rounded()))%" } ?? "—"
        let stale = monitor.isStale()
        button.title = "\(text)\(stale ? " !" : "") "
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
        )
        button.image = statusIndicatorIcon(
            usedPercent: used,
            showingRemaining: preferences.showRemaining,
            stale: stale,
            appearance: button.effectiveAppearance
        )
        let mode = preferences.showRemaining ? "remaining" : "used"
        let window = monitor.snapshot?.mainWindow?.label ?? "Usage"
        button.toolTip = "Codex · \(window) · \(text) \(mode)\n\(stale ? "Stale reading · " : "")\(monitor.freshness())"
        button.setAccessibilityValue("\(window), \(text) \(mode)\(stale ? ", stale reading" : "")")
        usageMenu?.update()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        ticker?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}

@MainActor
private func statusIndicatorIcon(
    usedPercent: Double?,
    showingRemaining: Bool,
    stale: Bool,
    appearance: NSAppearance
) -> NSImage {
    let image = NSImage(size: NSSize(width: 40, height: 18))
    image.lockFocus()
    defer { image.unlockFocus() }

    appearance.performAsCurrentDrawingAppearance {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let meterColor = (isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(stale ? 0.55 : 1)
        let used = usedPercent.map { min(100, max(0, $0)) }
        let displayed = used.map { showingRemaining ? 100 - $0 : $0 }

        // A readable capacity bar: pure rectangle, no battery terminal.
        let track = NSRect(x: 0.5, y: 4, width: 16, height: 10)
        let outline = NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1)
        outline.lineWidth = 1
        meterColor.setStroke()
        outline.stroke()

        if let displayed {
            let interior = track.insetBy(dx: 2, dy: 2)
            let width = displayed > 0 ? max(1, interior.width * CGFloat(displayed / 100)) : 0
            meterColor.setFill()
            NSBezierPath(rect: NSRect(x: interior.minX, y: interior.minY, width: width, height: interior.height)).fill()
        } else {
            meterColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 7.25, y: 8.25, width: 2, height: 2)).fill()
        }

        if stale {
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 6.5, y: 5))
            mark.line(to: NSPoint(x: 10.5, y: 13))
            mark.lineWidth = 1
            meterColor.setStroke()
            mark.stroke()
        }

        // Retain the installed Codex artwork as a distinct icon beside the meter.
        menuBarIcon().draw(in: NSRect(x: 20, y: 0, width: 18, height: 18),
                           from: .zero,
                           operation: .sourceOver,
                           fraction: 1)
    }
    image.isTemplate = false
    image.accessibilityDescription = "Codex usage capacity meter and Codex icon"
    return image
}

/// Reuse the installed Codex artwork at native menu-bar size.
@MainActor
func menuBarIcon() -> NSImage {
    if let url = Bundle.assets.url(forResource: "Codex", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
        image.size = NSSize(width: 18, height: 18)
        return image
    }
    return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex") ?? NSImage()
}

@MainActor
func openCodex() {
    let paths = ["/Applications/Codex.app", "/Applications/ChatGPT.app",
                 NSHomeDirectory() + "/Applications/Codex.app", NSHomeDirectory() + "/Applications/ChatGPT.app"]
    if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
    }
}

extension Bundle {
    static var assets: Bundle {
        if let resources = Bundle.main.resourceURL,
           let bundled = Bundle(url: resources.appendingPathComponent("CodexUsageBar_CodexUsageBar.bundle")) {
            return bundled
        }
        return .module
    }
}
