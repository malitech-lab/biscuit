import BiscuitKit
import AppKit
import SwiftUI

/// Shows the result of the previous run once the form is visible again.
struct OutcomeSection: View {
    @Environment(AppEnvironment.self) private var env

    private var coordinator: JobCoordinator { env.coordinator }

    var body: some View {
        if let result = coordinator.result, coordinator.state == .succeeded {
            successCard(result)
        } else if let failure = coordinator.failure, coordinator.state == .failed {
            failureCard(failure)
        }
    }

    private func successCard(_ result: JobResult) -> some View {
        SectionCard(title: t(.outcomeTitleDone), systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                CalloutView(
                    kind: .success,
                    text: successHeadline,
                    detail: successDetail(result)
                )

                ForEach(result.warnings, id: \.self) { warning in
                    CalloutView(kind: .warning, text: warning)
                }

                if coordinator.strategy == .windowsFAT32 {
                    Text(t(.outcomeWindowsBootHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var successHeadline: String {
        switch coordinator.strategy {
        case .eraseOnly: return t(.outcomeErased)
        case .macOSInstaller: return t(.outcomeMacOSReady)
        case .windowsFAT32: return t(.outcomeWindowsReady)
        case .rawImage: return t(.outcomeImageWritten)
        }
    }

    private func successDetail(_ result: JobResult) -> String {
        var parts = [t(.outcomeDuration, ByteCount.formatDuration(result.duration))]
        if result.bytesWritten > 0 {
            parts.append(t(.outcomeTransferred, ByteCount.format(result.bytesWritten)))
        }
        if result.verified {
            parts.append(t(.outcomeVerified))
        }
        return parts.joined(separator: " · ")
    }

    /// Deep link to Privacy & Security → Full Disk Access.
    ///
    /// Verified to be accepted by `open(1)` on macOS 27 before being used here.
    static let fullDiskAccessPane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    private func failureCard(_ failure: BiscuitError) -> some View {
        SectionCard(title: t(.outcomeTitleFailed), systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 10) {
                CalloutView(
                    kind: failure.isCancellation ? .warning : .error,
                    text: failure.message,
                    detail: failure.remedy
                )

                // Full Disk Access cannot be requested programmatically, so the
                // best Biscuit can do is take the user to the right pane. A
                // written path they have to retype is not enough when the
                // alternative is one click.
                if failure.message == t(.errorDeviceNeedsFullDiskAccess) {
                    Button(t(.outcomeOpenPrivacySettings)) {
                        if let url = URL(string: Self.fullDiskAccessPane) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let diagnostics = failure.diagnostics {
                    DisclosureGroup(t(.outcomeTechnicalDetails)) {
                        Text(diagnostics)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .font(.caption)
                }

                HStack {
                    Button(t(.actionCopyLog)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            coordinator.exportableLog(),
                            forType: .string
                        )
                    }
                    .controlSize(.small)

                    if failure.kind == .wimToolMissing {
                        Button(t(.outcomeCopyBrewCommand)) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install wimlib", forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
