import Foundation
#if canImport(UIKit)
import UIKit
#endif

// The guest's virtual monitor and how it is laid out on the device's screen.
//
// A game renders for the virtual monitor win32u reports (build/win32u-unix/
// sysparams_ios.c): it starts at the session default from MADEIRA_SCREEN_W/H,
// and a game's ChangeDisplaySettings programs a new mode, which win32u
// publishes through winios_display_mode_changed() (IOSDisplayShim.m;
// MADEIRA_VIRTUAL_MODE_SET=0 keeps the session default). MetalBackedView reads the current size back (winios_screen_size) and places
// the presented layer with GameSurfaceLayout, so the layer's frame and the
// touch mapping always agree. A library entry chooses the monitor size
// (Resolution) and how it is scaled (Aspect & scaling); the developer
// interface keeps Fit.

/// How the guest surface is mapped into the view's bounds.
enum DisplayMode: String, CaseIterable {
    case fit, fill, stretch, aspect

    /// Older settings stored "fitHeight" (Fill height); it behaved as Fit in
    /// landscape and is gone from the picker, so it decodes to Fit.
    init?(rawValue: String) {
        switch rawValue {
        case "fit", "fitHeight": self = .fit
        case "fill": self = .fill
        case "stretch": self = .stretch
        case "aspect": self = .aspect
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .fit:       return "Fit"
        case .fill:      return "Fill"
        case .stretch:   return "Stretch"
        case .aspect:    return "Aspect"
        }
    }
    var symbol: String {
        switch self {
        case .fit:       return "aspectratio"
        case .fill:      return "arrow.up.left.and.arrow.down.right"
        case .stretch:   return "rectangle.expand.vertical"
        case .aspect:    return "rectangle.ratio.16.to.9"
        }
    }
}

/// Geometry shared by the presented layer's frame and the touch mapping: if
/// the two did their own aspect math, Fill and Stretch would skew input the
/// moment they disagreed by a rounding hair.
enum GameSurfaceLayout {
    /// The rect, in `bounds`'s coordinate space, that the guest surface
    /// occupies for `mode`.
    ///
    /// - Fit: the guest's shape, as large as fits, centred (letterbox).
    /// - Fill: the guest's shape, covering `bounds`; one axis overflows and
    ///   is cropped.
    /// - Stretch: exactly `bounds`.
    /// - Aspect: like Fit, but on the shape of what is actually presented
    ///   (`aspect`, the swapchain drawable, i.e. the game's back buffer). A
    ///   game whose back buffer is 4:3 on a 16:9 monitor is stretched by the
    ///   layer in every other mode; here it is scaled uniformly. Falls back to
    ///   the guest shape until a drawable size is known (`aspect == .zero`).
    static func rect(guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGRect {
        guard guest.width > 0, guest.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        if mode == .stretch { return bounds }
        let useDrawable = mode == .aspect && aspect.width > 0 && aspect.height > 0
        let shape = useDrawable ? aspect : guest
        let sx = bounds.width / shape.width, sy = bounds.height / shape.height
        let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
        let w = shape.width * scale, h = shape.height * scale
        return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                      y: bounds.minY + (bounds.height - h) / 2,
                      width: w, height: h)
    }

    /// A point in `bounds`'s coordinate space (a touch) in guest pixels for
    /// `mode`, clamped to the guest surface; a touch in Fill's cropped margin
    /// clamps to the nearest edge.
    static func map(point: CGPoint, guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGPoint {
        let r = rect(guest: guest, aspect: aspect, bounds: bounds, mode: mode)
        guard r.width > 0, r.height > 0 else { return .zero }
        let x = (point.x - r.minX) * guest.width / r.width
        let y = (point.y - r.minY) * guest.height / r.height
        return CGPoint(x: min(max(x, 0), guest.width - 1),
                       y: min(max(y, 0), guest.height - 1))
    }
}

/// The session default of the guest's virtual monitor.
enum GuestDisplay {
    /// Standard modes a session default is chosen from when no size is given.
    static let standardModes: [(w: Int, h: Int)] = [
        (640, 480), (800, 600), (1024, 768), (1152, 864),
        (1280, 720), (1280, 768), (1280, 800), (1280, 960),
        (1280, 1024), (1360, 768), (1366, 768), (1440, 900),
        (1600, 900), (1600, 1200), (1680, 1050), (1920, 1080),
        (1920, 1200), (2048, 1536), (2560, 1440),
    ]

