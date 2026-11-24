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
    var connectionStatus = ""
    var isSwitching = false
    var language: AppLanguage = .system
    var leftClickAction: LeftClickAction = .selectMac
    var mirrorsOtherInputs = false
    var mirrorStatus: String?
}

enum MonitorSetting {
    case language(AppLanguage)
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
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var model: MonitorSettingsModel
    @State private var showsDetails = false

    var body: some View {
        let localization = AppLocalization(language: model.state.language)
        TabView {
            inputs(localization)
                .tabItem { Label(localization.text("Inputs"), systemImage: "display") }
            general(localization)
                .tabItem { Label(localization.text("General"), systemImage: "gearshape") }
        }
        .environment(\.locale, localization.locale)
        .onAppear { model.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginStatus()
        }
    }

    private func inputs(_ localization: AppLocalization) -> some View {
        Form {
            Section(localization.text("Monitor")) {
                Picker(localization.text("Select Monitor"), selection: Binding(
                    get: { model.state.preferredMonitor },
                    set: { model.apply(.monitor($0)) }
                )) {
                    Text(localization.text("Automatic")).tag(String?.none)
                    ForEach(model.state.choices) { choice in
                        Text(choice.name).tag(Optional(choice.id)).disabled(!choice.canSelect)
                    }
                }
                .disabled(model.state.isSwitching)
                .background(SettingsScroller().allowsHitTesting(false))

                let detectedName = model.state.preferredMonitor == nil ? model.state.device?.name : nil
                LabeledContent(detectedName ?? localization.text("Status"), value: model.state.connectionStatus)

                if let device = model.state.device, !device.ports.isEmpty {
                    Picker(localization.text("Mac Input"), selection: Binding(
                        get: { device.macInput },
                        set: { if let input = $0 { model.apply(.macInput(input, device.identity)) } }
                    )) {
                        if device.macInput == nil {
                            Text(localization.text("Choose a port")).tag(DisplayInput?.none)
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
                    Section(localization.text("Input Names and Visibility")) {
                        ForEach(device.ports) { port in
                            MonitorPortRow(
                                port: port,
                                localization: localization,
                                rename: { model.apply(.alias($0, port.id, device.identity)) },
                                setVisibility: { model.apply(.visibility($0, port.id, device.identity)) }
                            )
                            .id("\(device.identity.fingerprint)-\(port.id.hexCode)")
                        }
                    }
                }

                Section {
                    DisclosureGroup(localization.text("Monitor Details"), isExpanded: $showsDetails) {
                        if let lastSeen = device.lastSeen {
                            LabeledContent(localization.text("Last Connected")) {
                                Text(lastSeen, format: .dateTime.day().month().hour().minute())
                            }
                        }
                        if let lastSource = device.lastSource {
                            LabeledContent(localization.text("Last Input"), value: lastSource)
                        }
                        if let serial = device.identity.serialNumber {
                            LabeledContent(localization.text("EDID Serial Number"), value: String(format: "%08X", serial))
                        }
                        LabeledContent(localization.text("EDID ID")) {
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
                                .accessibilityLabel(localization.text("Copy EDID ID"))
                                .help(localization.text("Copy EDID ID"))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func general(_ localization: AppLocalization) -> some View {
        Form {
            Section {
                Picker(localization.text("Language"), selection: Binding(
                    get: { model.state.language },
                    set: { model.apply(.language($0)) }
                )) {
                    Text(localization.text("System Default")).tag(AppLanguage.system)
                    Text(verbatim: "Русский").tag(AppLanguage.russian)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                .pickerStyle(.menu)
                .background(SettingsScroller().allowsHitTesting(false))
            }

            Section(localization.text("Startup")) {
                Toggle(localization.text("Launch at login"), isOn: Binding(
                    get: { model.startsAtLogin },
                    set: { model.setStartsAtLogin($0) }
                ))
                if model.loginStatus == .requiresApproval {
                    LabeledContent(localization.text("Approval required")) {
                        Button(localization.text("Open macOS Settings…")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = model.loginError {
                    Text(localization.text("Could not change launch at login. %@", error)).foregroundStyle(.secondary)
                }
            }

            Section(localization.text("Menu Bar")) {
                Picker(localization.text("Left Click"), selection: Binding(
                    get: { model.state.leftClickAction },
                    set: { model.apply(.leftClickAction($0)) }
                )) {
                    Text(localization.text("Open menu")).tag(LeftClickAction.showMenu)
                    Text(localization.text("Switch to Mac")).tag(LeftClickAction.selectMac)
                    Text(localization.text("Toggle between two inputs")).tag(LeftClickAction.toggleInputs)
                }
                .pickerStyle(.menu)
                .disabled(model.state.isSwitching)

                if model.state.leftClickAction == .toggleInputs {
                    if let device = model.state.device, device.ports.count >= 2 {
                        LabeledContent(localization.text("Monitor"), value: device.name)
                        toggleInputPicker(
                            localization.text("First Input"), selection: \.first,
                            excluding: device.toggleInputs.second, on: device, localization: localization
                        )
                        toggleInputPicker(
                            localization.text("Second Input"), selection: \.second,
                            excluding: device.toggleInputs.first, on: device, localization: localization
                        )
                        Text(localization.text(device.toggleInputs.selection == nil
                            ? "Choose two inputs. Until both are set, left-click opens the menu."
                            : "If another input is active, left-click selects the first input."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(localization.text("Choose a monitor with two known inputs in the Inputs tab."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(localization.text("Desktop")) {
                Toggle(isOn: Binding(
                    get: { model.state.mirrorsOtherInputs },
                    set: { model.apply(.mirroring($0)) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localization.text("Mirror when another input is active"))
                        Text(model.state.mirrorStatus ?? localization.text(
                            "Show the desktop on the MacBook display while the monitor shows another source."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(localization.text("Mirror when another input is active"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private func toggleInputPicker(
        _ title: String, selection: WritableKeyPath<InputTogglePair, DisplayInput?>,
        excluding other: DisplayInput?, on device: MonitorSettingsState.Device, localization: AppLocalization
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
            Text(localization.text("Not selected")).tag(DisplayInput?.none)
            ForEach(device.ports.filter { $0.id != other }) { port in
                let alias = port.alias.isEmpty && port.id == device.macInput ? localization.text("This Mac") : port.alias
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
    let localization: AppLocalization
    let rename: (String) -> Void
    let setVisibility: (Bool) -> Void
    @State private var draft: String
    @FocusState private var isEditingName: Bool

    init(
        port: MonitorSettingsState.Port, localization: AppLocalization,
        rename: @escaping (String) -> Void, setVisibility: @escaping (Bool) -> Void
    ) {
        self.port = port
        self.localization = localization
        self.rename = rename
        self.setVisibility = setVisibility
        _draft = State(initialValue: port.alias)
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(port.name)
                if port.isSelected {
                    Label(localization.text("Selected"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 118, alignment: .leading)

            TextField(
                localization.text("%@ input name", port.name), text: $draft,
                prompt: Text(localization.text("Add a name"))
            )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($isEditingName)
                .onChange(of: draft) { _, name in rename(name) }
                .onChange(of: isEditingName) { _, editing in
                    if !editing { draft = port.alias }
                }
                .onSubmit { isEditingName = false }

            Toggle(localization.text("In menu"), isOn: Binding(get: { port.isVisible }, set: { setVisibility($0) }))
                .toggleStyle(.checkbox)
                .accessibilityLabel(localization.text("Show %@ in the menu", port.name))
                .fixedSize()
        }
    }
}
