import CoreGraphics

final class QuartzDesktopMirroring: DesktopMirroring {
    private var savedLayout: SavedLayout?
    private var manuallyRestored: DisplayIdentity?
    private var restorationIncomplete = false

    func mirrorHuawei(_ identity: DisplayIdentity) -> DesktopMirrorState {
        if let saved = savedLayout, saved.identity != identity {
            let restoration = restoreLayout()
            guard restoration == .inactive else { return restoration }
        }
        guard let displays = onlineDisplays() else { return .unavailable }
        if let saved = savedLayout {
            if saved.ownsMirror(in: displays) { return .active }
            if saved.hasSameScreens, !saved.isOriginalLayout {
                // Preserve a layout changed while automation was active.
                manuallyRestored = identity
            }
            savedLayout = nil
        }
        if manuallyRestored == identity { return .inactive }

        let matching = displays.filter { $0.isHuawei(identity) }
        let builtIns = displays.filter { display in
            CGDisplayIsBuiltin(display.id) != 0 && CGDisplayIsActive(display.id) != 0
                && CGDisplayIsAsleep(display.id) == 0
        }
        guard matching.count == 1, let huawei = matching.first,
              builtIns.count == 1, let builtIn = builtIns.first
        else { return .unavailable }

        if mirrorMember(huawei.id, builtIn.id) != nil { return .active }
        guard CGDisplayIsActive(huawei.id) != 0,
              CGDisplayIsInMirrorSet(huawei.id) == 0, CGDisplayIsInMirrorSet(builtIn.id) == 0
        else { return .unavailable }

        let main = CGMainDisplayID()
        let roots = displays.filter { CGDisplayIsActive($0.id) != 0 && CGDisplayMirrorsDisplay($0.id) == kCGNullDirectDisplay }
        var original = roots.compactMap(ScreenLayout.init)
        guard original.count == roots.count else { return .unavailable }
        if let index = original.firstIndex(where: { $0.key.id == main }) {
            let primary = original.remove(at: index)
            original.append(primary)
        }
        guard reconfigure({ CGConfigureDisplayMirrorOfDisplay($0, huawei.id, builtIn.id) }),
              let secondary = mirrorMember(huawei.id, builtIn.id)
        else { return .unavailable }

        savedLayout = SavedLayout(
            identity: identity, huawei: huawei, builtIn: builtIn, secondary: secondary,
            main: main, original: original, peersAfterMirroring: peers(in: displays, huawei: huawei, builtIn: builtIn)
        )
        restorationIncomplete = false
        return .active
    }

    func restoreLayout() -> DesktopMirrorState {
        manuallyRestored = nil
        guard let saved = savedLayout else { return restorationIncomplete ? .restoreFailed : .inactive }
        guard let displays = onlineDisplays() else { return .restoreFailed }
        guard saved.ownsMirror(in: displays) else {
            savedLayout = nil
            return .inactive
        }

        let samePeers = peers(in: displays, huawei: saved.huawei, builtIn: saved.builtIn) == saved.peersAfterMirroring
        if samePeers, restoreOriginalLayout(saved) {
            if mirrorMember(saved.huawei.id, saved.builtIn.id) == nil {
                savedLayout = nil
                restorationIncomplete = !saved.isOriginalLayout
                return restorationIncomplete ? .restoreFailed : .inactive
            }
        }

        // A changed topology or unavailable mode can prevent exact restoration.
        if let current = onlineDisplays(), saved.ownsMirror(in: current),
           reconfigure({ CGConfigureDisplayMirrorOfDisplay($0, saved.secondary, kCGNullDirectDisplay) }),
           mirrorMember(saved.huawei.id, saved.builtIn.id) == nil {
            savedLayout = nil
        }
        restorationIncomplete = !saved.isOriginalLayout
        return restorationIncomplete ? .restoreFailed : .inactive
    }

    private func restoreOriginalLayout(_ saved: SavedLayout) -> Bool {
        reconfigure { configuration in
            let unmirror = CGConfigureDisplayMirrorOfDisplay(configuration, saved.secondary, kCGNullDirectDisplay)
            guard unmirror == .success else { return unmirror }
            for screen in saved.original where screen.key == saved.huawei || screen.key == saved.builtIn {
                let mode = CGConfigureDisplayWithDisplayMode(configuration, screen.key.id, screen.mode, nil)
                guard mode == .success else { return mode }
            }
            for screen in saved.original {
                let position = CGConfigureDisplayOrigin(configuration, screen.key.id, screen.x, screen.y)
                guard position == .success else { return position }
            }
            return .success
        }
    }