    /// The standard mode nearest a landscape view's shape, and among modes of
    /// effectively the same shape (0.9 to 2.1 megapixels) the cheapest: a
    /// 19.5:9 phone gets 1280x720, a 4:3 tablet 1152x864.
    static func defaultMode(forLandscapeView size: CGSize) -> (w: Int, h: Int) {
        let fallback = (w: 1280, h: 720)
        guard size.width > 0, size.height > 0 else { return fallback }
        let want = Double(max(size.width, size.height) / min(size.width, size.height))
        let candidates = standardModes.filter { m in
            let px = m.w * m.h
            return px >= 900_000 && px <= 2_100_000
        }
        guard !candidates.isEmpty else { return fallback }
        let error = { (m: (w: Int, h: Int)) in abs(Double(m.w) / Double(m.h) - want) }
        let best = candidates.map(error).min()!
        return candidates.filter { error($0) <= best + 0.01 }
                         .min { $0.w * $0.h < $1.w * $1.h }!
    }

    /// Chooses the session's virtual monitor and exports it for win32u, which
    /// reads MADEIRA_SCREEN_W/H (and MADEIRA_SCREEN_SRC for its log line) the
    /// first time the monitor is queried. `knob` is a "WxH" choice (a library
    /// entry's Resolution); without a valid one the default is the standard
    /// mode nearest the view's shape.
    ///
    /// The size is also published to IOSDisplayShim, so a layout that already
    /// ran re-reads it (MadeiraDisplayModeChangedNotification).
    @discardableResult
    static func configureSessionDefault(view: CGSize, knob: String?) -> (w: Int, h: Int, source: String) {
        var mode = defaultMode(forLandscapeView: view)
        var source = "view"
        if let raw = knob?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parts = raw.lowercased().split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                mode = (w, h)
                source = "knob"
            }
        }
        setenv("MADEIRA_SCREEN_W", String(mode.w), 1)
        setenv("MADEIRA_SCREEN_H", String(mode.h), 1)
        setenv("MADEIRA_SCREEN_SRC", source, 1)
        winios_display_mode_changed(Int32(mode.w), Int32(mode.h))
        return (mode.w, mode.h, source)
    }
}

/// ml1172: the Resolution choices, built from this device's screen.
///
/// Upstream's library offered one fixed list whose default, 1408x648, is a
/// 19.5:9 phone's landscape shape: on an iPad, Fit leaves a third of the
/// screen black. The fork's ml1157 list (0.8x to 2x the screen in points)
/// was device-shaped but far too small on a phone, whose points are few.
/// Here the sizes that fill the screen have its shape at fixed pixel counts,
/// so a choice costs the GPU the same on every device, followed by the usual
/// PC sizes (16:9, 4:3) with a note on how each fits this screen. The
/// library's Resolution picker (games and the Desktop entry) and the
/// developer interface's Resolution menu both show this list; its first
/// choice is the default.
enum ResolutionChoices {
    struct Choice: Hashable {
        let w: Int, h: Int
        let label: String
        var value: String { "\(w)x\(h)" }
    }

    struct Group {
        let title: String
        let choices: [Choice]
    }

    /// The screen in landscape: `points` give its shape, `pixels` its native size.
    struct Screen {
        var points: CGSize
        var pixels: CGSize
    }

    /// Read once. MadeiraApp.init touches it first, on the main thread;
    /// library entries (whose default comes from it) are also made off it.
    static var screen: Screen = {
        #if canImport(UIKit)
        let b = UIScreen.main.bounds, n = UIScreen.main.nativeBounds
        return Screen(points: CGSize(width: max(b.width, b.height), height: min(b.width, b.height)),
                      pixels: CGSize(width: max(n.width, n.height), height: min(n.width, n.height)))
        #else
        // Hosts without UIKit (the host tests): an 11-inch iPad.
        return Screen(points: CGSize(width: 1180, height: 820), pixels: CGSize(width: 2360, height: 1640))
        #endif
    }()

