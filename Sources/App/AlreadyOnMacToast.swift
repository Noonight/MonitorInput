import AppKit

@MainActor
final class AlreadyOnMacToast {
    private var panel: ToastPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ message: String, below anchor: NSView) {
        guard let window = anchor.window, let screen = window.screen else { return }
        dismiss()
        let panel = makePanel(message: message)
        self.panel = panel
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let available = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: max(available.minX, min(anchorFrame.midX - size.width / 2, available.maxX - size.width)),
            y: max(available.minY, min(anchorFrame.minY - 6, available.maxY) - size.height)
        ))
        panel.orderFrontRegardless()

        NSAccessibility.post(
            element: anchor,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )

        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_300))
                self?.dismiss()
            } catch {
                // A new presentation or dismissal replaced this timer.
            }
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel(message: String) -> ToastPanel {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        symbol.contentTintColor = .systemGreen
        symbol.setAccessibilityElement(false)

        let row = NSStackView(views: [symbol, label])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 11
        surface.layer?.masksToBounds = true
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6)
        ])

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: row.fittingSize.width + 20, height: row.fittingSize.height + 12),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = surface
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    private final class ToastPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
