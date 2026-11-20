import AppKit
import OSLog

@MainActor
final class MonitorMenuBar: NSObject, NSApplicationDelegate {
    private let worker = MonitorWorker()
    private let preferences = MonitorPreferences()
    private let profiles = MonitorProfiles.bundled()
    private let automaticMirroring = AutomaticMirroring(desktop: QuartzDesktopMirroring())
    private let log = Logger(subsystem: "local.monitorinput.app", category: "Input")
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private var status: MonitorStatus?
    private var lastConnection: MonitorConnection?
    private var switchingTo: DisplayInput?
    private var connections: [MonitorConnection] = []
    private var capabilities: (fingerprint: String, inputs: Set<DisplayInput>)?
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
            timeInterval: 3, target: self, selector: #selector(refreshOnTimer(_:)), userInfo: nil, repeats: true
        )
        timer?.tolerance = 0.3
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
           preferences.leftClickAction == .selectMac,
           let connection = switchableConnection,
           let input = preferences.configuration(for: connection.identity).macInput {
            select(input, expected: connection, showsFailure: true)
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
        let preferred = preferences.preferredMonitor
        Task {
            let scan = await worker.scan(preferredFingerprint: preferred)
            isRefreshing = false
            guard switchGeneration == generation else {
                refresh()
                return
            }
            if status != scan.status { notice = nil }
            if case .connected(let reading) = scan.status {
                capabilities = (reading.connection.identity.fingerprint, scan.advertisedInputs)
            }
            apply(scan.status, inventory: scan.inventory)
        }
    }

    private func select(_ target: DisplayInput, expected: MonitorConnection, showsFailure: Bool) {
        guard switchingTo == nil, switchableConnection == expected else { return }
        let allowed = availableInputs(for: expected.identity)
        guard allowed.contains(target) else { return }
        let preferred = preferences.preferredMonitor
        alreadyOnMac.dismiss()
        switchGeneration &+= 1
        switchingTo = target
        notice = nil
        renderStatusItem()
        Task {
            let (result, inventory) = await worker.select(
                target, allowed: allowed, expected: expected, preferredFingerprint: preferred
            )
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

            apply(result.status, inventory: inventory)
            switch result {
            case .alreadySelected:
                if target == preferences.configuration(for: expected.identity).macInput,
                   !isShowingMenu, let button = item.button {
                    alreadyOnMac.show(below: button)
                }
            case .selected:
                break
            case .blocked, .unconfirmed:
                if showsFailure {
                    showMenu()
                } else {
                    refresh()
                }
            }
        }
    }

    private func apply(_ latest: MonitorStatus, inventory: MonitorInventory) {
        status = latest
        connections = inventory.connections
        switch latest {
        case .connected(let reading):
            lastConnection = reading.connection
            preferences.remember(reading)
        case .ambiguous, .disconnected:
            lastConnection = nil
        case .unavailable:
            if let lastConnection, !connections.isEmpty, !connections.contains(lastConnection) {
                self.lastConnection = nil
            }
        }
        if !isShowingMenu { updateMirroring(latest, inventory: inventory) }
        renderStatusItem()
    }

    private func updateMirroring(_ latest: MonitorStatus?, inventory: MonitorInventory? = nil) {
        let macInput = reading.flatMap { preferences.configuration(for: $0.connection.identity).macInput }
        let uniqueDisplay = reading.map { inventory?.hasUniqueDisplayMatch(for: $0.connection.identity) == true } ?? false
        if let state = automaticMirroring.update(
            latest, enabled: preferences.mirrorsOtherInputs, macInput: macInput, hasUniqueDisplayMatch: uniqueDisplay
        ) {
            mirrorState = state
        } else if case .disconnected = latest, mirrorState == .active {
            mirrorState = .inactive
        }
    }

    private var reading: MonitorReading? {
        if case .connected(let reading) = status { return reading }
        return nil
    }

    private var switchableConnection: MonitorConnection? {
        if let reading { return reading.connection }
        if case .unavailable = status { return lastConnection }
        return nil
    }

    private var selectedIdentity: DisplayIdentity? {
        if let switchableConnection { return switchableConnection.identity }
        if case .ambiguous = status { return nil }
        return preferences.lastSeen?.identity
    }

    private func monitorName(_ identity: DisplayIdentity) -> String {
        profiles.profile(for: identity)?.name ?? identity.product?.name ?? "Монитор"
    }

    private func availableInputs(for identity: DisplayIdentity) -> Set<DisplayInput> {
        let inputs = capabilities.flatMap { $0.fingerprint == identity.fingerprint ? $0.inputs : nil } ?? []
        return preferences.configuration(for: identity).inputs(advertised: inputs, profile: profiles.profile(for: identity))
    }

    private func portName(_ input: DisplayInput, on identity: DisplayIdentity) -> String {
        profiles.profile(for: identity)?.ports[input] ?? MonitorProfile.portName(for: input)
    }

    private func inputTitle(_ input: DisplayInput, on identity: DisplayIdentity) -> String {
        let configuration = preferences.configuration(for: identity)
        if let alias = configuration.aliases[input.rawValue] { return alias }
        return configuration.macInput == input ? "Этот Mac" : portName(input, on: identity)
    }

    private var connectionStatus: String {
        switch status {
        case nil: "Проверка связи…"
        case .disconnected: "Не подключён"
        case .unavailable: "Связь недоступна"
        case .ambiguous: "Нужно выбрать монитор"
        case .connected(let reading): reading.input == nil ? "Подключён · Вход не определён" : "Подключён"
        }
    }

    private var summary: String {
        if let switchingTo, let identity = selectedIdentity {
            return "Переключение · \(inputTitle(switchingTo, on: identity))…"
        }
        if let notice { return notice }
        if let reading, let input = reading.input {
            return "\(connectionStatus) · \(inputTitle(input, on: reading.connection.identity))"
        }
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
        let title = selectedIdentity.map(monitorName) ?? "Вход монитора"
        button.toolTip = "\(title) · \(summary)"
        button.setAccessibilityLabel("Вход монитора")
        button.setAccessibilityValue(summary)
        button.setAccessibilityHelp("Control‑клик открывает меню источников.")
    }

    private func showMenu() {
        guard !isShowingMenu, let button = item.button else { return }
        alreadyOnMac.dismiss()
        isShowingMenu = true
        let previousSelection = preferences.preferredMonitor
        let previousMonitor = selectedIdentity?.fingerprint
        let menu = makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        isShowingMenu = false
        if let preferred = preferences.preferredMonitor, preferred != previousSelection, preferred != previousMonitor {
            mirrorState = automaticMirroring.update(nil, enabled: false) ?? .inactive
        } else if !preferences.mirrorsOtherInputs {
            updateMirroring(nil)
        }
        refresh()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 290

        let identity = selectedIdentity
        let header = NSMenuItem(title: identity.map(monitorName) ?? "Вход монитора", action: nil, keyEquivalent: "")
        if let identity, let input = reading?.input,
           !preferences.configuration(for: identity).isInputVisible(input) {
            header.subtitle = "\(connectionStatus) · \(inputTitle(input, on: identity))"
        } else {
            header.subtitle = connectionStatus
        }
        header.image = icon("display")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let selector = makeMonitorSelector() { menu.addItem(selector) }
        if let identity {
            let configuration = preferences.configuration(for: identity)
            let inputs = availableInputs(for: identity).sorted { $0.rawValue < $1.rawValue }
            let visibleInputs = inputs.filter { configuration.isInputVisible($0) }
            for input in visibleInputs {
                menu.addItem(sourceItem(input, on: identity, isMac: configuration.macInput == input))
            }
            if !visibleInputs.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "Сигнал на входах неизвестен"))
            }
            if !inputs.isEmpty {
                menu.addItem(inputSettings(for: identity, inputs: inputs, configuration: configuration))
            }
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
        let target: DisplayInput
        let connection: MonitorConnection
    }

    private func sourceItem(_ target: DisplayInput, on identity: DisplayIdentity, isMac: Bool) -> NSMenuItem {
        let title = inputTitle(target, on: identity)
        let port = portName(target, on: identity)
        let menuItem = command(title, #selector(sourceChosen(_:)), symbol: isMac ? "laptopcomputer" : "cable.connector")
        menuItem.subtitle = title == port ? target.hexCode : "\(port) · \(target.hexCode)"
        menuItem.state = reading?.input == target ? .on : .off
        if let connection = switchableConnection, connection.identity == identity, switchingTo == nil {
            menuItem.representedObject = SourceSelection(target: target, connection: connection)
        } else {
            menuItem.isEnabled = false
        }
        return menuItem
    }

    @objc private func sourceChosen(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SourceSelection else { return }
        select(selection.target, expected: selection.connection, showsFailure: false)
    }

    private func makeMonitorSelector() -> NSMenuItem? {
        let knownConnections = connections.isEmpty ? switchableConnection.map { [$0] } ?? [] : connections
        guard !knownConnections.isEmpty else { return nil }
        let item = NSMenuItem(title: "Монитор", action: nil, keyEquivalent: "")
        item.image = icon("display.2")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let automatic = command("Выбирать автоматически", #selector(chooseMonitor(_:)), symbol: "checkmark.circle")
        automatic.state = preferences.preferredMonitor == nil ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        let grouped = Dictionary(grouping: knownConnections, by: { $0.identity.fingerprint })
        for group in grouped.values.sorted(by: {
            let first = $0[0].identity
            let second = $1[0].identity
            return (monitorName(first), first.fingerprint) < (monitorName(second), second.fingerprint)
        }) {
            let identity = group[0].identity
            let display = command(monitorName(identity), #selector(chooseMonitor(_:)), symbol: "display")
            display.subtitle = group.count == 1 ? String(identity.fingerprint.prefix(8)) : "Несколько экранов с одним EDID"
            display.representedObject = identity.fingerprint
            display.state = preferences.preferredMonitor == identity.fingerprint ? .on : .off
            display.isEnabled = group.count == 1
            submenu.addItem(display)
        }
        item.submenu = submenu
        return item
    }

    @objc private func chooseMonitor(_ sender: NSMenuItem) {
        guard switchingTo == nil else { return }
        let fingerprint = sender.representedObject as? String
        guard preferences.preferredMonitor != fingerprint else { return }
        preferences.preferredMonitor = fingerprint
        switchGeneration &+= 1
        status = nil
        lastConnection = nil
        capabilities = nil
        notice = nil
        renderStatusItem()
    }

    private struct PortPreference {
        let input: DisplayInput
        let identity: DisplayIdentity
    }

    private func inputSettings(
        for identity: DisplayIdentity, inputs: [DisplayInput], configuration: MonitorConfiguration
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Настроить входы", action: nil, keyEquivalent: "")
        item.image = icon("slider.horizontal.3")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let mac = inputOptions(
            "Вход Mac", symbol: "laptopcomputer", inputs: inputs, for: identity,
            action: #selector(assignMacInput(_:)), checked: { $0 == configuration.macInput }
        )
        mac.subtitle = configuration.macInput.map { portName($0, on: identity) } ?? "Выберите порт, к которому подключён Mac"
        mac.isEnabled = switchingTo == nil
        submenu.addItem(mac)
        submenu.addItem(inputOptions(
            "Показывать входы", symbol: "eye", inputs: inputs, for: identity,
            action: #selector(toggleInputVisibility(_:)), checked: configuration.isInputVisible
        ))
        submenu.addItem(inputOptions(
            "Переименовать вход", symbol: "pencil", inputs: inputs, for: identity, action: #selector(renameInput(_:))
        ))
        item.submenu = submenu
        return item
    }

    private func inputOptions(
        _ title: String, symbol: String, inputs: [DisplayInput], for identity: DisplayIdentity,
        action: Selector, checked: ((DisplayInput) -> Bool)? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = icon(symbol)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let aliases = preferences.configuration(for: identity).aliases
        for input in inputs {
            let port = portName(input, on: identity)
            let choice = NSMenuItem(title: aliases[input.rawValue] ?? port, action: action, keyEquivalent: "")
            choice.target = self
            choice.representedObject = PortPreference(input: input, identity: identity)
            choice.subtitle = choice.title == port ? input.hexCode : "\(port) · \(input.hexCode)"
            choice.state = checked?(input) == true ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func assignMacInput(_ sender: NSMenuItem) {
        guard switchingTo == nil, let selection = sender.representedObject as? PortPreference else { return }
        preferences.assignMacInput(selection.input, for: selection.identity)
        notice = nil
        renderStatusItem()
    }

    @objc private func toggleInputVisibility(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? PortPreference else { return }
        preferences.toggleInputVisibility(selection.input, for: selection.identity)
    }

    @objc private func renameInput(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? PortPreference else { return }
        Task {
            let identity = selection.identity
            let port = portName(selection.input, on: identity)
            let alert = NSAlert()
            alert.messageText = "Название входа \(port)"
            alert.informativeText = "Пустое поле вернёт стандартную подпись."
            alert.addButton(withTitle: "Сохранить")
            alert.addButton(withTitle: "Отмена")
            let value = preferences.configuration(for: identity).aliases[selection.input.rawValue] ?? ""
            let name = NSTextField(string: value)
            name.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
            name.placeholderString = "Например, Linux или консоль"
            alert.accessoryView = name
            alert.window.initialFirstResponder = name
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                preferences.renameInput(selection.input, for: identity, to: name.stringValue)
                renderStatusItem()
            }
        }
    }

    private func makeDetails() -> NSMenuItem? {
        let previous = preferences.lastSeen
        guard let identity = selectedIdentity else { return nil }
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
            submenu.addItem(NSMenuItem.sectionHeader(title: monitorName(identity)))
            if let input = previous.input {
                submenu.addItem(NSMenuItem.sectionHeader(title: "Был выбран \(inputTitle(input, on: identity))"))
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
