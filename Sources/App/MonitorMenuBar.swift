import AppKit
import OSLog
import SwiftUI

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
    private var pendingSelection: InputSelection?
    private var connections: [MonitorConnection] = []
    private var capabilities: (fingerprint: String, inputs: Set<DisplayInput>)?
    private var switchGeneration: UInt64 = 0
    private var notice: String?
    private var mirrorState: DesktopMirrorState = .inactive
    private var isRefreshing = false
    private var isShowingMenu = false
    private var opensSettingsAfterMenu = false
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let alreadyOnMac = AlreadyOnMacToast()
    private lazy var settings = MonitorSettingsModel { [weak self] in self?.applySetting($0) }
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
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

    private func installApplicationMenu() {
        let applicationMenu = NSMenu(title: "MonitorInput")
        applicationMenu.addItem(command("Настройки…", #selector(showSettings), key: ",", symbol: "gearshape"))
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Завершить MonitorInput", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)

        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = automaticMirroring.update(nil, enabled: false)
        alreadyOnMac.dismiss()
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        NSStatusBar.system.removeStatusItem(item)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard !isShowingMenu else { return }
        let event = NSApp.currentEvent
        if event?.type == .leftMouseUp, event?.modifierFlags.contains(.control) != true,
           let connection = switchableConnection,
           let selection = preferences.configuration(for: connection.identity).selection(for: preferences.leftClickAction) {
            select(selection, expected: connection, showsFailure: true)
        } else {
            showMenu()
        }
    }

    @objc private func refreshOnTimer(_ timer: Timer) {
        refresh()
    }

    private func refresh() {
        guard !isRefreshing, pendingSelection == nil, !isShowingMenu else { return }
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

    private func select(_ selection: InputSelection, expected: MonitorConnection, showsFailure: Bool) {
        guard pendingSelection == nil, switchableConnection == expected else { return }
        let allowed = availableInputs(for: expected.identity)
        guard selection.isAllowed(in: allowed) else {
            if showsFailure { showMenu() }
            return
        }
        let preferred = preferences.preferredMonitor
        alreadyOnMac.dismiss()
        switchGeneration &+= 1
        pendingSelection = selection
        notice = nil
        renderStatusItem()
        Task {
            let (result, inventory) = await worker.select(
                selection, allowed: allowed, expected: expected, preferredFingerprint: preferred
            )
            pendingSelection = nil

            switch result {
            case .selected(let reading):
                if let input = reading.input {
                    log.info("Selected input \(input.rawValue, privacy: .public)")
                }
            case .alreadySelected:
                break
            case .blocked(.connected(let reading)) where reading.input != nil:
                notice = "Монитор переподключён. Повторите выбор."
            case .blocked:
                break
            case .unconfirmed:
                notice = "Смена входа не подтверждена"
                log.notice("Could not confirm input change")
            }

            apply(result.status, inventory: inventory)
            switch result {
            case .alreadySelected(let reading):
                if let input = reading.input, input == preferences.configuration(for: expected.identity).macInput,
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
        if let pendingSelection {
            if case .fixed(let input) = pendingSelection, let identity = selectedIdentity {
                return "Переключение · \(inputTitle(input, on: identity))…"
            }
            return "Переключение входа…"
        }
        if let notice { return notice }
        if let reading, let input = reading.input {
            return "\(connectionStatus) · \(inputTitle(input, on: reading.connection.identity))"
        }
        return connectionStatus
    }

    private func renderStatusItem() {
        if settingsWindow?.isVisible == true { updateSettings() }
        guard let button = item.button else { return }
        let symbol: String
        if pendingSelection != nil {
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
        let menu = makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        isShowingMenu = false
        if opensSettingsAfterMenu {
            opensSettingsAfterMenu = false
            showSettings()
        } else {
            refresh()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSApp.effectiveAppearance
        menu.minimumWidth = 235

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

        if let identity {
            let configuration = preferences.configuration(for: identity)
            let inputs = availableInputs(for: identity).sorted { $0.rawValue < $1.rawValue }
            let visibleInputs = inputs.filter { configuration.isInputVisible($0) }
            if !visibleInputs.isEmpty { menu.addItem(.separator()) }
            for input in visibleInputs {
                menu.addItem(sourceItem(input, on: identity, isMac: configuration.macInput == input))
            }
        }
        if pendingSelection != nil || notice != nil {
            menu.addItem(NSMenuItem.sectionHeader(title: summary))
        }
        menu.addItem(.separator())
        menu.addItem(command("Настройки…", #selector(showSettings), key: ",", symbol: "gearshape"))
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
        if title != port { menuItem.subtitle = port }
        menuItem.state = reading?.input == target ? .on : .off
        if let connection = switchableConnection, connection.identity == identity, pendingSelection == nil {
            menuItem.representedObject = SourceSelection(target: target, connection: connection)
        } else {
            menuItem.isEnabled = false
        }
        return menuItem
    }

    @objc private func sourceChosen(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SourceSelection else { return }
        select(.fixed(selection.target), expected: selection.connection, showsFailure: false)
    }

    @objc private func showSettings() {
        if isShowingMenu {
            opensSettingsAfterMenu = true
            return
        }
        updateSettings()
        settings.refreshLoginStatus()
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 604, height: 508),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Настройки MonitorInput"
            window.tabbingMode = .disallowed
            window.collectionBehavior.formUnion([.fullScreenNone, .moveToActiveSpace])
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: MonitorSettingsView(model: settings))
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: 604, height: 508))
            window.contentMinSize = NSSize(width: 520, height: 390)
            window.center()
            window.setFrameAutosaveName("MonitorInput.Settings")
            settingsWindow = window
        }
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKey()
        refresh()
    }

    private func updateSettings() {
        var state = MonitorSettingsState()
        state.preferredMonitor = preferences.preferredMonitor
        state.choices = monitorChoices
        state.connectionStatus = connectionStatus
        state.isSwitching = pendingSelection != nil
        state.leftClickAction = preferences.leftClickAction
        state.mirrorsOtherInputs = preferences.mirrorsOtherInputs
        switch mirrorState {
        case .inactive: break
        case .active: state.mirrorStatus = "Рабочий стол сейчас на экране MacBook."
        case .unavailable: state.mirrorStatus = "Зеркалирование сейчас недоступно."
        case .restoreFailed: state.mirrorStatus = "Раскладка восстановлена не полностью."
        }
        if let identity = selectedIdentity {
            let configuration = preferences.configuration(for: identity)
            let ports = availableInputs(for: identity).sorted { $0.rawValue < $1.rawValue }.map { input in
                MonitorSettingsState.Port(
                    id: input,
                    name: portName(input, on: identity),
                    alias: configuration.aliases[input.rawValue] ?? "",
                    isVisible: configuration.isInputVisible(input),
                    isSelected: reading?.input == input
                )
            }
            let previous = reading == nil ? configuration.lastSeen ?? preferences.lastSeen : nil
            state.device = MonitorSettingsState.Device(
                identity: identity,
                name: monitorName(identity),
                macInput: configuration.macInput,
                toggleInputs: configuration.toggleInputs ?? InputTogglePair(),
                ports: ports,
                lastSeen: previous?.observedAt,
                lastSource: previous?.input.map { inputTitle($0, on: identity) }
            )
        }
        settings.update(state)
    }

    private var monitorChoices: [MonitorSettingsState.Choice] {
        let known = connections.isEmpty ? switchableConnection.map { [$0] } ?? [] : connections
        let grouped = Dictionary(grouping: known, by: { $0.identity.fingerprint })
        var choices = grouped.values.compactMap { group -> MonitorSettingsState.Choice? in
            guard let identity = group.first?.identity else { return nil }
            let name = monitorName(identity)
            let label = group.count > 1 ? "\(name) · одинаковый EDID" : name
            return MonitorSettingsState.Choice(id: identity.fingerprint, name: label, canSelect: group.count == 1)
        }
        let nameCounts = Dictionary(grouping: choices, by: \.name).mapValues(\.count)
        choices = choices.map { choice in
            guard nameCounts[choice.name, default: 0] > 1 else { return choice }
            return MonitorSettingsState.Choice(
                id: choice.id, name: "\(choice.name) · \(choice.id.prefix(8))", canSelect: choice.canSelect
            )
        }
        if let preferred = preferences.preferredMonitor, !choices.contains(where: { $0.id == preferred }) {
            let name = preferences.lastSeen.map { monitorName($0.identity) } ?? "Сохранённый монитор"
            choices.append(MonitorSettingsState.Choice(id: preferred, name: "\(name) · отключён", canSelect: false))
        }
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func applySetting(_ setting: MonitorSetting) {
        switch setting {
        case .monitor(let fingerprint):
            guard pendingSelection == nil, preferences.preferredMonitor != fingerprint else { return }
            let previous = selectedIdentity?.fingerprint
            preferences.preferredMonitor = fingerprint
            switchGeneration &+= 1
            status = nil
            lastConnection = nil
            capabilities = nil
            notice = nil
            if let fingerprint, fingerprint != previous {
                mirrorState = automaticMirroring.update(nil, enabled: false) ?? .inactive
            }
            refresh()
        case .macInput(let input, let identity):
            guard pendingSelection == nil else { return }
            preferences.assignMacInput(input, for: identity)
            notice = nil
            refresh()
        case .alias(let name, let input, let identity):
            preferences.renameInput(input, for: identity, to: name)
        case .visibility(let visible, let input, let identity):
            preferences.setInputVisibility(input, visible: visible, for: identity)
        case .leftClickAction(let action):
            guard pendingSelection == nil else { return }
            preferences.leftClickAction = action
        case .toggleInputs(let pair, let identity):
            guard pendingSelection == nil, selectedIdentity == identity else { return }
            let available = availableInputs(for: identity)
            guard [pair.first, pair.second].compactMap({ $0 }).allSatisfy(available.contains) else { return }
            preferences.setToggleInputs(pair, for: identity)
        case .mirroring(let enabled):
            preferences.mirrorsOtherInputs = enabled
            if enabled {
                refresh()
            } else {
                updateMirroring(nil)
            }
        }
        renderStatusItem()
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