    /// Pixel counts of the screen-shaped choices: a light one (944x656's, 0.8x
    /// an 11-inch iPad's points), the default (1280x720's: 1408x648 on a 19.5:9
    /// iPhone, the size every entry had before these choices, so a game's mode
    /// list is unchanged), then 1920x1080's.
    static let budgets: [(pixels: Int, name: String)] = [
        (944 * 656, "light"), (1280 * 720, "default"), (1920 * 1080, "≈1080p"),
    ]
    static let defaultBudget = 1
    static let widescreen = [(960, 540), (1280, 720), (1600, 900), (1920, 1080), (2560, 1440)]
    static let classic = [(640, 480), (800, 600), (1024, 768), (1280, 960)]

    static func aspect(_ s: Screen) -> Double {
        s.points.height > 0 ? Double(s.points.width / s.points.height) : 16.0 / 9
    }

    /// The screen's shape at about `pixels`, both sides multiples of 8.
    static func shape(_ s: Screen, pixels: Int) -> (w: Int, h: Int) {
        let a = aspect(s)
        let h = Int(((Double(pixels) / a).squareRoot() / 8).rounded()) * 8
        return (Int((Double(h) * a / 8).rounded()) * 8, h)
    }

    /// Whether a w x h monitor has this screen's shape: within 1.5%, where
    /// Fit fills both axes (GameSurfaceLayout.rect).
    static func fills(_ w: Int, _ h: Int, screen s: Screen = screen) -> Bool {
        h > 0 && abs(Double(w) / Double(h) / aspect(s) - 1) < 0.015
    }

    static func defaultSize(for s: Screen = screen) -> (w: Int, h: Int) { shape(s, pixels: budgets[preferredBudget].pixels) }
    static var defaultValue: String { let d = defaultSize(); return "\(d.w)x\(d.h)" }
    /// This screen's shape at the light pixel budget (for 6 GB phones).
    static var lightValue: String { let d = shape(screen, pixels: budgets[0].pixels); return "\(d.w)x\(d.h)" }
    /// 720p-class budget on 8 GB+ devices; light on ~6 GB iPhones (iPhone 13 Pro Max).
    static var preferredBudget: Int { DevicePlayProfile.memoryConstrained ? 0 : defaultBudget }

    static func groups(for s: Screen = screen) -> [Group] {
        let native = (w: Int(s.pixels.width), h: Int(s.pixels.height))
        var own: [Choice] = []
        for (i, b) in budgets.enumerated() {
            let (w, h) = shape(s, pixels: b.pixels)
            // More pixels than the screen has only cost more (never the light or default size).
            if i > defaultBudget && w * h >= native.w * native.h { break }
            own.append(Choice(w: w, h: h, label: "\(w)×\(h) · \(b.name)"))
        }
        if native.w <= 3840, native.h <= 2160, !own.contains(where: { $0.w == native.w && $0.h == native.h }) {
            own.append(Choice(w: native.w, h: native.h, label: "\(native.w)×\(native.h) · native"))
        }
        var out = [Group(title: "This screen's shape", choices: own)]
        for (name, sizes) in [("16:9 widescreen", widescreen), ("4:3 classic", classic)] {
            let (w0, h0) = sizes[0]
            let r = Double(w0) / Double(h0) / aspect(s)
            let note = fills(w0, h0, screen: s) ? "fills this screen" : (r > 1 ? "bars above and below" : "bars at the sides")
            // A size already offered in this screen's shape (1280x720 on a 16:9 phone) is listed once.
            let rest = sizes.filter { size in !own.contains(where: { $0.w == size.0 && $0.h == size.1 }) }
            if !rest.isEmpty {
                out.append(Group(title: "\(name) · \(note)", choices: rest.map { Choice(w: $0.0, h: $0.1, label: "\($0.0)×\($0.1)") }))
            }
        }
        return out
    }

    /// The screen's shape at 480 lines, which MetalFX 1.5× brings to 720 (the
    /// library offers it while a game uses MetalFX 1.5×); nil when `groups`
    /// already have that size (640x480 on a 4:3 iPad).
    static func metalFX(for s: Screen = screen, in groups: [Group]) -> Choice? {
        let w = Int((480 * aspect(s) / 8).rounded()) * 8
        guard (640...4096).contains(w), !groups.contains(where: { $0.choices.contains { $0.w == w && $0.h == 480 } }) else { return nil }
        return Choice(w: w, h: 480, label: "\(w)×480 · for MetalFX 1.5×")
    }

