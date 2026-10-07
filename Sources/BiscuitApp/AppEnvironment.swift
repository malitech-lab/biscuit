import BiscuitKit
import Foundation
import Observation

/// Composition root. Owns the long-lived services and wires them together so
/// views receive one object rather than five.
@MainActor
@Observable
final class AppEnvironment {
    let monitor: DeviceMonitor
    let coordinator: JobCoordinator
    let updater: UpdateService
    let broker: PrivilegeBroker
    let language: LanguageSetting
    let catalogue: CatalogueService

    private(set) var startupWarnings: [String] = []

    init() {
        let appSupport: URL
        do {
            appSupport = try AppInfo.applicationSupportDirectory()
        } catch {
            // Falling back to a temporary directory keeps the app usable; the
            // only consequence is that the session directory is not persisted,
            // which it never needed to be.
            appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Biscuit", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: appSupport,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let broker = PrivilegeBroker(
            appSupport: appSupport,
            helperExecutable: BundledTools.helperPath,
            clientBundlePrefix: BundledTools.clientBundlePrefix,
            clientVersion: "\(AppInfo.version) (\(AppInfo.build))"
        )
        let monitor = DeviceMonitor()

        self.broker = broker
        self.monitor = monitor
        self.coordinator = JobCoordinator(broker: broker, monitor: monitor)
        self.updater = UpdateService()
        // Applied before any view body runs, so the first frame is already in
        // the chosen language.
        self.language = LanguageSetting()
        self.catalogue = CatalogueService(appSupport: appSupport)

        collectStartupWarnings()
    }

    func start() {
        monitor.start()
        Task { await updater.checkAutomaticallyIfDue() }
    }

    func shutdown() async {
        monitor.stop()
        await broker.teardown()
    }

    /// Problems worth telling the user about before they start, rather than
    /// failing mid-write.
    private func collectStartupWarnings() {
        var warnings: [String] = []

        if !FileManager.default.isExecutableFile(atPath: BundledTools.helperPath.path) {
            warnings.append(t(.startupHelperMissing, BundledTools.helperPath.lastPathComponent))
        }

        if !BundledTools.isWimlibAvailable {
            warnings.append(t(.startupWimlibMissing))
        }

        if !AppInfo.isRunningFromAppBundle {
            warnings.append(t(.startupDevelopmentMode))
        }

        startupWarnings = warnings
    }
}
