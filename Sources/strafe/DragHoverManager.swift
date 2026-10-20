import AppKit
import ApplicationServices
import CStrafe

/// Dwell-time presets before switching to a hovered Dock app, in-app tab, or
/// background window during an active drag-and-drop session.
///
/// Users can pick one of these presets in the menu bar or pass any integer
/// millisecond value in `0...200` to `strafe drag <ms>`.
enum DragHoverDelay: Int, CaseIterable {
    case zero    = 0
    case instant = 25
    case fast    = 75
    case quick   = 125
    case max     = 200

    static let `default`: DragHoverDelay = .instant
    static let validRange: ClosedRange<Int> = 0...200

    var title: String {
        switch self {
        case .zero:    return "Zero (0 ms)"
        case .instant: return "Instant (25 ms)"
        case .fast:    return "Fast (75 ms)"
        case .quick:   return "Quick (125 ms)"
        case .max:     return "Max (200 ms)"
        }
    }

    var name: String {
        switch self {
        case .zero:    return "zero"
        case .instant: return "instant"
        case .fast:    return "fast"
        case .quick:   return "quick"
        case .max:     return "max"
        }
    }

    init?(name: String) {
        guard let match = DragHoverDelay.allCases.first(where: { $0.name == name })
        else { return nil }
        self = match
    }

    static func clamp(_ milliseconds: Int) -> Int {
        Swift.min(Swift.max(milliseconds, validRange.lowerBound), validRange.upperBound)
    }

    static func parseMilliseconds(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let preset = DragHoverDelay(name: trimmed) {
            return preset.rawValue
        }
        let numeric = trimmed.hasSuffix("ms") ? String(trimmed.dropLast(2)) : trimmed
        guard let value = Int(numeric) else { return nil }
        return clamp(value)
    }

    static func describe(_ milliseconds: Int) -> String {
        if let preset = DragHoverDelay(rawValue: milliseconds) {
            return preset.title
        }
        return "\(milliseconds) ms"
    }
}