    /// A stored "WxH" that none of `groups` offers (a size chosen on another
    /// device, or typed into madeira.cfg), so a picker never shows a blank
    /// choice; nil when it is offered or does not parse.
    static func extra(_ value: String, in groups: [Group], note: String) -> Choice? {
        let p = value.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 2, !groups.contains(where: { $0.choices.contains { $0.w == p[0] && $0.h == p[1] } }) else { return nil }
        return Choice(w: p[0], h: p[1], label: "\(p[0])×\(p[1]) · \(note)")
    }
}

/// Play defaults for this device. ~6 GB phones (iPhone 13 / 14 Pro Max) render
/// fewer pixels and get a swap tier so Unity and other PC games stay under Jetsam.
enum DevicePlayProfile {
    static let memoryCeilingBytes: UInt64 = 7 * 1024 * 1024 * 1024
    /// Host tests and Mac builds keep the 720p library default.
    static var memoryConstrained: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.physicalMemory < memoryCeilingBytes
        #else
        false
        #endif
    }

    /// Fills only unset madeira.cfg keys, once per install, so a user's own
    /// Memory & sync choices are never overwritten.
    static func applyMemoryDefaultsIfNeeded() {
        let key = "madeira.device-play.memory-v1"
        guard memoryConstrained, !UserDefaults.standard.bool(forKey: key) else { return }
        if MadeiraConfig.get("swap-mb") == nil {
            MadeiraConfig.set("swap-mb", "2048")
            if MadeiraConfig.get("env.MADEIRA_SWAP_COVERAGE") == nil {
                MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", "broad")
            }
        }
        if MadeiraConfig.get("vram-mb") == nil {
            MadeiraConfig.set("vram-mb", "1536")
        }
        UserDefaults.standard.set(true, forKey: key)
        LogStore.shared.log("[device-play] 6GB-class defaults swap-mb=2048 coverage=broad vram-mb=1536")
    }
}

/// Unity and Unreal installs added from drive_c, without Steam.
enum GameEnginePreset {
    static func isCrashHandler(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("unitycrashhandler")
            || name == "crashreportclient"
            || name.hasPrefix("unrealcefsubprocess")
    }

    static func isUnity(at executable: URL) -> Bool {
        isUnityFolder(executable.deletingLastPathComponent(), stem: executable.deletingPathExtension().lastPathComponent)
    }

