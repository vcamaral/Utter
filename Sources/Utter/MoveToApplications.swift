import AppKit

/// Offers to move the app into /Applications when it's launched from anywhere else (typically straight
/// from the DMG), since Spotlight and Launch at Login need the app to live there.
enum MoveToApplications {
    private static let suppressKey = "moveToApplicationsSuppressed"
    private static let destination = URL(fileURLWithPath: "/Applications/Utter.app")

    static func offerIfNeeded() {
        let current = originalBundleURL()
        // Builds from a git clone (build.sh) are installed by build.sh itself.
        guard Bundle.main.object(forInfoDictionaryKey: "UtterSourceDir") == nil,
              !isInApplicationsFolder(current),
              !UserDefaults.standard.bool(forKey: suppressKey) else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Utter to the Applications folder?"
        alert.informativeText = "Utter works best from Applications — that's where Spotlight finds it and where Open at Login expects it."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return }

        do {
            try move(from: current)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Couldn't move Utter to Applications"
            failure.informativeText = "Drag Utter into the Applications folder yourself. (\(error.localizedDescription))"
            failure.runModal()
        }
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return parent == "/Applications" || parent == userApps
    }

    private static func move(from source: URL) throws {
        let fm = FileManager.default
        let volume = try source.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey])
        let fromDiskImage = volume.volumeIsReadOnly == true

        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        // The user already approved this copy by opening it; don't make Gatekeeper ask again.
        removeQuarantine(destination)
        if !fromDiskImage {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }

        // Relaunch from the new location once this instance has quit, and eject the DMG we came from.
        var script = "sleep 1; /usr/bin/open \"\(destination.path)\""
        if fromDiskImage, let volumeURL = volume.volume, volumeURL.path.hasPrefix("/Volumes/") {
            script += "; /usr/bin/hdiutil detach \"\(volumeURL.path)\" -quiet"
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private static func removeQuarantine(_ url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /// Where the app really is. Apps opened from a quarantined DMG run from a randomized read-only copy
    /// ("App Translocation"); Security.framework can map that back to the original path.
    private static func originalBundleURL() -> URL {
        let url = Bundle.main.bundleURL
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }

        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(origSym, to: OriginalPath.self)(url as CFURL, nil) else { return url }
        return original.takeRetainedValue() as URL
    }
}
