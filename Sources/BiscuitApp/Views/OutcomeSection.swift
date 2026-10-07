import BiscuitKit
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

    private func failureCard(_ failure: BiscuitError) -> some View {
        SectionCard(title: t(.outcomeTitleFailed), systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 10) {
                CalloutView(
                    kind: failure.isCancellation ? .warning : .error,
                    text: failure.message,
                    detail: failure.remedy
                )

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