    static func isUnity(relativePath: String) -> Bool {
        let url = LibraryEntry.hostDrive.appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return isUnityFolder(url, stem: nil) }
        return isUnity(at: url)
    }

    static func isUnityFolder(_ folder: URL, stem: String?) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("UnityPlayer.dll").path) { return true }
        if fm.fileExists(atPath: folder.appendingPathComponent("GameAssembly.dll").path) { return true }
        for name in ["UnityCrashHandler64.exe", "UnityCrashHandler32.exe", "UnityCrashHandler.exe"] {
            if fm.fileExists(atPath: folder.appendingPathComponent(name).path) { return true }
        }
        if let stem {
            var isDir: ObjCBool = false
            let data = folder.appendingPathComponent("\(stem)_Data")
            if fm.fileExists(atPath: data.path, isDirectory: &isDir), isDir.boolValue { return true }
        }
        if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            if items.contains(where: { $0.lastPathComponent.hasSuffix("_Data") && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }) {
                return true
            }
        }
        return false
    }

    /// DirectX 11 in a window at the virtual monitor size: DXMT's usual path,
    /// and Unity's exclusive fullscreen often fails to find a mode.
    static func unityArguments(_ existing: String, resolution: String) -> String {
        var parts = tokens(existing)
        let lower = Set(parts.map { $0.lowercased() })
        func has(_ names: String...) -> Bool { names.contains { lower.contains($0) } }
        if !has("-force-d3d11", "-force-d3d12", "-force-d3d9", "-dx11", "-dx12", "-dx10", "-dx9", "-force-vulkan", "-force-glcore") {
            parts.append("-force-d3d11")
        }
        if !has("-windowed", "-fullscreen") {
            parts.append("-windowed")
        }
        if !has("-popupwindow") {
            parts.append("-popupwindow")
        }
        let size = resolution.lowercased().split(separator: "x").compactMap { Int($0) }
        if size.count == 2, !has("-screen-width") {
            parts.append(contentsOf: ["-screen-width", String(size[0]), "-screen-height", String(size[1])])
        }
        return parts.joined(separator: " ")
    }

    static func isUnreal(relativePath: String) -> Bool {
        let url = LibraryEntry.hostDrive.appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return isUnrealFolder(url) || shippingExecutables(under: url).first != nil }
        return isUnreal(at: url)
    }

    static func isUnreal(at executable: URL) -> Bool {
        let name = executable.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("win64-shipping") || name.contains("win64-test") { return true }
        let folder = executable.deletingLastPathComponent()
        if folder.lastPathComponent.lowercased() == "win64",
           folder.deletingLastPathComponent().lastPathComponent.lowercased() == "binaries" {
            return true
        }
        return isUnrealFolder(folder) || shippingExecutable(from: executable) != nil
    }

    static func isUnrealFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        for name in ["UnrealCEFSubProcess.exe", "CrashReportClient.exe", "UE4PrereqSetup_x64.exe", "UE5PrereqSetup_x64.exe"] {
            if fm.fileExists(atPath: folder.appendingPathComponent(name).path) { return true }
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: folder.appendingPathComponent("Engine/Binaries").path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in items {
                let win64 = item.appendingPathComponent("Binaries/Win64")
                if fm.fileExists(atPath: win64.path, isDirectory: &isDir), isDir.boolValue { return true }
            }
        }
        return false
    }

    /// Game install root: parent of `<Project>/Binaries/Win64`, else the exe folder.
    static func installRoot(from executable: URL) -> URL {
        var folder = executable.deletingLastPathComponent()
        if folder.lastPathComponent.lowercased() == "win64" {
            let binaries = folder.deletingLastPathComponent()
            if binaries.lastPathComponent.lowercased() == "binaries" {
                return binaries.deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        return folder
    }

    /// `Project/Binaries/Win64/*-Win64-Shipping.exe` under the install root.
    static func shippingExecutable(from executable: URL) -> URL? {
        let name = executable.lastPathComponent.lowercased()
        if name.hasSuffix("-win64-shipping.exe") { return executable }
        let root = installRoot(from: executable)
        return shippingExecutables(under: root).first
    }

    static func shippingExecutables(under root: URL, limit: Int = 8) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let skip = Set(["engine", "easyanticheat", "saved", "intermediate", "deriveddatacache", "content"])
        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if skip.contains(url.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent.lowercased().hasSuffix("-win64-shipping.exe") {
                found.append(url)
                if found.count >= limit { break }
            }
        }
        return found
    }

    static func preferredLaunchRelativePath(from relativePath: String) -> String? {
        let url = LibraryEntry.hostDrive.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let shipping = shippingExecutable(from: url) else { return nil }
        let drive = LibraryEntry.hostDrive.resolvingSymlinksInPath().path
        let path = shipping.resolvingSymlinksInPath().path
        guard path.hasPrefix(drive + "/") else { return nil }
        let relative = String(path.dropFirst(drive.count + 1))
        if relative.caseInsensitiveCompare(relativePath) == .orderedSame { return nil }
        return relative
    }

    static func projectName(forShipping url: URL) -> String? {
        let win64 = url.deletingLastPathComponent()
        guard win64.lastPathComponent.lowercased() == "win64" else { return nil }
        let binaries = win64.deletingLastPathComponent()
        guard binaries.lastPathComponent.lowercased() == "binaries" else { return nil }
        let project = binaries.deletingLastPathComponent().lastPathComponent
        return project.isEmpty ? nil : project
    }

    /// DX11 windowed: DXMT's path. -ansimalloc avoids UE5 FMallocBinned2 fatals seen on Valley.
    static func unrealArguments(_ existing: String, project: String?) -> String {
        var parts = tokens(existing)
        let lower = Set(parts.map { $0.lowercased() })
        func has(_ names: String...) -> Bool { names.contains { lower.contains($0) } }
        if let project, !project.isEmpty {
            let hasProject = parts.contains { !$0.hasPrefix("-") && $0.caseInsensitiveCompare(project) == .orderedSame }
            if !hasProject { parts.insert(project, at: 0) }
        }
        if !has("-dx11", "-dx12", "-dx10", "-dx9", "-d3d11", "-d3d12", "-vulkan", "-opengl") {
            parts.append("-dx11")
        }
        if !has("-windowed", "-fullscreen") {
            parts.append("-windowed")
        }
        if !has("-ansimalloc", "-binnedmalloc2", "-binnedmalloc", "-mimalloc") {
            parts.append("-ansimalloc")
        }
        return parts.joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        var out: [String] = [], current = "", quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
