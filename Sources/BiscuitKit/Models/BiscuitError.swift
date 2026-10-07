import Foundation

/// Every failure surfaced to the user funnels through this type so the GUI can
/// render a consistent title + remedy, and so the helper can transport errors
/// across the IPC boundary losslessly.
public struct BiscuitError: Error, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case cancelled
        case privilegeDenied
        case helperUnavailable
        case helperProtocol
        case deviceNotFound
        case deviceNotEligible
        case deviceTooSmall
        case deviceBusy
        case sourceUnreadable
        case sourceUnsupported
        case imageTooLarge
        case writeFailed
        case verificationFailed
        case partitioningFailed
        case mountFailed
        case copyFailed
        case wimToolMissing
        case wimSplitFailed
        case downloadFailed
        case checksumMismatch
        case signatureInvalid
        case updateFailed
        case internalInconsistency
    }

    public let kind: Kind
    public let message: String
    public let remedy: String?
    /// Raw diagnostic text (stderr, errno description). Shown in the log pane only.
    public let diagnostics: String?

    public init(kind: Kind, message: String, remedy: String? = nil, diagnostics: String? = nil) {
        self.kind = kind
        self.message = message
        self.remedy = remedy
        self.diagnostics = diagnostics
    }

    public var isCancellation: Bool { kind == .cancelled }
}

extension BiscuitError: LocalizedError {
    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { remedy }
}

// MARK: - Common constructors

public extension BiscuitError {
    /// Not a stored constant: the message has to follow a language change made
    /// while the app is running.
    static var cancelled: BiscuitError {
        BiscuitError(kind: .cancelled, message: t(.errorCancelled))
    }

    static func privilegeDenied(_ diagnostics: String? = nil) -> BiscuitError {
        BiscuitError(
            kind: .privilegeDenied,
            message: t(.errorPrivilegeDenied),
            remedy: t(.errorPrivilegeDeniedRemedy),
            diagnostics: diagnostics
        )
    }

    static func helperUnavailable(_ diagnostics: String? = nil) -> BiscuitError {
        BiscuitError(
            kind: .helperUnavailable,
            message: t(.errorHelperUnavailable),
            remedy: t(.errorHelperUnavailableRemedy),
            diagnostics: diagnostics
        )
    }

    static func helperProtocol(_ detail: String) -> BiscuitError {
        BiscuitError(
            kind: .helperProtocol,
            message: t(.errorHelperProtocol),
            remedy: t(.errorHelperProtocolRemedy),
            diagnostics: detail
        )
    }

    static func deviceNotEligible(_ bsdName: String) -> BiscuitError {
        BiscuitError(
            kind: .deviceNotEligible,
            message: t(.errorDeviceNotEligible, bsdName),
            remedy: t(.errorDeviceNotEligibleRemedy)
        )
    }

    static func deviceIsSystemDisk(_ bsdName: String) -> BiscuitError {
        BiscuitError(
            kind: .deviceNotEligible,
            message: t(.errorDeviceIsSystemDisk, bsdName),
            remedy: t(.errorDeviceIsSystemDiskRemedy)
        )
    }

    static func deviceTooSmall(required: UInt64, available: UInt64) -> BiscuitError {
        BiscuitError(
            kind: .deviceTooSmall,
            message: t(.errorDeviceTooSmall),
            remedy: t(
                .errorDeviceTooSmallRemedy,
                ByteCount.format(required),
                ByteCount.format(available)
            )
        )
    }

    static func writeFailed(_ detail: String) -> BiscuitError {
        BiscuitError(
            kind: .writeFailed,
            message: t(.errorWriteFailed),
            remedy: t(.errorWriteFailedRemedy),
            diagnostics: detail
        )
    }

    static func verificationFailed(atOffset offset: UInt64) -> BiscuitError {
        BiscuitError(
            kind: .verificationFailed,
            message: t(.errorVerificationFailed, offset),
            remedy: t(.errorVerificationFailedRemedy)
        )
    }

    static func internalInconsistency(_ detail: String) -> BiscuitError {
        BiscuitError(
            kind: .internalInconsistency,
            message: t(.errorInternal),
            diagnostics: detail
        )
    }
}

// MARK: - Bridging arbitrary errors

public extension BiscuitError {
    /// Normalises any error into a `BiscuitError` without losing detail.
    static func wrap(_ error: any Error, kind: Kind = .internalInconsistency) -> BiscuitError {
        if let typed = error as? BiscuitError { return typed }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return .cancelled
        }
        return BiscuitError(
            kind: kind,
            message: nsError.localizedDescription,
            diagnostics: "\(nsError.domain) \(nsError.code)"
        )
    }

    /// `operation` is a syscall name such as `lseek`, so it stays untranslated —
    /// it is the part a maintainer greps for.
    static func posix(_ code: Int32, operation: String) -> BiscuitError {
        BiscuitError(
            kind: .writeFailed,
            message: t(.errorPosixOperationFailed, operation),
            diagnostics: "errno \(code): \(String(cString: strerror(code)))"
        )
    }
}
