import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct MonitorSettingsState: Equatable {
    struct Choice: Equatable, Identifiable {
        let id: String
        let name: String
        let canSelect: Bool
    }

    struct Device: Equatable {
        let identity: DisplayIdentity
        let name: String
        let macInput: DisplayInput?
        let toggleInputs: InputTogglePair
        let ports: [Port]
        let lastSeen: Date?
        let lastSource: String?
    }

    struct Port: Equatable, Identifiable {
        let id: DisplayInput
        let name: String
        let alias: String
        let isVisible: Bool
        let isSelected: Bool
    }

    var preferredMonitor: String?
    var choices: [Choice] = []
    var device: Device?
    var connectionStatus = "Проверка связи…"
    var isSwitching = false
    var leftClickAction: LeftClickAction = .selectMac
    var mirrorsOtherInputs = false
    var mirrorStatus: String?
}

enum MonitorSetting {
    case monitor(String?)
    case macInput(DisplayInput, DisplayIdentity)
    case alias(String, DisplayInput, DisplayIdentity)
    case visibility(Bool, DisplayInput, DisplayIdentity)
    case leftClickAction(LeftClickAction)
    case toggleInputs(InputTogglePair, DisplayIdentity)
    case mirroring(Bool)
}

@MainActor
final class MonitorSettingsModel: ObservableObject {
    @Published private(set) var state = MonitorSettingsState()
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var loginError: String?
    let apply: (MonitorSetting) -> Void
    private let loginItem = SMAppService.mainApp

    init(apply: @escaping (MonitorSetting) -> Void) {
        self.apply = apply
    }

    func update(_ state: MonitorSettingsState) {
        if self.state != state { self.state = state }
    }

    var startsAtLogin: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    func refreshLoginStatus() {
        loginStatus = loginItem.status
    }

