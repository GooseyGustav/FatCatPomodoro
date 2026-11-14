import SwiftUI
import AppKit
import Combine
import StoreKit

@main
struct IslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var storeManager = StoreManager.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "fatcatpomodoro"))
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: IslandWindow?
    var statusItem: NSStatusItem?
    var fullScreenWindow: NSWindow?
    var breakBorderWindow: NSWindow?
    var skipButtonWindow: NSWindow?
    var breakTimerWindow: NSWindow?
    var alertWindow: NSWindow?
    var extendPromptWindow: NSWindow?
    #if FATCAT_DIRECT
    var licenseWindow: NSWindow?
    #endif
    let pomodoroManager = PomodoroManager()
    private var cancellables = Set<AnyCancellable>()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            #if FATCAT_DIRECT
            if DirectLicenseManager.shared.handle(url: url) {
                showLicenseWindow()
                continue
            }
            #endif
            JarviManager.shared.handleDeepLink(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let iconURL = Bundle.main.url(forResource: "FatCatPomodoro", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }

        let contentView = IslandView(pomodoroManager: pomodoroManager)
        window = IslandWindow(contentView: AnyView(contentView))

        positionWindow()
        window?.makeKeyAndOrderFront(nil)

        setupFullScreenObserver()
        setupAlertObserver()
        setupExtendPromptObserver()
        setupScreenChangeObserver()
        setupHotkeys()
        setupStatusItem()
    }

    // MARK: - Menu bar extra (App Review Guideline 4: accessory apps need a menu bar presence)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "FatCatPomodoro")
                ?? NSImage(systemSymbolName: "timer", accessibilityDescription: "FatCatPomodoro")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self

        let stateItem = NSMenuItem(title: "FatCatPomodoro", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "Start Flow", action: #selector(menuToggleTimer), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let expandItem = NSMenuItem(title: "Open Island", action: #selector(menuToggleExpansion), keyEquivalent: "")
        expandItem.target = self
        menu.addItem(expandItem)

        #if FATCAT_DIRECT
        let licenseItem = NSMenuItem(title: "License…", action: #selector(menuLicense), keyEquivalent: "")
        licenseItem.target = self
        menu.addItem(licenseItem)
        #endif

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit FatCatPomodoro", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.count >= 3 else { return }
        if pomodoroManager.isRunning {
            let mode = pomodoroManager.sessionType == .work ? "Flow" : "Break"
            menu.items[0].title = "\(mode) — \(pomodoroManager.timeString)"
            menu.items[2].title = "Pause \(mode)"
        } else {
            menu.items[0].title = "FatCatPomodoro"
            menu.items[2].title = pomodoroManager.sessionType == .breakTime ? "Start Break" : "Start Flow"
        }
    }

    @objc private func menuToggleTimer() {
        pomodoroManager.toggle()
    }

    @objc private func menuToggleExpansion() {
        NotificationCenter.default.post(name: Notification.Name("ToggleIslandExpansion"), object: nil)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    #if FATCAT_DIRECT
    @objc private func menuLicense() {
        showLicenseWindow()
    }

    private func showLicenseWindow() {
        if licenseWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 470),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "FatCatPomodoro License"
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: DirectLicenseView(onClose: { [weak win] in
                win?.close()
            }))
            licenseWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        licenseWindow?.makeKeyAndOrderFront(nil)
    }
    #endif
    
    private func setupHotkeys() {
        HotkeyManager.shared.onToggleTimer = { [weak self] in
            DispatchQueue.main.async {
                self?.pomodoroManager.toggle()
            }
        }
        HotkeyManager.shared.onToggleExpansion = {
            DispatchQueue.main.async {
                // viaHotkey → the island activates the app and focuses the title
                // field so the user can type a session name immediately.
                NotificationCenter.default.post(name: Notification.Name("ToggleIslandExpansion"), object: nil, userInfo: ["viaHotkey": true])
            }
        }
        HotkeyManager.shared.onStartBreak = { [weak self] in
            DispatchQueue.main.async {
                guard let pm = self?.pomodoroManager else { return }
                if pm.sessionType == .work && (pm.isRunning || pm.hasActiveWorkSession) {
                    pm.skip() // finish the flow (logs elapsed) and roll into break
                } else if !(pm.isRunning && pm.sessionType == .breakTime) {
                    pm.startBreakWithActivity(pm.breakActivity)
                }
            }
        }
        HotkeyManager.shared.setup()
    }

    // Prefer the built-in MacBook display so the Island aligns with the physical notch
    private var notchScreen: NSScreen {
        let builtIn = NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        return builtIn ?? NSScreen.main ?? NSScreen.screens[0]
    }
    
    private func positionWindow() {
        let screen = notchScreen
        let r = screen.frame
        let w: CGFloat = 600
        let h: CGFloat = 420
        // Flush against the top edge on every display — the island hangs off the
        // screen edge like the physical notch, even on external monitors.
        window?.setFrame(NSRect(x: r.midX - w / 2, y: r.maxY - h, width: w, height: h), display: true)
    }

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.positionWindow()
            if let borderWin = self.breakBorderWindow {
                borderWin.setFrame(self.notchScreen.frame, display: true)
            }
        }
    }

    private func setupAlertObserver() {
        pomodoroManager.$showingAlert
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                // The Top Pill (ForegroundAlertView) doesn't have to show up
                /*
                if show {
                    self?.showForegroundAlert()
                } else
                */
                if !show {
                    self?.hideForegroundAlert()
                }
            }
            .store(in: &cancellables)
    }

    // One-minute warning: slides a small "extend?" pill in under the island.
    private func setupExtendPromptObserver() {
        pomodoroManager.$showExtendPrompt
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] show in
                if show {
                    self?.showExtendPrompt()
                } else {
                    self?.hideExtendPrompt()
                }
            }
            .store(in: &cancellables)
    }

    private func showExtendPrompt() {
        if extendPromptWindow == nil {
            let screen = notchScreen
            let w: CGFloat = 400
            let h: CGFloat = 56
            // A non-activating panel: the buttons are clickable but the prompt
            // never steals keyboard focus from whatever the user is doing.
            let win = NSPanel(
                contentRect: NSRect(x: screen.frame.midX - w / 2,
                                    y: screen.frame.maxY - h - 54,
                                    width: w, height: h),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 4)
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = true
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: ExtendPromptView(pomodoroManager: pomodoroManager))
            extendPromptWindow = win
        }
        extendPromptWindow?.orderFrontRegardless()
    }

    private func hideExtendPrompt() {
        extendPromptWindow?.orderOut(nil)
        extendPromptWindow = nil
    }

    private func showForegroundAlert() {
        if alertWindow == nil {
            let screen = notchScreen
            let w: CGFloat = 500
            let h: CGFloat = 160
            let alertWin = NSWindow(
                contentRect: NSRect(x: screen.frame.midX - w / 2,
                                   y: screen.frame.maxY - h - 100,
                                   width: w, height: h),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            alertWin.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 5)
            alertWin.backgroundColor = .clear
            alertWin.isOpaque = false
            alertWin.hasShadow = true
            alertWin.ignoresMouseEvents = false
            alertWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alertWin.contentView = IslandHostingView(rootView: ForegroundAlertView(pomodoroManager: pomodoroManager))
            self.alertWindow = alertWin
        }
        NSApp.activate(ignoringOtherApps: true)
        alertWindow?.orderFrontRegardless()
    }

    private func hideForegroundAlert() {
        NotificationManager.shared.stopAlarm()
        alertWindow?.orderOut(nil)
        alertWindow = nil
    }

    private func setupFullScreenObserver() {
        pomodoroManager.$isRunning
            .combineLatest(pomodoroManager.$sessionType)
            .sink { [weak self] isRunning, sessionType in
                let shouldShow = isRunning && sessionType == .breakTime
                if shouldShow {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if self?.pomodoroManager.isRunning == true && self?.pomodoroManager.sessionType == .breakTime {
                            self?.updateFullScreenVideo(show: true)
                        }
                    }
                } else {
                    self?.updateFullScreenVideo(show: false)
                }
            }
            .store(in: &cancellables)

        // React live when user toggles the break timer setting mid-break
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.pomodoroManager.isRunning,
                  self.pomodoroManager.sessionType == .breakTime else { return }
            self.syncBreakTimerOverlay()
        }
    }

    private func updateFullScreenVideo(show: Bool) {
        if show {
            let screen = notchScreen

            // 1. Break Border Window — 1-2 cm screen border highlight during dragging
            if breakBorderWindow == nil {
                let borderWin = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                borderWin.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
                borderWin.backgroundColor = .clear
                borderWin.isOpaque = false
                borderWin.hasShadow = false
                borderWin.ignoresMouseEvents = true
                borderWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                borderWin.contentView = NSHostingView(
                    rootView: BreakBorderOverlayView(coordinator: BreakCatDragCoordinator.shared)
                )
                self.breakBorderWindow = borderWin
            }
            breakBorderWindow?.orderFrontRegardless()

            // 2. Interactive Draggable Cat Window — enters maxed-out, drag & resize during the break
            if fullScreenWindow == nil {
                let baseW: CGFloat = 560
                let baseH: CGFloat = 315
                // The cat always enters at maximum size — practically the full
                // screen, like the original full-screen player. Saved
                // scale/position are deliberately ignored on entry so a
                // shrunken cat from a past break never carries over; dragging
                // and resizing still work for the duration of the break.
                let scale = min((screen.frame.width * 0.98) / baseW, (screen.frame.height * 0.88) / baseH)
                let catW = baseW * scale
                let catH = baseH * scale
                let startX = screen.frame.midX - catW / 2
                let startY = screen.frame.midY - catH / 2

                let swiftPMBundle: Bundle? = {
                    if let url = Bundle.main.url(forResource: "FatCatPomodoro_FatCatPomodoro", withExtension: "bundle") {
                        return Bundle(url: url)
                    }
                    return nil
                }()
                let hasProRes = Bundle.main.path(forResource: "cleancat_safari", ofType: "mov") != nil
                    || Bundle(for: AppDelegate.self).path(forResource: "cleancat_safari", ofType: "mov") != nil
                    || swiftPMBundle?.path(forResource: "cleancat_safari", ofType: "mov") != nil
                let (vidName, vidType) = hasProRes ? ("cleancat_safari", "mov") : ("cleancat", "mp4")

                let catWin = DraggableCatWindow(
                    contentRect: NSRect(x: startX, y: startY, width: catW, height: catH),
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                catWin.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                catWin.backgroundColor = .clear
                catWin.isOpaque = false
                catWin.hasShadow = false
                catWin.ignoresMouseEvents = false
                catWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                catWin.contentView = NSHostingView(
                    rootView: BreakCatOverlayView(
                        pomodoroManager: pomodoroManager,
                        window: catWin,
                        videoName: vidName,
                        videoType: vidType,
                        initialScale: scale
                    )
                )
                self.fullScreenWindow = catWin

                // Skip pill + activity chips — bottom center, clickable
                let btnW: CGFloat = 360
                let btnH: CGFloat = 80
                let skipWin = NSWindow(
                    contentRect: NSRect(x: screen.frame.midX - btnW / 2,
                                       y: screen.frame.minY + 20,
                                       width: btnW, height: btnH),
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                skipWin.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                skipWin.backgroundColor = .clear
                skipWin.isOpaque = false
                skipWin.hasShadow = true
                skipWin.ignoresMouseEvents = false
                skipWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                skipWin.contentView = NSHostingView(rootView: BreakSkipButton(pomodoroManager: pomodoroManager))
                self.skipButtonWindow = skipWin
            }
            fullScreenWindow?.orderFrontRegardless()
            skipButtonWindow?.orderFrontRegardless()
            syncBreakTimerOverlay()
        } else {
            fullScreenWindow?.orderOut(nil);   fullScreenWindow = nil
            breakBorderWindow?.orderOut(nil);  breakBorderWindow = nil
            skipButtonWindow?.orderOut(nil);   skipButtonWindow = nil
            breakTimerWindow?.orderOut(nil);   breakTimerWindow = nil
            BreakCatDragCoordinator.shared.update(isDragging: false, isExitZone: false)
        }
    }

    // Break timer overlay — top-left, translucent
    private func syncBreakTimerOverlay() {
        guard pomodoroManager.showBreakTimerOverlay else {
            breakTimerWindow?.orderOut(nil)
            breakTimerWindow = nil
            return
        }
        let screen = notchScreen
        // Window size tracks the remembered zoom — resizing changes the window
        // frame itself (like the break cat), not just scaled content in a
        // fixed frame.
        let savedScale = UserDefaults.standard.double(forKey: "pomodoro.breakOverlayScale")
        let scale = savedScale > 0 ? min(2.2, max(0.65, savedScale)) : 1.0
        let winW = BreakTimerOverlay.baseSize.width * scale
        let winH = BreakTimerOverlay.baseSize.height * scale

        let savedX = UserDefaults.standard.double(forKey: "pomodoro.breakOverlayX_v4")
        let savedY = UserDefaults.standard.double(forKey: "pomodoro.breakOverlayY_v4")
        let defaultX = screen.frame.origin.x + 150
        let defaultY = screen.frame.maxY - 100 - winH
        var startX = savedX != 0 ? savedX : defaultX
        var startY = savedY != 0 ? savedY : defaultY

        // Safety validation: Ensure the overlay window remains on screen
        if startY + winH > screen.frame.maxY || startY < screen.frame.origin.y {
            startY = defaultY
        }
        if startX < screen.frame.origin.x || startX + winW > screen.frame.maxX {
            startX = defaultX
        }

        if breakTimerWindow == nil {
            let timerWin = DraggableOverlayWindow(
                contentRect: NSRect(x: startX, y: startY, width: winW, height: winH),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            timerWin.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            timerWin.backgroundColor = .clear
            timerWin.isOpaque = false
            timerWin.hasShadow = false
            timerWin.isMovableByWindowBackground = true
            timerWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            timerWin.contentView = NSHostingView(rootView: BreakTimerOverlay(pomodoroManager: pomodoroManager, window: timerWin))
            self.breakTimerWindow = timerWin
        }
        breakTimerWindow?.orderFrontRegardless()
    }
}

class DraggableOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }
    
    @objc private func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(frame.origin.x, forKey: "pomodoro.breakOverlayX_v4")
        UserDefaults.standard.set(frame.origin.y, forKey: "pomodoro.breakOverlayY_v4")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Purchase anchoring
//
// Since macOS 15.2, StoreKit attaches every purchase confirmation to a "UI
// anchor" — a foreground-active, key-capable window. This app is .accessory
// with a non-activating overlay panel, so no valid anchor exists and purchases
// silently fail. The coordinator briefly shows a small titled window, promotes
// the app to .regular so it can activate, runs purchase(confirmIn:) against
// that window, then closes it and reverts to .accessory.
@MainActor
final class PurchaseCoordinator {
    static let shared = PurchaseCoordinator()
    private var anchorWindow: NSWindow?
    private var purchaseInFlight = false

    func purchase(_ product: Product) {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        Task {
            await self.run(product)
            self.purchaseInFlight = false
        }
    }

    private func run(_ product: Product) async {
        let win = makeAnchorWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        centerOnIslandScreen(win)
        win.makeKeyAndOrderFront(nil)
        do {
            try await StoreManager.shared.purchase(product, confirmIn: win)
        } catch {
            print("Purchase failed: \(error)")
        }
        win.close()
        anchorWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // Center the anchor window on the built-in (notch) display — same screen as
    // the island but clear of it, so Apple's purchase sheet never overlaps the
    // expanded island and never jumps to an external monitor.
    private func centerOnIslandScreen(_ win: NSWindow) {
        let builtIn = NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        guard let screen = builtIn ?? NSScreen.main else { win.center(); return }
        let f = screen.visibleFrame
        let s = win.frame.size
        // Slightly above center — the sheet drops downward from the anchor, so
        // this keeps the purchase card in the upper-middle of the screen without
        // touching the expanded island.
        win.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2 + f.height * 0.15))
    }

    private func makeAnchorWindow() -> NSWindow {
        if let anchorWindow { return anchorWindow }
        // Minimal dark chrome: the window exists only as the StoreKit anchor, so
        // it renders as a slim black strip that blends into the island above it.
        // (Don't shrink below the titlebar height — AppKit crashes on degenerate
        // titled-window geometry.)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "FatCatPomodoro"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        )
        anchorWindow = win
        return win
    }
}