    private func peers(in displays: [ScreenKey], huawei: ScreenKey, builtIn: ScreenKey) -> [ScreenKey: PeerLayout] {
        var result: [ScreenKey: PeerLayout] = [:]
        for display in displays where display != huawei && display != builtIn {
            result[display] = PeerLayout(display.id)
        }
        return result
    }

    private func onlineDisplays() -> [ScreenKey]? {
        var ids = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success, count < ids.count
        else { return nil }
        return ids.prefix(Int(count)).map(ScreenKey.init)
    }

    private func reconfigure(_ configure: (CGDisplayConfigRef) -> CGError) -> Bool {
        var draft: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&draft) == .success, let draft else { return false }
        guard configure(draft) == .success else {
            CGCancelDisplayConfiguration(draft)
            return false
        }
        // WindowServer can undo this configuration if the app exits mid-switch.
        return CGCompleteDisplayConfiguration(draft, .forAppOnly) == .success
    }

    private struct ScreenKey: Hashable {
        let id: CGDirectDisplayID
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32?

        init(_ id: CGDirectDisplayID) {
            self.id = id
            vendor = CGDisplayVendorNumber(id)
            model = CGDisplayModelNumber(id)
            let number = CGDisplaySerialNumber(id)
            serial = number == 0 || number == .max ? nil : number
        }

        var isCurrent: Bool { CGDisplayIsOnline(id) != 0 && ScreenKey(id) == self }

        func isHuawei(_ identity: DisplayIdentity) -> Bool {
            guard CGDisplayIsBuiltin(id) == 0, vendor == DisplayProtocol.vendorID, model == DisplayProtocol.modelID,
                  let expected = identity.serialNumber
            else { return false }
            return serial == expected
        }
    }

    private struct ScreenLayout {
        let key: ScreenKey
        let mode: CGDisplayMode
        let x: Int32
        let y: Int32

        init?(_ key: ScreenKey) {
            let origin = CGDisplayBounds(key.id).origin
            guard let mode = CGDisplayCopyDisplayMode(key.id),
                  let x = Int32(exactly: origin.x), let y = Int32(exactly: origin.y)
            else { return nil }
            self.key = key
            self.mode = mode
            self.x = x
            self.y = y
        }

        var matchesCurrent: Bool {
            guard key.isCurrent, let currentMode = CGDisplayCopyDisplayMode(key.id) else { return false }
            let origin = CGDisplayBounds(key.id).origin
            return origin.x == CGFloat(x) && origin.y == CGFloat(y)
                && currentMode.ioDisplayModeID == mode.ioDisplayModeID
                && currentMode.pixelWidth == mode.pixelWidth && currentMode.pixelHeight == mode.pixelHeight
                && currentMode.refreshRate == mode.refreshRate
        }
    }

    private struct PeerLayout: Equatable {
        let bounds: CGRect
        let modeID: Int32?
        let mirrorSource: CGDirectDisplayID
        let active: Bool

        init(_ id: CGDirectDisplayID) {
            bounds = CGDisplayBounds(id)
            modeID = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
            mirrorSource = CGDisplayMirrorsDisplay(id)
            active = CGDisplayIsActive(id) != 0
        }
    }

    private struct SavedLayout {
        let identity: DisplayIdentity
        let huawei: ScreenKey
        let builtIn: ScreenKey
        let secondary: CGDirectDisplayID
        let main: CGDirectDisplayID
        let original: [ScreenLayout]
        let peersAfterMirroring: [ScreenKey: PeerLayout]

        var hasSameScreens: Bool { huawei.isCurrent && builtIn.isCurrent }

        var isOriginalLayout: Bool {
            mirrorMember(huawei.id, builtIn.id) == nil && CGMainDisplayID() == main
                && original.allSatisfy(\.matchesCurrent)
        }

        func ownsMirror(in displays: [ScreenKey]) -> Bool {
            guard hasSameScreens, mirrorMember(huawei.id, builtIn.id) == secondary else { return false }
            return !displays.contains { display in
                guard display != huawei, display != builtIn else { return false }
                let source = CGDisplayMirrorsDisplay(display.id)
                return source == huawei.id || source == builtIn.id
            }
        }
    }
}

private func mirrorMember(_ first: CGDirectDisplayID, _ second: CGDirectDisplayID) -> CGDirectDisplayID? {
    if CGDisplayMirrorsDisplay(first) == second { return first }
    if CGDisplayMirrorsDisplay(second) == first { return second }
    return nil
}
