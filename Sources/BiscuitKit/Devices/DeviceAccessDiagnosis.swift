import Foundation

/// Turns a failed open of the raw device node into something actionable.
///
/// The distinction that matters is `EPERM` versus `EACCES`, and it took a
/// real USB stick to surface it. A process without the file permissions
/// gets `EACCES` (13); the helper runs as root, so file modes cannot stop
/// it — and it got `EPERM` (1). On macOS that is the signature of a
/// *policy* denial rather than a permission one: raw disk access is gated
/// by Full Disk Access, which applies to root as well.
///
/// Full Disk Access cannot be requested programmatically. There is no
/// prompt to trigger, unlike `NSRemovableVolumesUsageDescription`, which
/// governs the filesystem of a *mounted* removable volume and is a
/// different TCC service entirely. So the only useful thing to do is say
/// precisely what to grant and where — which the previous version did not:
/// it reported "access denied" plus a bare errno and left the user with no
/// way forward.
public enum DeviceAccessDiagnosis {
    public static func error(errno code: Int32, path: String) -> BiscuitError {
        let diagnostics = "open \(path) O_WRONLY failed, errno \(code): "
            + String(cString: strerror(code))
        switch code {
        case EPERM:
            return BiscuitError(
                kind: .partitioningFailed,
                message: t(.errorDeviceNeedsFullDiskAccess),
                remedy: t(.errorDeviceNeedsFullDiskAccessRemedy),
                diagnostics: diagnostics
            )
        case EBUSY:
            return BiscuitError(
                kind: .partitioningFailed,
                message: t(.errorDeviceBusy),
                remedy: t(.errorDeviceBusyRemedy),
                diagnostics: diagnostics
            )
        default:
            return BiscuitError(
                kind: .partitioningFailed,
                message: t(.errorDeviceAccessDenied),
                diagnostics: diagnostics
            )
        }
    }
}
