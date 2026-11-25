import AppKit
import Darwin
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var addAppMenu: NSMenu?
    private var config = LibraryConfig(apps: [])

    func applicationDidFinishLaunching(_ notification: Notification) {
        reloadLibrary()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = menuBarImage
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.toolTip = "Application Manager"
        }
        statusItem = item
        MenuBarAppCandidates.warmUpInBackground()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        reloadLibrary()
        showMenu()
    }

    private func reloadLibrary() {
        config = LibraryStore.load()
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        if config.apps.isEmpty {
            let emptyItem = NSMenuItem(title: "No apps in library", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for app in config.apps {
                menu.addItem(makeAppMenuItem(for: app))
            }
        }

        menu.addItem(.separator())

        let manageItem = NSMenuItem(title: "Manage Library", action: nil, keyEquivalent: "")
        let manageMenu = NSMenu()

        // Filled in menuNeedsUpdate, only when opened: finding running menu bar apps
        // takes a fraction of a second, too slow to do on every click of the icon.
        let addMenu = NSMenu()
        addMenu.delegate = self
        addMenu.autoenablesItems = false
        addAppMenu = addMenu
        let addItem = NSMenuItem(title: "Add Application", action: nil, keyEquivalent: "")
        addItem.submenu = addMenu
        manageMenu.addItem(addItem)

        manageMenu.addItem(
            withTitle: "Refresh Library",
            action: #selector(refreshLibrary),
            keyEquivalent: "r"
        ).target = self

        if !config.apps.isEmpty {
            manageMenu.addItem(.separator())
            for app in config.apps {
                let removeItem = NSMenuItem(
                    title: "Remove \(app.name)",
                    action: #selector(removeApplication(_:)),
                    keyEquivalent: ""
                )
                removeItem.target = self
                removeItem.representedObject = app.id
                manageMenu.addItem(removeItem)
            }
        }

        manageItem.submenu = manageMenu
        menu.addItem(manageItem)

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Quit Application Manager",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ).target = self

        // Attaching the menu and clicking lets macOS place it under the icon;
        // a manual popUp(at:) lands in the wrong spot on some menu bar layouts.
        statusItem?.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next click reaches statusItemClicked and rebuilds the menu.
        guard menu === statusItem?.menu else { return }
        statusItem?.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === addAppMenu else { return }
        menu.removeAllItems()

        let candidates = MenuBarAppCandidates.candidates(excluding: config.apps)
        if candidates.isEmpty {
            let noneItem = NSMenuItem(title: "No other menu bar apps found", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        }
        for candidate in candidates {
            let item = NSMenuItem(
                title: candidate.isRunning ? "\(candidate.name)  ✓" : candidate.name,
                action: #selector(addCandidate(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.url
            item.image = AppBundleIcon.menuIcon(for: candidate.url)
            item.toolTip = candidate.url.path
            menu.addItem(item)
        }

        if !MenuBarAppCandidates.canSeeRunningApps {
            menu.addItem(.separator())
            let allowItem = NSMenuItem(
                title: "Allow Accessibility to Find Running Apps…",
                action: #selector(requestAccessibility),
                keyEquivalent: ""
            )
            allowItem.target = self
            allowItem.toolTip = "Without it, only installed menu bar-only apps are listed."
            menu.addItem(allowItem)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Choose Other Application…",
            action: #selector(chooseOtherApplication),
            keyEquivalent: ""
        ).target = self
    }

    private func makeAppMenuItem(for app: LibraryApp) -> NSMenuItem {
        let running = isRunning(app)
        let exists = FileManager.default.fileExists(atPath: app.url.path)

        var title = app.name
        if running {
            title += "  ✓"
        } else if !exists {
            title += "  (missing)"
        }

        let item = NSMenuItem(title: title, action: #selector(toggleApp(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = app.id
        item.isEnabled = exists

        item.image = menuIcon(for: app)

        if running {
            item.toolTip = "Running — click to turn off"
        } else if exists {
            item.toolTip = "Off — click to turn on"
        } else {
            item.toolTip = "App not found at \(app.path)"
        }

        return item
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? String,
              let app = config.apps.first(where: { $0.id == appID }) else {
            return
        }

        let runningApps = runningApplications(for: app)
        if !runningApps.isEmpty {
            quitApplications(runningApps)
            return
        }

        guard FileManager.default.fileExists(atPath: app.url.path) else {
            showAlert(
                title: "App Not Found",
                message: "\(app.name) was not found at:\n\(app.path)\n\nUse Refresh Library after building, or edit the config path."
            )
            return
        }

        launchInMenuBar(app)
    }

    /// Start in the background with windows hidden, so apps that also open a
    /// main window (e.g. Wispr Flow) come up in the menu bar only.
    private func launchInMenuBar(_ app: LibraryApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true

        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { runningApp, error in
            if let runningApp {
                DispatchQueue.main.async { self.keepHiddenWhileStarting(runningApp) }
            }
            if let error {
                DispatchQueue.main.async {
                    self.showAlert(
                        title: "Launch Failed",
                        message: "Could not launch \(app.name):\n\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Some apps (e.g. Wispr Flow) ignore the hidden-launch request: they show their
    /// main window and bring themselves to the front once loaded. Keep hiding them
    /// while they start. Wispr Flow (with "Hide app in Dock" on) drops its Dock icon
    /// once its window is hidden; at that point un-hide it so its dictation bar can
    /// still appear. Menu bar-only apps are skipped.
    private func keepHiddenWhileStarting(_ runningApp: NSRunningApplication, checksLeft: Int = 30) {
        guard checksLeft > 0, !runningApp.isTerminated else { return }

        if runningApp.activationPolicy == .accessory {
            if runningApp.isHidden { runningApp.unhide() }
            return
        }
        if runningApp.activationPolicy == .regular, !runningApp.isHidden {
            runningApp.hide()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.keepHiddenWhileStarting(runningApp, checksLeft: checksLeft - 1)
        }
    }

    /// Adds a menu bar app picked from the list and turns it on.
    @objc private func addCandidate(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let entry = addToLibrary(url)
        if !isRunning(entry) {
            launchInMenuBar(entry)
        }
    }

    @objc private func requestAccessibility() {
        MenuBarAppCandidates.requestAccessibilityPermission()
    }

    @objc private func chooseOtherApplication() {
        let panel = NSOpenPanel()
        panel.title = "Add Application"
        panel.message = "Choose an app to add to your library."
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        addToLibrary(url)
        showMenu()
    }

    @discardableResult
    private func addToLibrary(_ url: URL) -> LibraryApp {
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        let baseID = bundleID ?? url.deletingPathExtension().lastPathComponent.lowercased()
        var uniqueID = baseID
        var suffix = 2
        while config.apps.contains(where: { $0.id == uniqueID }) {
            uniqueID = "\(baseID)-\(suffix)"
            suffix += 1
        }

        let entry = LibraryApp(
            id: uniqueID,
            name: name,
            path: url.path,
            bundleIdentifier: bundleID,
            symbolName: AppBundleIcon.resolvedSymbolName(for: url)
        )

        LibraryStore.includeApp(entry, in: &config)
        config.apps.append(entry)
        LibraryStore.save(config)
        reloadLibrary()
        return entry
    }

    @objc private func removeApplication(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? String,
              let app = config.apps.first(where: { $0.id == appID }) else { return }
        LibraryStore.excludeApp(app, from: &config)
        LibraryStore.save(config)
        reloadLibrary()
        showMenu()
    }

    @objc private func refreshLibrary() {
        reloadLibrary()
        showMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func isRunning(_ app: LibraryApp) -> Bool {
        !runningApplications(for: app).isEmpty
    }

    private func runningApplications(for app: LibraryApp) -> [NSRunningApplication] {
        var matchedPIDs = Set<pid_t>()
        var matches: [NSRunningApplication] = []

        for runningApp in NSWorkspace.shared.runningApplications {
            guard isUserOwnedProcess(runningApp) else { continue }

            if belongs(runningApp, to: app),
               matchedPIDs.insert(runningApp.processIdentifier).inserted {
                matches.append(runningApp)
            }
        }

        return matches
    }

    /// The app itself, or one of its own helper processes (e.g. Wispr Flow's
    /// `com.electron.wispr-flow.helper`). Only the app's full ID or bundle path count:
    /// apps from the same developer share an ID prefix (`com.megadata.claudeping` and
    /// `com.megadata.claudespeech`), and turning one off must not quit the other.
    private func belongs(_ runningApp: NSRunningApplication, to app: LibraryApp) -> Bool {
        if let bundleID = app.resolvedBundleIdentifier, let runningBundleID = runningApp.bundleIdentifier,
           runningBundleID == bundleID || runningBundleID.hasPrefix(bundleID + ".") {
            return true
        }

        if let runningPath = runningApp.bundleURL?.path,
           runningPath == app.url.path || runningPath.hasPrefix(app.url.path + "/") {
            return true
        }

        let appFolderName = app.url.deletingPathExtension().lastPathComponent
        return runningApp.localizedName == app.name || runningApp.localizedName == appFolderName
    }

    private func isUserOwnedProcess(_ runningApp: NSRunningApplication) -> Bool {
        let pid = runningApp.processIdentifier
        guard pid > 0 else { return false }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return false }
        return info.pbi_uid == getuid()
    }

    private func quitApplications(_ apps: [NSRunningApplication]) {
        for app in apps {
            _ = app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for app in apps where !app.isTerminated {
                app.forceTerminate()
            }
        }
    }

    private func menuIcon(for app: LibraryApp) -> NSImage? {
        if FileManager.default.fileExists(atPath: app.url.path),
           let icon = AppBundleIcon.menuIcon(for: app.url) {
            return icon
        }

        let symbolName = AppBundleIcon.resolvedSymbolName(for: app.url, storedSymbolName: app.symbolName)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: app.name) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private var menuBarImage: NSImage? {
        guard let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Application Manager") else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
