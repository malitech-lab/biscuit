import BiscuitKit
import DiskArbitration
import Foundation
import Observation

/// Keeps the device list current without polling.
///
/// DiskArbitration delivers appear/disappear/change callbacks on a run loop; we
/// use them only as a trigger to re-run a full `diskutil` enumeration. Deriving
/// the model from one authoritative snapshot rather than mutating it per event
/// avoids the class of bug where a missed or reordered callback leaves the UI
/// showing a stick that is no longer plugged in.
@MainActor
@Observable
final class DeviceMonitor {
    private(set) var devices: [StorageDevice] = []
    private(set) var isRefreshing = false
    private(set) var lastError: BiscuitError?

    /// Devices offered as write targets.
    var eligibleDevices: [StorageDevice] {
        devices.filter(\.isEligibleTarget)
    }

    /// Attached devices we refuse to touch, surfaced so the user understands why
    /// their drive is missing from the list rather than assuming a bug.
    var blockedDevices: [StorageDevice] {
        devices.filter { !$0.isEligibleTarget }
    }

    private let inspector = DeviceInspector()
    private var session: DASession?
    private var refreshTask: Task<Void, Never>?
    private var coalesceTask: Task<Void, Never>?

    init() {}

    // MARK: - Lifecycle

    func start() {
        guard session == nil else { return }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            lastError = BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorDiskArbitrationUnavailable),
                remedy: t(.errorDiskArbitrationUnavailableRemedy)
            )
            Task { await refresh() }
            return
        }
        self.session = session

        // `Unmanaged` round-trip: DiskArbitration callbacks are C function
        // pointers, so the only way to reach `self` is an opaque context pointer.
        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { _, context in
            DeviceMonitor.handleCallback(context)
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            DeviceMonitor.handleCallback(context)
        }, context)

        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, context in
            DeviceMonitor.handleCallback(context)
        }, context)

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        Task { await refresh() }
    }

    func stop() {
        coalesceTask?.cancel()
        refreshTask?.cancel()
        guard let session else { return }
        DASessionUnscheduleFromRunLoop(
            session,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        self.session = nil
    }

    private static func handleCallback(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.scheduleRefresh()
        }
    }

    // MARK: - Refreshing

    /// Plugging in a single stick fires several callbacks in quick succession
    /// (whole disk, then each partition). Coalescing them into one enumeration
    /// keeps `diskutil` from being invoked a dozen times per insertion.
    private func scheduleRefresh() {
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        refreshTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            do {
                let result = try await self.inspector.enumerateDevices()
                guard !Task.isCancelled else { return }
                self.devices = result
                self.lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.lastError = BiscuitError.wrap(error)
            }
        }
        refreshTask = task
        await task.value
    }

    /// Looks a device back up by BSD name, returning nil if it has gone away.
    func device(withBSDName bsdName: String) -> StorageDevice? {
        devices.first { $0.bsdName == bsdName }
    }
}
