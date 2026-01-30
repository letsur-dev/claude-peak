import SwiftUI
import AppKit
import Combine

@main
struct ClaudePeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var service: UsageService!
    private var settings: AppSettings!
    private var activity: ActivityMonitor!
    private var updateChecker: UpdateChecker!
    private var animationTimer: Timer?
    private var displayTimer: Timer?
    private var frameIndex = 0
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Claude Peak launched")
        service = UsageService()
        settings = AppSettings.shared
        activity = ActivityMonitor()
        updateChecker = UpdateChecker()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsageView(service: service, settings: settings, activity: activity, updateChecker: updateChecker)
                .frame(width: 280)
        )

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        updateMenuBar()

        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMenuBar()
            }
        }

        activity.$tokensPerSecond.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAnimationSpeed()
            }
        }.store(in: &cancellables)

        settings.$flameMode.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMenuBar()
                self?.updateAnimationSpeed()
            }
        }.store(in: &cancellables)

        service.startPolling()
        activity.start()
        Task { await updateChecker.check() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Flame Rendering

    private func flameCount(for tps: Double) -> Int {
        switch settings.flameMode {
        case .off:
            return 0
        case .single:
            return tps > 0 ? 1 : 0
        case .dynamic:
            if tps > 60000 { return 3 }
            if tps > 30000 { return 2 }
            if tps > 0     { return 1 }
            return 0
        case .madmax:
            if tps <= 0 { return 0 }
            return min(10, Int(tps / 10000) + 1)
        }
    }

    private func createFlameImage(count: Int, frame: Int) -> NSImage {
        let size: CGFloat = 18
        let overlap: CGFloat = 6
        let totalWidth = count == 0 ? size : size + CGFloat(count - 1) * (size - overlap)

        let image = NSImage(size: NSSize(width: totalWidth, height: size))
        image.lockFocus()

        for i in 0..<count {
            // Each flame flickers independently using offset frame
            let flicker = (frame + i * 2) % 4
            let symbolName: String
            let pointSize: CGFloat

            switch flicker {
            case 0:
                symbolName = "flame.fill"
                pointSize = 14
            case 1:
                symbolName = "flame.fill"
                pointSize = 12
            case 2:
                symbolName = "flame"
                pointSize = 13
            default:
                symbolName = "flame.fill"
                pointSize = 15
            }

            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let x = CGFloat(i) * (size - overlap)
                let yOffset = (size - pointSize) / 2
                symbol.draw(in: NSRect(x: x, y: yOffset, width: pointSize, height: pointSize))
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Update

    private func updateMenuBar() {
        guard let button = statusItem.button else { return }

        if settings.flameMode != .off {
            let tps = activity.tokensPerSecond
            let count = flameCount(for: tps)

            if count > 0 {
                button.image = createFlameImage(count: count, frame: frameIndex)
            } else {
                // Tiny static ember
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .light)
                let image = NSImage(systemSymbolName: "flame", accessibilityDescription: "usage")?
                    .withSymbolConfiguration(config)
                image?.isTemplate = true
                button.image = image
            }
        } else {
            button.image = nil
        }

        guard let usage = service.usage else {
            button.title = " —"
            return
        }

        switch settings.menuBarDisplay {
        case .percentOnly:
            button.title = " \(usage.fiveHour.percentage)%"
        case .timeOnly:
            button.title = " \(usage.fiveHour.timeUntilReset)"
        case .both:
            button.title = " \(usage.fiveHour.percentage)% · \(usage.fiveHour.timeUntilReset)"
        }
    }

    private func animationInterval(for tps: Double) -> TimeInterval? {
        guard tps > 0 else { return nil }

        if settings.flameMode == .madmax {
            // 0.50s at low tps → 0.08s at 100000+
            let t = min(tps / 100000, 1.0)
            return 0.50 - t * 0.42
        }

        if tps > 60000 {
            // 3 flames: 0.40s → 0.10s
            let t = min((tps - 60000) / 40000, 1.0)
            return 0.40 - t * 0.30
        } else if tps > 30000 {
            // 2 flames: 0.50s → 0.25s
            let t = (tps - 30000) / 30000
            return 0.50 - t * 0.25
        } else {
            // 1 flame: 0.70s → 0.30s
            let t = min(tps / 30000, 1.0)
            return 0.70 - t * 0.40
        }
    }

    private func updateAnimationSpeed() {
        animationTimer?.invalidate()
        animationTimer = nil

        guard settings.flameMode != .off else { return }

        let tps = activity.tokensPerSecond
        guard let interval = animationInterval(for: tps) else { return }

        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.frameIndex += 1
                self?.updateMenuBar()
            }
        }
    }
}
