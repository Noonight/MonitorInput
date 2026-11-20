import AppKit
import OSLog

@MainActor
final class MonitorMenuBar: NSObject, NSApplicationDelegate {
    private let worker = MonitorWorker()
    private let preferences = MonitorPreferences()
    private let automaticMirroring = AutomaticMirroring(desktop: QuartzDesktopMirroring())
    private let log = Logger(subsystem: "local.monitorinput.app", category: "Input")
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private var status: MonitorStatus?
    private var switchingTo: SwitchTarget?
    private var switchGeneration: UInt64 = 0
    private var notice: String?
    private var mirrorState: DesktopMirrorState = .inactive
    private var isRefreshing = false
    private var isShowingMenu = false
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let alreadyOnMac = AlreadyOnMacToast()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(
            timeInterval: 12, target: self, selector: #selector(refreshOnTimer(_:)), userInfo: nil, repeats: true
        )
        renderStatusItem()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = automaticMirroring.update(nil, enabled: false)
        alreadyOnMac.dismiss()
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard !isShowingMenu else { return }
        let event = NSApp.currentEvent
        if event?.type == .leftMouseUp, event?.modifierFlags.contains(.control) != true,
           preferences.leftClickAction == .selectMac {
            select(.mac, expected: nil, showsFailure: true)
        } else {
            showMenu()
        }
    }

    @objc private func refreshOnTimer(_ timer: Timer) {
        refresh()
    }

    private func refresh() {
        guard !isRefreshing, switchingTo == nil, !isShowingMenu else { return }
        isRefreshing = true
        let generation = switchGeneration
        Task {
            let latest = await worker.probe()
            isRefreshing = false
            guard switchGeneration == generation else { return }
            if status != latest { notice = nil }
            apply(latest)
        }
    }

    private func select(_ target: SwitchTarget, expected: MonitorConnection?, showsFailure: Bool) {
        guard switchingTo == nil else { return }
        alreadyOnMac.dismiss()
        switchGeneration &+= 1
        switchingTo = target
        notice = nil
        renderStatusItem()
        Task {
            let result = await worker.select(target, expected: expected)
            switchingTo = nil

            switch result {
            case .selected:
                log.info("Selected input \(target.rawValue, privacy: .public)")
            case .alreadySelected:
                break
            case .blocked(.connected(let reading)) where reading.input != nil:
                notice = "Монитор переподключён. Повторите выбор."
            case .blocked:
                break
            case .unconfirmed:
                notice = "Смена входа не подтверждена"
                log.notice("Could not confirm input \(target.rawValue, privacy: .public)")
            }

            apply(result.status)
            switch result {
            case .alreadySelected:
                if target == .mac, !isShowingMenu, let button = item.button {
                    alreadyOnMac.show(below: button)
                }
            case .selected:
                break
            case .blocked, .unconfirmed:
                if showsFailure { showMenu() }
            }
        }
    }

    private func apply(_ latest: MonitorStatus) {
        status = latest
        if case .connected(let reading) = latest {
            preferences.remember(reading)
        }
        if !isShowingMenu { updateMirroring(latest) }
        renderStatusItem()
    }

    private func updateMirroring(_ latest: MonitorStatus?) {
        if let state = automaticMirroring.update(latest, enabled: preferences.mirrorsOtherInputs) {
            mirrorState = state
        } else if case .disconnected = latest, mirrorState == .active {
            mirrorState = .inactive
        }
    }

    private var reading: MonitorReading? {
        if case .connected(let reading) = status { return reading }
        return nil
    }

    private var connectionStatus: String {
        switch status {
        case nil: "Проверка связи…"
        case .disconnected: "Не подключён"
        case .unavailable: "Связь недоступна"
        case .ambiguous: "Найдено несколько таких мониторов"
        case .connected(let reading): reading.input == nil ? "Подключён · Вход не определён" : "Подключён"
        }
    }

    private var summary: String {
        if let switchingTo { return "Переключение на \(switchingTo == .mac ? "Mac" : "Windows")…" }
        if let notice { return notice }
        if let input = reading?.input { return "\(connectionStatus) · \(input.label)" }
        return connectionStatus
    }

    private func renderStatusItem() {
        guard let button = item.button else { return }
        let symbol: String
        if switchingTo != nil {
            symbol = "arrow.triangle.2.circlepath"
        } else if reading == nil && status != nil || notice != nil {
            symbol = "display.trianglebadge.exclamationmark"
        } else {
            symbol = "display"
        }
        button.image = icon(symbol) ?? icon("display")
        button.toolTip = "HUAWEI MateView GT · \(summary)"
        button.setAccessibilityLabel("Вход монитора")
        button.setAccessibilityValue(summary)
        button.setAccessibilityHelp("Control‑клик открывает меню источников.")
    }

    private func showMenu() {
        guard !isShowingMenu, let button = item.button else { return }
        alreadyOnMac.dismiss()
        isShowingMenu = true
        let menu = makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        isShowingMenu = false
        if !preferences.mirrorsOtherInputs { updateMirroring(nil) }
        refresh()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 290

        let header = NSMenuItem(title: "HUAWEI MateView GT", action: nil, keyEquivalent: "")
        header.subtitle = "\(DisplayProtocol.modelName) · \(connectionStatus)"
        header.image = icon("display")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let macStatus = reading != nil ? "Подключён" : connectionStatus
        menu.addItem(sourceItem(.mac, title: "Этот Mac", subtitle: "USB‑C · \(macStatus)", symbol: "laptopcomputer"))
        menu.addItem(sourceItem(
            .windows, title: "Windows", subtitle: "DisplayPort · Сигнал неизвестен", symbol: "pc"
        ))
        if let input = reading?.input, input == .hdmi1 || input == .hdmi2 {
            menu.addItem(NSMenuItem.sectionHeader(title: "Выбран \(input.label)"))
        }
        if switchingTo != nil || notice != nil {
            menu.addItem(NSMenuItem.sectionHeader(title: summary))
        }
        if let details = makeDetails() { menu.addItem(details) }

        menu.addItem(.separator())
        let quickSwitch = command("Левый клик переключает на Mac", #selector(toggleQuickSwitch), symbol: "cursorarrow.click")
        quickSwitch.state = preferences.leftClickAction == .selectMac ? .on : .off
        menu.addItem(quickSwitch)
        let mirroring = command("Зеркалировать при другом входе", #selector(toggleMirroring), symbol: "rectangle.on.rectangle")
        mirroring.state = preferences.mirrorsOtherInputs ? .on : .off
        switch mirrorState {
        case .inactive: break
        case .active: mirroring.subtitle = "Рабочий стол на экране MacBook"
        case .unavailable: mirroring.subtitle = "Зеркалирование сейчас недоступно"
        case .restoreFailed: mirroring.subtitle = "Раскладка восстановлена не полностью"
        }
        menu.addItem(mirroring)
        menu.addItem(command("Выход", #selector(quit), key: "q", symbol: "power"))
        return menu
    }

    private struct SourceSelection {
        let target: SwitchTarget
        let connection: MonitorConnection
    }

    private func sourceItem(_ target: SwitchTarget, title: String, subtitle: String, symbol: String) -> NSMenuItem {
        let menuItem = command(title, #selector(sourceChosen(_:)), symbol: symbol)
        menuItem.subtitle = subtitle
        menuItem.state = reading?.input == target.input ? .on : .off
        if let reading, reading.input != nil, switchingTo == nil {
            menuItem.representedObject = SourceSelection(target: target, connection: reading.connection)
        } else {
            menuItem.isEnabled = false
        }
        return menuItem
    }

    @objc private func sourceChosen(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SourceSelection else { return }
        select(selection.target, expected: selection.connection, showsFailure: false)
    }

    private func makeDetails() -> NSMenuItem? {
        let previous = preferences.lastSeen
        guard let identity = reading?.connection.identity ?? previous?.identity else { return nil }
        let isCached = reading == nil
        let details = NSMenuItem(
            title: isCached ? "Последнее подключение" : "Сведения о мониторе",
            action: nil,
            keyEquivalent: ""
        )
        details.image = icon(isCached ? "clock" : "info.circle")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if isCached, let previous {
            let formatted = previous.observedAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "ru_RU"))
            )
            submenu.addItem(NSMenuItem.sectionHeader(title: formatted))
            submenu.addItem(NSMenuItem.sectionHeader(title: "Этот Mac · USB‑C"))
            if let input = previous.input {
                submenu.addItem(NSMenuItem.sectionHeader(title: "Был выбран \(input.label)"))
            }
        }
        if let serial = identity.serialNumber {
            let text = String(format: "%08X", serial)
            submenu.addItem(NSMenuItem.sectionHeader(title: "Серийный номер EDID · \(text)"))
        }
        let copy = command("Скопировать ID EDID", #selector(copyIdentifier(_:)), symbol: "doc.on.doc")
        copy.subtitle = String(identity.fingerprint.prefix(12))
        copy.representedObject = identity.fingerprint
        submenu.addItem(copy)
        details.submenu = submenu
        return details
    }

    private func command(_ title: String, _ action: Selector, key: String = "", symbol: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menuItem.image = icon(symbol)
        return menuItem
    }

    private func icon(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    @objc private func copyIdentifier(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identifier, forType: .string)
    }

    @objc private func toggleQuickSwitch() {
        preferences.leftClickAction = preferences.leftClickAction == .selectMac ? .showMenu : .selectMac
    }

    @objc private func toggleMirroring() {
        preferences.mirrorsOtherInputs.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension DisplayInput {
    var label: String {
        switch self {
        case .usbC: "Этот Mac (USB‑C)"
        case .displayPort: "Windows (DisplayPort)"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        }
    }
}