// MARK: - Extend Prompt

/// Catches trackpad/mouse-wheel swipes over the extend-prompt window and
/// dismisses it with a slide-up + fade. Hit-test transparent; the monitor is
/// scoped to the prompt's own window.
private struct SwipeDismissCatcher: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> SwipeView {
        let view = SwipeView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: SwipeView, context: Context) {
        nsView.onDismiss = onDismiss
    }

    final class SwipeView: NSView {
        var onDismiss: (() -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var dismissing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    guard let self, event.window === self.window, !self.dismissing else { return event }
                    let delta = event.scrollingDeltaY
                    guard delta != 0 else { return event }
                    // Any decisive vertical swipe dismisses — direction isn't
                    // worth fighting natural-scrolling inversion over.
                    self.accumulated += abs(delta)
                    if self.accumulated > 30 {
                        self.slideOutAndDismiss()
                    }
                    return nil
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func slideOutAndDismiss() {
            dismissing = true
            guard let win = window else { onDismiss?(); return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                win.animator().alphaValue = 0
                var f = win.frame
                f.origin.y += 36
                win.animator().setFrame(f, display: true)
            }, completionHandler: { [weak self] in
                self?.onDismiss?()
                self?.accumulated = 0
                self?.dismissing = false
            })
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One-minute warning pill: "Flow/Break ends in 1 min — +1 +2 +5 ✕".
/// Buttons call PomodoroManager.extendSession(by:), which also dismisses it;
/// swiping over the pill slides it away.
struct ExtendPromptView: View {
    @ObservedObject var pomodoroManager: PomodoroManager

    private func extendButton(_ minutes: Int) -> some View {
        Button(action: { pomodoroManager.extendSession(by: minutes) }) {
            Text("+\(minutes)m")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.9))
                .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help("Extend by \(minutes) minute\(minutes == 1 ? "" : "s")")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.orange)

            Text(pomodoroManager.sessionType == .work ? "Flow ends in 1 min" : "Break ends in 1 min")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            extendButton(1)
            extendButton(2)
            extendButton(5)

            Button(action: { pomodoroManager.showExtendPrompt = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Dismiss (or swipe over the pill)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            ZStack {
                Capsule().fill(Color.black.opacity(0.55))
                Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
        }
        .background(SwipeDismissCatcher { pomodoroManager.showExtendPrompt = false })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Break Screen Views

struct ForegroundAlertView: View {
    @ObservedObject var pomodoroManager: PomodoroManager

    var body: some View {
        HStack(spacing: 24) {
            let alarmImage = Image(systemName: "alarm.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            
            if #available(macOS 15.0, *) {
                alarmImage.symbolEffect(.bounce, options: .repeating)
            } else {
                alarmImage
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(pomodoroManager.alertTitle)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(.white)

                Text(pomodoroManager.alertMessage)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            Button(action: {
                pomodoroManager.showingAlert = false
            }) {
                Text("DONE")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color.orange)
                    .clipShape(Capsule())
                    .shadow(color: .orange.opacity(0.4), radius: 10)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color.black.opacity(0.9))
                
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(LinearGradient(colors: [.orange, .orange.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
            }
        }
    }
}

struct BreakSkipButton: View {
    @ObservedObject var pomodoroManager: PomodoroManager

    var body: some View {
        VStack(spacing: 10) {
            // Activity chips row
            HStack(spacing: 8) {
                ForEach(["Stretch", "Hydrate", "Walk", "Breathe"], id: \.self) { activity in
                    let isSelected = pomodoroManager.breakActivity == activity
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if pomodoroManager.isRunning && pomodoroManager.sessionType == .breakTime {
                                pomodoroManager.breakActivity = activity
                                if pomodoroManager.breakSessionStart == nil {
                                    pomodoroManager.breakSessionStart = Date()
                                }
                            } else {
                                pomodoroManager.startBreakWithActivity(activity)
                            }
                        }
                    } label: {
                        Text(activity)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(isSelected ? .orange : .white.opacity(0.55))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.orange.opacity(0.2) : Color.black.opacity(0.5))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(isSelected ? Color.orange.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(pomodoroManager.isRunning ? "Tag this break as: \(activity)" : "Start break: \(activity)")
                }
            }

            // Skip Break button
            Button(action: { pomodoroManager.skip() }) {
                HStack(spacing: 6) {
                    Text("Skip Break")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Image(systemName: "forward.fill")
                        .font(.system(size: 10))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.6))
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

/// Catches scroll events over the break-overlay window and turns them into
/// zoom deltas (two-finger scroll on trackpad, wheel on a mouse). The view is
/// hit-test transparent; the whole window is the overlay, so window-scoped
/// interception is safe.
private struct ScrollZoomCatcher: NSViewRepresentable {
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ZoomView, context: Context) {
        nsView.onZoom = onZoom
    }

    final class ZoomView: NSView {
        var onZoom: ((Double) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    guard let self, event.window === self.window else { return event }
                    let delta = event.scrollingDeltaY
                    guard delta != 0 else { return event }
                    // Trackpad: smooth proportional zoom; mouse wheel: 0.1 per notch. Scroll up → bigger.
                    let step = event.hasPreciseScrollingDeltas ? delta * 0.004 : (delta > 0 ? 0.1 : -0.1)
                    self.onZoom?(step)
                    return nil
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Two-finger scroll over the break-timer overlay moves the window — it
/// follows the fingers like dragging — while zooming stays on pinch and the
/// hover ± buttons. Hit-test transparent, scoped to its own window.
private struct ScrollMoveCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> MoveView { MoveView() }
    func updateNSView(_ nsView: MoveView, context: Context) {}

    final class MoveView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    guard let self, let win = self.window, event.window === win else { return event }
                    let dx = event.scrollingDeltaX
                    let dy = event.scrollingDeltaY
                    guard dx != 0 || dy != 0 else { return event }
                    // Natural scrolling reports deltas content-wise; flip for
                    // traditional wheels so the window always follows the fingers.
                    let m: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
                    var origin = win.frame.origin
                    origin.x -= dx * m
                    origin.y -= dy * m
                    win.setFrameOrigin(origin)
                    return nil
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct BreakTimerOverlay: View {
    @ObservedObject var pomodoroManager: PomodoroManager
    weak var window: NSWindow?
    @AppStorage("pomodoro.breakOverlayScale") private var scale: Double = 1.0
    @State private var isPulsing = false
    @State private var isHovering = false
    @State private var hoveredZoomButton: String? = nil
    @State private var pinchBaseScale: Double? = nil

    /// Window size at scale 1 — the window frame is baseSize × scale, so
    /// zooming resizes the actual window (like the break cat), not just the
    /// content inside a fixed frame.
    static let baseSize = NSSize(width: 400, height: 185)

    private func clampScale(_ value: Double) -> Double {
        min(2.2, max(0.65, value))
    }

    /// Apply a new zoom: persist it and resize the window keeping the top-left
    /// corner anchored, so the overlay grows toward the screen center instead
    /// of walking off the top edge.
    private func applyScale(_ newScale: Double) {
        let clamped = clampScale(newScale)
        scale = clamped
        guard let win = window else { return }
        let newW = Self.baseSize.width * clamped
        let newH = Self.baseSize.height * clamped
        win.setFrame(NSRect(x: win.frame.minX, y: win.frame.maxY - newH, width: newW, height: newH), display: true)
    }

    /// Generous hit area + orange hover so it reads as clickable and survives
    /// the overlay growing/shrinking under the cursor.
    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(hoveredZoomButton == symbol ? .orange : .white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(hoveredZoomButton == symbol ? Color.orange.opacity(0.18) : Color.clear)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                if hovering {
                    hoveredZoomButton = symbol
                } else if hoveredZoomButton == symbol {
                    hoveredZoomButton = nil
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // A glowing orange dot indicating active state
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: .orange.opacity(0.6), radius: 4)
                    .opacity(isPulsing ? 0.3 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
                
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(pomodoroManager.breakActivity.isEmpty ? "REST TIME" : pomodoroManager.breakActivity.uppercased() + " BREAK")
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .foregroundColor(.orange)
                            .tracking(1.5)
                            .fixedSize(horizontal: true, vertical: false)
                        
                        if isHovering {
                            HStack(spacing: 2) {
                                zoomButton("minus") { applyScale(scale - 0.1) }
                                zoomButton("plus") { applyScale(scale + 0.1) }
                            }
                            .transition(.opacity)
                        }
                    }

                    Text(pomodoroManager.timeString)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            // Activity chips
            HStack(spacing: 6) {
                ForEach(["Stretch", "Hydrate", "Walk", "Breathe"], id: \.self) { activity in
                    let isSelected = pomodoroManager.breakActivity == activity
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            pomodoroManager.breakActivity = activity
                            if pomodoroManager.breakSessionStart == nil {
                                pomodoroManager.breakSessionStart = Date()
                            }
                        }
                    } label: {
                        Text(activity)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(isSelected ? .orange : .white.opacity(0.4))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.orange.opacity(0.2) : Color.white.opacity(0.06))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(isSelected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Tag this break as: \(activity)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LinearGradient(colors: [.orange.opacity(0.4), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
        }
        .scaleEffect(scale, anchor: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hover
            }
        }
        .gesture(
            // Pinch in/out — anchored to the scale at gesture start so it
            // doesn't compound per-event and run away.
            MagnificationGesture()
                .onChanged { val in
                    if pinchBaseScale == nil { pinchBaseScale = scale }
                    applyScale((pinchBaseScale ?? scale) * val)
                }
                .onEnded { _ in pinchBaseScale = nil }
        )
        .background(
            // Two-finger scroll moves the overlay; resizing is pinch / ± only.
            ScrollMoveCatcher()
        )
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Break Cat Dragging & Screen Border Overlay

final class BreakCatDragCoordinator: ObservableObject {
    static let shared = BreakCatDragCoordinator()
    
    @Published var isDragging: Bool = false
    @Published var isExitZone: Bool = false
    
    func update(isDragging: Bool, isExitZone: Bool) {
        if self.isDragging != isDragging || self.isExitZone != isExitZone {
            DispatchQueue.main.async {
                self.isDragging = isDragging
                self.isExitZone = isExitZone
            }
        }
    }
}

class DraggableCatWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

struct DraggableArea: NSViewRepresentable {
    weak var window: NSWindow?
    let onEndBreak: () -> Void
    let onResetScale: () -> Void
    
    func makeNSView(context: Context) -> DragNSView {
        let view = DragNSView()
        view.targetWindow = window
        view.onEndBreak = onEndBreak
        view.onResetScale = onResetScale
        return view
    }
    
    func updateNSView(_ nsView: DragNSView, context: Context) {
        nsView.targetWindow = window
        nsView.onEndBreak = onEndBreak
        nsView.onResetScale = onResetScale
    }
}

class DragNSView: NSView {
    weak var targetWindow: NSWindow?
    var onEndBreak: (() -> Void)?
    var onResetScale: (() -> Void)?
    
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var isDragging = false
    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        if !isDragging && !isMouseInside {
            isMouseInside = true
            NSCursor.openHand.push()
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if isMouseInside && !isDragging {
            isMouseInside = false
            NSCursor.pop()
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onResetScale?()
            return
        }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = targetWindow?.frame.origin ?? window?.frame.origin
        isDragging = true
        NSCursor.closedHand.push()
        BreakCatDragCoordinator.shared.update(isDragging: true, isExitZone: false)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isDragging,
              let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartWindowOrigin,
              let win = targetWindow ?? window else { return }
        
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        
        let newOrigin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        win.setFrameOrigin(newOrigin)
        
        let activeScreen = NSScreen.screens.first { NSMouseInRect(currentMouse, $0.frame, false) }
            ?? win.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let sFrame = activeScreen.frame
        
        // 1-2 cm border threshold (approx 52 points, ~1.8 cm)
        let borderThreshold: CGFloat = 52.0
        
        let mouseInBorder = currentMouse.x < sFrame.minX + borderThreshold ||
                            currentMouse.x > sFrame.maxX - borderThreshold ||
                            currentMouse.y < sFrame.minY + borderThreshold ||
                            currentMouse.y > sFrame.maxY - borderThreshold
        
        let catInBorder = win.frame.minX < sFrame.minX + borderThreshold ||
                          win.frame.maxX > sFrame.maxX - borderThreshold ||
                          win.frame.minY < sFrame.minY + borderThreshold ||
                          win.frame.maxY > sFrame.maxY - borderThreshold
        
        let isExit = mouseInBorder || catInBorder
        BreakCatDragCoordinator.shared.update(isDragging: true, isExitZone: isExit)
    }
    
    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop() // pop closedHand
        if isMouseInside {
            isMouseInside = false
            NSCursor.pop() // pop openHand
        }
        
        let inExitZone = BreakCatDragCoordinator.shared.isExitZone
        BreakCatDragCoordinator.shared.update(isDragging: false, isExitZone: false)
        
        if inExitZone {
            if let win = targetWindow ?? window {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    win.animator().alphaValue = 0.0
                }, completionHandler: { [weak self] in
                    self?.onEndBreak?()
                })
            } else {
                onEndBreak?()
            }
        } else if let win = targetWindow ?? window {
            UserDefaults.standard.set(win.frame.origin.x, forKey: "pomodoro.breakCatX_v1")
            UserDefaults.standard.set(win.frame.origin.y, forKey: "pomodoro.breakCatY_v1")
        }
        
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }
}

struct BreakBorderOverlayView: View {
    @ObservedObject var coordinator: BreakCatDragCoordinator
    @State private var pulse = false
    
    var body: some View {
        GeometryReader { geo in
            let borderThickness: CGFloat = 52.0 // ~1.8 cm
            
            ZStack {
                if coordinator.isDragging {
                    if coordinator.isExitZone {
                        // Edge glow gradients on all 4 borders
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.22, blue: 0.15).opacity(0.85), Color.orange.opacity(0.45), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: borderThickness)
                            
                            Spacer()
                            
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.22, blue: 0.15).opacity(0.85), Color.orange.opacity(0.45), Color.clear],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                            .frame(height: borderThickness)
                        }
                        
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.22, blue: 0.15).opacity(0.85), Color.orange.opacity(0.45), Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: borderThickness)
                            
                            Spacer()
                            
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.22, blue: 0.15).opacity(0.85), Color.orange.opacity(0.45), Color.clear],
                                startPoint: .trailing,
                                endPoint: .leading
                            )
                            .frame(width: borderThickness)
                        }
                        
                        // Solid energetic perimeter border
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.red, Color.orange, Color.red],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 4
                            )
                            .shadow(color: Color.red.opacity(0.8), radius: 16)
                            .padding(2)
                        
                        // Exit Alert Badge
                        VStack {
                            HStack(spacing: 10) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16, weight: .black))
                                    .foregroundColor(.white)
                                Text("RELEASE TO END BREAK")
                                    .font(.system(size: 13, weight: .black, design: .rounded))
                                    .tracking(1.4)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(LinearGradient(colors: [Color.red.opacity(0.95), Color.orange.opacity(0.95)], startPoint: .leading, endPoint: .trailing))
                                    .shadow(color: Color.red.opacity(0.7), radius: 16, x: 0, y: 4)
                                    .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1.5))
                            )
                            .scaleEffect(pulse ? 1.04 : 0.98)
                            .padding(.top, borderThickness + 18)
                            
                            Spacer()
                        }
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        // Safe dragging mode: subtle dashed guide showing where the exit border begins
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                Color.orange.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
                            )
                            .padding(borderThickness)
                        
                        VStack {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.draw.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                Text("Drag cat to screen edge to end break")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.75))
                                    .overlay(Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1))
                            )
                            .padding(.top, borderThickness + 14)
                            
                            Spacer()
                        }
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: coordinator.isDragging)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: coordinator.isExitZone)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct BreakCatOverlayView: View {
    @ObservedObject var pomodoroManager: PomodoroManager
    weak var window: NSWindow?
    let videoName: String
    let videoType: String
    
    @State private var scale: Double
    @State private var isHovering = false
    @State private var hoveredControl: String? = nil
    @State private var pinchBaseScale: Double? = nil
    @ObservedObject private var dragCoordinator = BreakCatDragCoordinator.shared
    
    init(pomodoroManager: PomodoroManager, window: NSWindow?, videoName: String, videoType: String, initialScale: Double) {
        self.pomodoroManager = pomodoroManager
        self.window = window
        self.videoName = videoName
        self.videoType = videoType
        _scale = State(initialValue: initialScale)
    }
    
    private func clampScale(_ value: Double) -> Double {
        // Upper bound must stay above the full-screen entry scale (≈2.6 on a
        // MacBook display) or the first zoom gesture would snap the cat down.
        min(4.5, max(0.45, value))
    }

    private func applyScale(_ newScale: Double) {
        let clamped = clampScale(newScale)
        scale = clamped
        UserDefaults.standard.set(clamped, forKey: "pomodoro.breakCatScale_v1")
        
        guard let win = window else { return }
        let baseW: CGFloat = 560
        let baseH: CGFloat = 315
        let newW = baseW * clamped
        let newH = baseH * clamped
        
        let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
        let newOrigin = NSPoint(x: center.x - newW / 2, y: center.y - newH / 2)
        win.setFrame(NSRect(origin: newOrigin, size: NSSize(width: newW, height: newH)), display: true)
        
        UserDefaults.standard.set(newOrigin.x, forKey: "pomodoro.breakCatX_v1")
        UserDefaults.standard.set(newOrigin.y, forKey: "pomodoro.breakCatY_v1")
    }
    
    private func recenter() {
        guard let win = window else { return }
        let screen = win.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let centerX = screen.frame.midX - win.frame.width / 2
        let centerY = screen.frame.midY - win.frame.height / 2
        win.setFrameOrigin(NSPoint(x: centerX, y: centerY))
        UserDefaults.standard.set(centerX, forKey: "pomodoro.breakCatX_v1")
        UserDefaults.standard.set(centerY, forKey: "pomodoro.breakCatY_v1")
    }
    
    private func controlButton(symbol: String, id: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(hoveredControl == id ? .orange : .white.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(hoveredControl == id ? Color.orange.opacity(0.2) : Color.black.opacity(0.6))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.12)) {
                if hover { hoveredControl = id }
                else if hoveredControl == id { hoveredControl = nil }
            }
        }
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Background drag receiver (handles mouse down, drag, up, double click)
            DraggableArea(
                window: window,
                onEndBreak: {
                    pomodoroManager.skip()
                },
                onResetScale: {
                    applyScale(1.0)
                }
            )
            
            // Cat Video Player
            LoopingVideoPlayer(videoName: videoName, videoType: videoType)
                .allowsHitTesting(false)
                .opacity(dragCoordinator.isExitZone ? 0.75 : 1.0)
                .scaleEffect(dragCoordinator.isExitZone ? 0.94 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: dragCoordinator.isExitZone)
            
            // Subtle boundary feedback on hover / drag
            if isHovering || dragCoordinator.isDragging {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        dragCoordinator.isExitZone ? Color.red.opacity(0.8) : Color.white.opacity(0.18),
                        lineWidth: dragCoordinator.isExitZone ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
            
            // Hover controls: Zoom Out, Zoom In, Recenter
            if isHovering && !dragCoordinator.isDragging {
                HStack(spacing: 5) {
                    controlButton(symbol: "minus", id: "zoomOut", help: "Make cat smaller") {
                        applyScale(scale - 0.1)
                    }
                    controlButton(symbol: "plus", id: "zoomIn", help: "Make cat bigger") {
                        applyScale(scale + 0.1)
                    }
                    controlButton(symbol: "scope", id: "center", help: "Center cat on screen") {
                        recenter()
                    }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { val in
                    if pinchBaseScale == nil { pinchBaseScale = scale }
                    applyScale((pinchBaseScale ?? scale) * val)
                }
                .onEnded { _ in pinchBaseScale = nil }
        )
        .background(
            ScrollZoomCatcher { delta in
                applyScale(scale + delta)
            }
        )
    }
}