    func setStartsAtLogin(_ enabled: Bool) {
        refreshLoginStatus()
        guard enabled != startsAtLogin else { return }
        loginError = nil
        do {
            if enabled {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
        } catch {
            loginError = "Не удалось изменить автозапуск. \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var model: MonitorSettingsModel
    @State private var showsDetails = false

    var body: some View {
        TabView {
            inputs
                .tabItem { Label("Входы", systemImage: "display") }
            general
                .tabItem { Label("Общие", systemImage: "gearshape") }
        }
        .onAppear { model.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginStatus()
        }
    }

    private var inputs: some View {
        Form {
            Section("Монитор") {
                Picker("Выбор монитора", selection: Binding(
                    get: { model.state.preferredMonitor },
                    set: { model.apply(.monitor($0)) }
                )) {
                    Text("Автоматически").tag(String?.none)
                    ForEach(model.state.choices) { choice in
                        Text(choice.name).tag(Optional(choice.id)).disabled(!choice.canSelect)
                    }
                }
                .disabled(model.state.isSwitching)
                .background(SettingsScroller().allowsHitTesting(false))

                let detectedName = model.state.preferredMonitor == nil ? model.state.device?.name : nil
                LabeledContent(detectedName ?? "Состояние", value: model.state.connectionStatus)

                if let device = model.state.device, !device.ports.isEmpty {
                    Picker("Вход Mac", selection: Binding(
                        get: { device.macInput },
                        set: { if let input = $0 { model.apply(.macInput(input, device.identity)) } }
                    )) {
                        if device.macInput == nil {
                            Text("Выберите порт").tag(DisplayInput?.none)
                        }
                        ForEach(device.ports) { port in
                            Text(port.name).tag(Optional(port.id))
                        }
                    }
                    .disabled(model.state.isSwitching)
                }
            }

            if let device = model.state.device {
                if !device.ports.isEmpty {
                    Section("Названия и видимость входов") {
                        ForEach(device.ports) { port in
                            MonitorPortRow(
                                port: port,
                                rename: { model.apply(.alias($0, port.id, device.identity)) },
                                setVisibility: { model.apply(.visibility($0, port.id, device.identity)) }
                            )
                            .id("\(device.identity.fingerprint)-\(port.id.hexCode)")
                        }
                    }
                }

                Section {
                    DisclosureGroup("Сведения о мониторе", isExpanded: $showsDetails) {
                        if let lastSeen = device.lastSeen {
                            LabeledContent("Последнее подключение") {
                                Text(lastSeen, format: .dateTime.day().month().hour().minute())
                            }
                        }
                        if let lastSource = device.lastSource {
                            LabeledContent("Последний вход", value: lastSource)
                        }
                        if let serial = device.identity.serialNumber {
                            LabeledContent("Серийный номер EDID", value: String(format: "%08X", serial))
                        }
                        LabeledContent("ID EDID") {
                            HStack(spacing: 8) {
                                Text(device.identity.fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 160)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(device.identity.fingerprint, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .accessibilityLabel("Скопировать ID EDID")
                                .help("Скопировать ID EDID")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускать при входе в macOS", isOn: Binding(
                    get: { model.startsAtLogin },
                    set: { model.setStartsAtLogin($0) }
                ))
                .background(SettingsScroller().allowsHitTesting(false))
                if model.loginStatus == .requiresApproval {
                    LabeledContent("Требуется подтверждение") {
                        Button("Открыть настройки macOS…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = model.loginError {
                    Text(error).foregroundStyle(.secondary)
                }
            }

            Section("Строка меню") {
                Picker("Левый клик", selection: Binding(
                    get: { model.state.leftClickAction },
                    set: { model.apply(.leftClickAction($0)) }
                )) {
                    Text("Открыть меню").tag(LeftClickAction.showMenu)
                    Text("Переключить на Mac").tag(LeftClickAction.selectMac)
                    Text("Чередовать два входа").tag(LeftClickAction.toggleInputs)
                }
                .pickerStyle(.menu)
                .disabled(model.state.isSwitching)

                if model.state.leftClickAction == .toggleInputs {
                    if let device = model.state.device, device.ports.count >= 2 {
                        LabeledContent("Монитор", value: device.name)
                        toggleInputPicker(
                            "Первый вход", selection: \.first, excluding: device.toggleInputs.second, on: device
                        )
                        toggleInputPicker(
                            "Второй вход", selection: \.second, excluding: device.toggleInputs.first, on: device
                        )
                        Text(device.toggleInputs.selection == nil
                            ? "Выберите два входа. Пока пара не задана, левый клик открывает меню."
                            : "Если активен вход вне пары, левый клик выберет первый.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Выберите монитор с двумя известными входами на вкладке «Входы».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Рабочий стол") {
                Toggle(isOn: Binding(
                    get: { model.state.mirrorsOtherInputs },
                    set: { model.apply(.mirroring($0)) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Зеркалировать при другом входе")
                        Text(model.state.mirrorStatus ?? "Показывать рабочий стол на экране MacBook, пока монитор занят другим источником.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Зеркалировать при другом входе")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private func toggleInputPicker(
        _ title: String, selection: WritableKeyPath<InputTogglePair, DisplayInput?>,
        excluding other: DisplayInput?, on device: MonitorSettingsState.Device
    ) -> some View {
        Picker(title, selection: Binding(
            get: { device.toggleInputs[keyPath: selection] },
            set: { input in
                guard let current = model.state.device, current.identity == device.identity else { return }
                var pair = current.toggleInputs
                pair[keyPath: selection] = input
                model.apply(.toggleInputs(pair, device.identity))
            }
        )) {
            Text("Не выбран").tag(DisplayInput?.none)
            ForEach(device.ports.filter { $0.id != other }) { port in
                let alias = port.alias.isEmpty && port.id == device.macInput ? "Этот Mac" : port.alias
                Text(alias.isEmpty || alias == port.name ? port.name : "\(alias) · \(port.name)")
                    .tag(Optional(port.id))
            }
        }
        .pickerStyle(.menu)
        .disabled(model.state.isSwitching)
    }
}

private struct SettingsScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerConfigurationView {
        ScrollerConfigurationView()
    }

    func updateNSView(_ view: ScrollerConfigurationView, context: Context) {
        view.configureScroller()
    }

    final class ScrollerConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScroller()
        }

        func configureScroller() {
            guard let scrollView = enclosingScrollView else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if let scroller = scrollView.verticalScroller, scroller.controlSize != .small {
                scroller.controlSize = .small
            }
        }
    }
}

private struct MonitorPortRow: View {
    let port: MonitorSettingsState.Port
    let rename: (String) -> Void
    let setVisibility: (Bool) -> Void
    @State private var draft: String
    @FocusState private var isEditingName: Bool

    init(port: MonitorSettingsState.Port, rename: @escaping (String) -> Void, setVisibility: @escaping (Bool) -> Void) {
        self.port = port
        self.rename = rename
        self.setVisibility = setVisibility
        _draft = State(initialValue: port.alias)
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(port.name)
                if port.isSelected {
                    Label("Выбран", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 118, alignment: .leading)

            TextField("Название входа \(port.name)", text: $draft, prompt: Text("Добавить название"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($isEditingName)
                .onChange(of: draft) { _, name in rename(name) }
                .onChange(of: isEditingName) { _, editing in
                    if !editing { draft = port.alias }
                }
                .onSubmit { isEditingName = false }

            Toggle("В меню", isOn: Binding(get: { port.isVisible }, set: { setVisibility($0) }))
                .toggleStyle(.checkbox)
                .accessibilityLabel("Показывать \(port.name) в меню")
                .fixedSize()
        }
    }
}