/// Removes the ~1.3–2.0 second macOS spring-loading wait when dragging a file
/// or object onto a Dock application icon, an in-app tab, or a background window.
///
/// Uses a passive `NSEvent` global mouse monitor gated on `NSPasteboard(name: .drag).changeCount`
/// (an integer counter that increments only when a system Drag & Drop session
/// starts; pasteboard types and contents are never read). Ordinary mouse drags
/// (text selection, window move/resize, scrollbars) do not change the drag
/// pasteboard count and exit immediately.
@MainActor
final class DragHoverManager {
    enum Target: Equatable {
        case dockApp(title: String, bundleURL: URL?, element: AXUIElement)
        case tab(pid: pid_t, windowID: UInt32, isFrontmostWindow: Bool, element: AXUIElement)
        case backgroundWindow(windowID: UInt32, pid: pid_t)

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) {
            case let (.dockApp(t1, u1, e1), .dockApp(t2, u2, e2)):
                return CFEqual(e1, e2) || (t1 == t2 && u1 == u2)
            case let (.tab(p1, w1, _, e1), .tab(p2, w2, _, e2)):
                return p1 == p2 && w1 == w2 && CFEqual(e1, e2)
            case let (.backgroundWindow(w1, p1), .backgroundWindow(w2, p2)):
                return w1 == w2 && p1 == p2
            default:
                return false
            }
        }
    }

    // MARK: - Persistence

    nonisolated static let enabledStorageKey = "dragHoverEnabled"
    nonisolated static let delayStorageKey   = "dragHoverDelayMs"

    nonisolated private static let settingsChanged = Notification.Name(
        "com.rileycx.strafe.dragHoverChanged"
    )

    nonisolated static var enabled: Bool {
        Preferences.store.object(forKey: enabledStorageKey) as? Bool ?? true
    }

    nonisolated static var delayMs: Int {
        guard let raw = Preferences.store.object(forKey: delayStorageKey) as? Int else {
            return DragHoverDelay.default.rawValue
        }
        return DragHoverDelay.clamp(raw)
    }

    nonisolated static func persist(enabled: Bool) {
        Preferences.store.set(enabled, forKey: enabledStorageKey)
        notifySettingsChanged()
    }

    nonisolated static func persist(delayMs: Int) {
        Preferences.store.set(DragHoverDelay.clamp(delayMs), forKey: delayStorageKey)
        notifySettingsChanged()
    }

    nonisolated private static func notifySettingsChanged() {
        Preferences.store.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            settingsChanged, object: Preferences.domain, userInfo: nil, deliverImmediately: true
        )
    }

    // MARK: - State

    private let targetResolver: ((CGPoint) -> Target?)?
    private let targetActivator: ((Target) -> Void)?

    private var globalMouseMonitor: Any?
    private var settingsObserver: (any NSObjectProtocol)?
    private var hoverTimer: DispatchSourceTimer?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var baselinePasteboardCount: Int = 0
    private var isDragSessionActive = false
    private var dragStartedOnTab = false
    private var dragStartPID: pid_t = 0
    private var lastCursorPoint: CGPoint = .zero

    private var currentTarget: Target?
    private var lastActivatedTarget: Target?
    private var manualAXInitializedPIDs = Set<pid_t>()

    /// Cursor movement above this distance per drag tick indicates transit
    /// across the screen rather than settling on a target.
    private static let transitStepThreshold: CGFloat = 8.0

    init(
        targetResolver: ((CGPoint) -> Target?)? = nil,
        targetActivator: ((Target) -> Void)? = nil
    ) {
        self.targetResolver = targetResolver
        self.targetActivator = targetActivator
        self.baselinePasteboardCount = dragPasteboard.changeCount
    }

    func start() {
        if settingsObserver == nil {
            settingsObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.settingsChanged, object: Preferences.domain, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.settingsObserver != nil else { return }
                    self.applyStoredState()
                }
            }
        }
        applyStoredState()
    }

    func stop() {
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        removeMonitor()
    }

    func applyStoredState() {
        Preferences.store.synchronize()
        if Self.enabled {
            installMonitorIfNeeded()
        } else {
            removeMonitor()
        }
    }

    // MARK: - Event monitor

    private func installMonitorIfNeeded() {
        guard globalMouseMonitor == nil else { return }
        baselinePasteboardCount = dragPasteboard.changeCount
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseEvent(event)
            }
        }
    }

    private func removeMonitor() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        endDragSession()
    }

    func beginDragCandidate(at point: CGPoint, startedOnTab: Bool, startPID: pid_t) {
        cancelHoverTimer()
        isDragSessionActive = false
        currentTarget = nil
        lastActivatedTarget = nil
        lastCursorPoint = point
        dragStartedOnTab = startedOnTab
        dragStartPID = startPID
    }

    func endDragSession() {
        cancelHoverTimer()
        isDragSessionActive = false
        dragStartedOnTab = false
        dragStartPID = 0
        currentTarget = nil
        lastActivatedTarget = nil
        baselinePasteboardCount = dragPasteboard.changeCount
    }

    func handleDragMoved(to point: CGPoint, delayMs: Int = DragHoverManager.delayMs) {
        isDragSessionActive = true
        let stepDistance = hypot(point.x - lastCursorPoint.x, point.y - lastCursorPoint.y)
        lastCursorPoint = point

        let resolved = targetResolver?(point) ?? resolveTarget(at: point)
        guard let target = resolved else {
            if currentTarget != nil {
                currentTarget = nil
                cancelHoverTimer()
            }
            return
        }

        if target == lastActivatedTarget {
            cancelHoverTimer()
            return
        }

        let movingFast = stepDistance > Self.transitStepThreshold
        if target != currentTarget {
            currentTarget = target
            scheduleHoverTimer(for: target, delayMs: delayMs, isMovingFast: movingFast)
        } else if movingFast {
            scheduleHoverTimer(for: target, delayMs: delayMs, isMovingFast: true)
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard Self.enabled, Permissions.isAccessibilityGranted else { return }

        switch event.type {
        case .leftMouseDown:
            let pt = strafe_cursor_location()
            var winID: UInt32 = 0
            var ownerPID: Int32 = 0
            var isFront = false
            let hitWindow = strafe_window_at_point(pt, &winID, &ownerPID, &isFront) && ownerPID > 0
            let onTab = hitWindow && resolveTab(at: pt, pid: ownerPID) != nil
            beginDragCandidate(at: pt, startedOnTab: onTab, startPID: hitWindow ? ownerPID : 0)

        case .leftMouseDragged:
            if !isDragSessionActive {
                guard dragPasteboard.changeCount != baselinePasteboardCount else { return }
            }
            handleDragMoved(to: strafe_cursor_location())

        case .leftMouseUp:
            endDragSession()

        default:
            break
        }
    }

    // MARK: - Dwell timer

    private func cancelHoverTimer() {
        hoverTimer?.cancel()
        hoverTimer = nil
    }

    private func scheduleHoverTimer(for target: Target, delayMs: Int, isMovingFast: Bool) {
        cancelHoverTimer()

        // At 0 ms, fire immediately once the cursor has settled on the target;
        // if still moving fast (> 8 pt/tick), wait 18 ms so sweeping across the
        // Dock does not activate intermediate icons along the path.
        let effectiveMs = delayMs == 0 ? (isMovingFast ? 18 : 0) : delayMs
        if effectiveMs == 0 {
            activate(target)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(effectiveMs))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isDragSessionActive, self.currentTarget == target else {
                    return
                }
                self.hoverTimer = nil
                self.activate(target)
            }
        }
        hoverTimer = timer
        timer.resume()
    }

    // MARK: - Target resolution

    private enum DockHit {
        case none
        case app(Target)
        case nonAppSurface
    }

    private func resolveTarget(at point: CGPoint) -> Target? {
        switch resolveDockHit(at: point) {
        case let .app(target):
            return target
        case .nonAppSurface:
            // Cursor is over another Dock item (Trash, folder stack) or a
            // Mission Control / App Exposé surface; do not match windows below.
            return nil
        case .none:
            break
        }

        var windowID: UInt32 = 0
        var ownerPID: Int32 = 0
        var isFrontmost = false
        guard strafe_window_at_point(point, &windowID, &ownerPID, &isFrontmost),
              ownerPID > 0 else {
            return nil
        }

        if !(dragStartedOnTab && ownerPID == dragStartPID),
           let tabElement = resolveTab(at: point, pid: ownerPID),
           !isTabSelected(tabElement) {
            return .tab(
                pid: ownerPID,
                windowID: windowID,
                isFrontmostWindow: isFrontmost,
                element: tabElement
            )
        }

        if !isFrontmost {
            return .backgroundWindow(windowID: windowID, pid: ownerPID)
        }

        return nil
    }

    private func resolveDockHit(at point: CGPoint) -> DockHit {
        guard let dockApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else {
            return .none
        }
        let axDock = AXUIElementCreateApplication(dockApp.processIdentifier)
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(axDock, Float(point.x), Float(point.y), &hitRef) == .success,
              let hit = hitRef else {
            return .none
        }

        var cursor: AXUIElement? = hit
        for _ in 0..<4 {
            guard let elem = cursor else { break }
            if axString(elem, kAXRoleAttribute) == "AXDockItem",
               axString(elem, kAXSubroleAttribute) == "AXApplicationDockItem" {
                let title = axString(elem, kAXTitleAttribute) ?? ""
                let bundleURL = (axValue(elem, kAXURLAttribute) as? URL)?.standardizedFileURL
                return .app(.dockApp(title: title, bundleURL: bundleURL, element: elem))
            }
            cursor = axParent(of: elem)
        }
        return .nonAppSurface
    }

    private func resolveTab(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        if !manualAXInitializedPIDs.contains(pid) {
            manualAXInitializedPIDs.insert(pid)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &hitRef) == .success,
              let hit = hitRef else {
            return nil
        }

        // Never treat a tab's close button as a tab-switch target.
        let hitRole = axString(hit, kAXRoleAttribute) ?? ""
        let hitSubrole = axString(hit, kAXSubroleAttribute) ?? ""
        let hitTitle = (axString(hit, kAXTitleAttribute) ?? "").lowercased()
        let hitDesc = (axString(hit, kAXDescriptionAttribute) ?? "").lowercased()
        if hitSubrole == "AXCloseButton" ||
           (hitRole == "AXButton" && (hitTitle.contains("close") || hitDesc.contains("close"))) {
            return nil
        }

        var cursor: AXUIElement? = hit
        for _ in 0..<6 {
            guard let elem = cursor else { break }
            if isTabButton(elem) {
                return elem
            }
            if axString(elem, kAXRoleAttribute) == "AXTabGroup" {
                return findTabInGroup(elem, at: point, depth: 0)
            }
            cursor = axParent(of: elem)
        }
        return nil
    }

    private func isTabButton(_ elem: AXUIElement) -> Bool {
        let role = axString(elem, kAXRoleAttribute) ?? ""
        let subrole = axString(elem, kAXSubroleAttribute) ?? ""
        let roleDesc = axString(elem, kAXRoleDescriptionAttribute) ?? ""
        if subrole == "AXTabButton" || role == "AXTab" || roleDesc == "tab" {
            return true
        }
        if role == "AXRadioButton", let parent = axParent(of: elem) {
            return axString(parent, kAXRoleAttribute) == "AXTabGroup"
        }
        return false
    }

    private func findTabInGroup(_ elem: AXUIElement, at point: CGPoint, depth: Int) -> AXUIElement? {
        if depth > 6 { return nil }
        if depth > 0, isTabButton(elem) {
            return axFrame(of: elem)?.contains(point) == true ? elem : nil
        }
        if let tabs = axValue(elem, "AXTabs") as? [AXUIElement] {
            for tab in tabs where axFrame(of: tab)?.contains(point) == true {
                return tab
            }
        }
        if let children = axValue(elem, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                if let found = findTabInGroup(child, at: point, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    private func isTabSelected(_ elem: AXUIElement) -> Bool {
        axBool(elem, kAXSelectedAttribute) == true || axBool(elem, kAXValueAttribute) == true
    }

    // MARK: - Target activation

    private func activate(_ target: Target) {
        lastActivatedTarget = target
        if let targetActivator {
            targetActivator(target)
            return
        }

        switch target {
        case let .dockApp(title, bundleURL, dockElement):
            activateDockApplication(title: title, bundleURL: bundleURL, dockElement: dockElement)

        case let .tab(pid, windowID, isFrontmostWindow, tabElement):
            if !isFrontmostWindow {
                raiseWindowAndApp(pid: pid, windowID: windowID)
            }
            if AXUIElementPerformAction(tabElement, kAXPressAction as CFString) != .success {
                AXUIElementSetAttributeValue(tabElement, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(tabElement, kAXValueAttribute as CFString, kCFBooleanTrue)
            }

        case let .backgroundWindow(windowID, pid):
            raiseWindowAndApp(pid: pid, windowID: windowID)
        }
    }

    private func activateDockApplication(title: String, bundleURL: URL?, dockElement: AXUIElement) {
        let runningApps = NSWorkspace.shared.runningApplications
        let matchedApp = runningApps.first { app in
            guard let bundleURL, let candidate = app.bundleURL?.standardizedFileURL else {
                return false
            }
            return candidate == bundleURL
        } ?? runningApps.first { app in
            !title.isEmpty && app.localizedName == title
        }

        guard let app = matchedApp, app.isFinishedLaunching else {
            AXUIElementPerformAction(dockElement, kAXPressAction as CFString)
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (axValue(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let hasVisibleWindow = windows.contains { axBool($0, kAXMinimizedAttribute) != true }

        guard hasVisibleWindow else {
            // Let Dock unminimize or reopen the app's default window.
            AXUIElementPerformAction(dockElement, kAXPressAction as CFString)
            return
        }

        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
        if let firstWin = windows.first {
            AXUIElementPerformAction(firstWin, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(firstWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func raiseWindowAndApp(pid: pid_t, windowID: UInt32) {
        let app = NSRunningApplication(processIdentifier: pid)
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app?.activate()

        guard let windows = axValue(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
            return
        }
        for win in windows {
            var axWinID: UInt32 = 0
            if strafe_ax_window_id(win, &axWinID), axWinID == windowID {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
        if let first = windows.first {
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(first, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - AX attribute helpers

    private func axValue(_ elem: AXUIElement, _ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    private func axString(_ elem: AXUIElement, _ attr: String) -> String? {
        axValue(elem, attr) as? String
    }

    private func axBool(_ elem: AXUIElement, _ attr: String) -> Bool? {
        (axValue(elem, attr) as? NSNumber)?.boolValue
    }

    private func axParent(of elem: AXUIElement) -> AXUIElement? {
        guard let ref = axValue(elem, kAXParentAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    private func axFrame(of elem: AXUIElement) -> CGRect? {
        guard let pVal = axValue(elem, kAXPositionAttribute),
              let sVal = axValue(elem, kAXSizeAttribute),
              CFGetTypeID(pVal) == AXValueGetTypeID(),
              CFGetTypeID(sVal) == AXValueGetTypeID() else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(pVal, to: AXValue.self), .cgPoint, &pos),
              AXValueGetValue(unsafeDowncast(sVal, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }
}
