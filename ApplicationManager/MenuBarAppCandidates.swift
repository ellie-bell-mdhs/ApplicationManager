import AppKit
import ApplicationServices

/// Finds apps that put an icon in the menu bar, as options for "Add Application".
/// Two sources:
/// - running apps that own a menu bar icon, read through the Accessibility API
///   (needs Accessibility permission; macOS no longer lists these as windows);
/// - installed apps that aren't running but look like menu bar apps: menu bar-only
///   (`LSUIElement`), or their code creates a menu bar icon (`NSStatusBar`, or an
///   Electron `Tray`).
enum MenuBarAppCandidates {
    struct Candidate {
        let url: URL
        let name: String
        let bundleID: String?
        let isRunning: Bool
    }

    private static let installFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    static var canSeeRunningApps: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that opens System Settings › Privacy & Security › Accessibility.
    static func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Candidates not already in `library`, running ones first, each group sorted by name.
    static func candidates(excluding library: [LibraryApp]) -> [Candidate] {
        let libraryBundleIDs = Set(library.compactMap(\.resolvedBundleIdentifier))
        let libraryPaths = Set(library.map { $0.url.resolvingSymlinksInPath().path })
        var seen = Set<String>()

        func accept(_ candidate: Candidate) -> Bool {
            if let bundleID = candidate.bundleID {
                if bundleID == Bundle.main.bundleIdentifier || bundleID.hasPrefix("com.apple.") { return false }
                if libraryBundleIDs.contains(bundleID) { return false }
            }
            if libraryPaths.contains(candidate.url.resolvingSymlinksInPath().path) { return false }
            return seen.insert(candidate.bundleID ?? candidate.url.path).inserted
        }

        let byName: (Candidate, Candidate) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let running = runningMenuBarApps().filter(accept).sorted(by: byName)
        let installed = installedMenuBarApps().filter(accept).sorted(by: byName)
        return running + installed
    }

    private static func runningMenuBarApps() -> [Candidate] {
        guard canSeeRunningApps else { return [] }

        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL, hasMenuBarIcon(app) else { return nil }
            return Candidate(
                url: url,
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundleID: app.bundleIdentifier,
                isRunning: true
            )
        }
    }

    private static func hasMenuBarIcon(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app would otherwise stall the menu for the default 6 seconds.
        AXUIElementSetMessagingTimeout(element, 0.25)

        var extrasBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &extrasBar) == .success,
              let extrasBar else {
            return false
        }

        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(extrasBar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        return ((children as? [Any])?.isEmpty == false)
    }

    /// Apps in the install folders (and one folder down, e.g. `/Applications/Vendor/App.app`)
    /// that look like menu bar apps. For a running app the Accessibility check in
    /// `runningMenuBarApps` is the real answer (the code scan also matches apps whose
    /// icon is switched off), so running ones are skipped here when that check is available.
    private static func installedMenuBarApps() -> [Candidate] {
        installFolders.flatMap { appBundles(in: $0, depth: 1) }.compactMap { url in
            guard let bundle = Bundle(url: url) else { return nil }
            let isRunning = !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundle.bundleIdentifier ?? ""
            ).isEmpty
            if isRunning, canSeeRunningApps { return nil }
            guard isMenuBarOnly(bundle) || createsMenuBarIcon(bundle) else { return nil }

            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return Candidate(url: url, name: name, bundleID: bundle.bundleIdentifier, isRunning: isRunning)
        }
    }

    private static func isMenuBarOnly(_ bundle: Bundle) -> Bool {
        switch bundle.object(forInfoDictionaryKey: "LSUIElement") {
        case let value as Bool: return value
        case let value as String: return value == "1" || value.lowercased() == "yes" || value.lowercased() == "true"
        case let value as NSNumber: return value.boolValue
        default: return false
        }
    }

    /// Code-scan results by app path, reused while the app's executable is unchanged.
    private static var scanCache: [String: (modified: Date, result: Bool)] = [:]
    private static let scanCacheLock = NSLock()

    /// Looks for menu bar icon code in the app's main executable (`NSStatusBar`/`NSStatusItem`/
    /// SwiftUI `MenuBarExtra`, used by native apps) and, for Electron apps, in `app.asar`
    /// (`Tray`). Files are memory-mapped, so only the pages searched are read.
    private static func createsMenuBarIcon(_ bundle: Bundle) -> Bool {
        guard let executable = bundle.executableURL else { return false }
        let asar = bundle.bundleURL.appendingPathComponent("Contents/Resources/app.asar")
        let modified = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        scanCacheLock.lock()
        let cached = scanCache[bundle.bundleURL.path]
        scanCacheLock.unlock()
        if let cached, cached.modified == modified { return cached.result }

        let result = file(executable, contains: ["NSStatusBar", "NSStatusItem", "MenuBarExtra"])
            || file(asar, contains: ["new Tray(", ".Tray("])

        scanCacheLock.lock()
        scanCache[bundle.bundleURL.path] = (modified, result)
        scanCacheLock.unlock()
        return result
    }

    private static func file(_ url: URL, contains needles: [String]) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return needles.contains { data.range(of: Data($0.utf8)) != nil }
    }

    /// Runs the code scan ahead of time so the first "Add Application" opens quickly.
    static func warmUpInBackground() {
        DispatchQueue.global(qos: .utility).async {
            for url in installFolders.flatMap({ appBundles(in: $0, depth: 1) }) {
                if let bundle = Bundle(url: url) { _ = createsMenuBarIcon(bundle) }
            }
        }
    }

    private static func appBundles(in folder: URL, depth: Int) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.flatMap { item -> [URL] in
            if item.pathExtension == "app" { return [item] }
            guard depth > 0,
                  (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            return appBundles(in: item, depth: depth - 1)
        }
    }
}
