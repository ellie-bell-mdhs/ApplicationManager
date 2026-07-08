import Foundation

enum MenuBarAppsDiscovery {
    private static let maxSearchDepth = 8

    /// The folder to scan for menu bar apps, derived from where this app lives:
    /// the directory containing the app bundle, or — when the bundle sits in a
    /// project's `build` folder (e.g. `<parent>/<project>/build/App.app`) —
    /// the parent that holds the sibling app projects.
    static func menuBarApplicationsFolder() -> URL? {
        var url = Bundle.main.bundleURL.deletingLastPathComponent()
        if url.lastPathComponent == "build" {
            url = url.deletingLastPathComponent().deletingLastPathComponent()
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    static func discoverApps() -> [LibraryApp] {
        guard let menuBarFolder = menuBarApplicationsFolder() else { return [] }

        let selfBundleID = Bundle.main.bundleIdentifier
        let selfAppName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String

        let bundleURLs = findAppBundles(in: menuBarFolder, remainingDepth: maxSearchDepth)

        let discovered = bundleURLs.compactMap { url in
            makeLibraryApp(from: url, selfBundleID: selfBundleID, selfAppName: selfAppName)
        }
        return deduplicated(discovered)
    }

    private static func findAppBundles(in directory: URL, remainingDepth: Int) -> [URL] {
        guard remainingDepth >= 0 else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var apps: [URL] = []
        for item in contents {
            if let appURL = resolvedAppBundleURL(from: item) {
                apps.append(appURL)
                continue
            }

            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            let name = item.lastPathComponent
            if name == ".git" || name.hasPrefix(".") {
                continue
            }

            apps.append(contentsOf: findAppBundles(in: item, remainingDepth: remainingDepth - 1))
        }

        return apps
    }

    /// Resolves `.app` bundles, symlinks, and Finder aliases to a launchable app URL.
    private static func resolvedAppBundleURL(from url: URL) -> URL? {
        if url.pathExtension == "app" {
            return Bundle(url: url) != nil ? url : nil
        }

        if let aliasTarget = try? URL(resolvingAliasFileAt: url, options: [.withoutUI]),
           aliasTarget.pathExtension == "app",
           Bundle(url: aliasTarget) != nil {
            return aliasTarget
        }

        let resolvedPath = (url.path as NSString).resolvingSymlinksInPath
        if resolvedPath != url.path {
            let resolvedURL = URL(fileURLWithPath: resolvedPath)
            if resolvedURL.pathExtension == "app", Bundle(url: resolvedURL) != nil {
                return resolvedURL
            }
        }

        return nil
    }

    private static func makeLibraryApp(
        from url: URL,
        selfBundleID: String?,
        selfAppName: String?
    ) -> LibraryApp? {
        guard let bundle = Bundle(url: url) else { return nil }

        let bundleID = bundle.bundleIdentifier
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        if bundleID == selfBundleID || name == selfAppName {
            return nil
        }

        let id = bundleID ?? url.deletingPathExtension().lastPathComponent.lowercased()
        let symbolName = AppBundleIcon.resolvedSymbolName(for: url)
        return LibraryApp(
            id: id,
            name: name,
            path: url.path,
            bundleIdentifier: bundleID,
            symbolName: symbolName
        )
    }

    private static func deduplicated(_ apps: [LibraryApp]) -> [LibraryApp] {
        var seen = Set<String>()
        var result: [LibraryApp] = []

        for app in apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let key = app.resolvedBundleIdentifier ?? app.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(app)
        }

        return result
    }
}
