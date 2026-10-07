import BiscuitKit
import SwiftUI

/// Non-modal update notice. Never interrupts a running job.
struct UpdateBanner: View {
    @Environment(AppEnvironment.self) private var env

    private var updater: UpdateService { env.updater }

    var body: some View {
        switch updater.status {
        case .available(let release):
            available(release)

        case .downloading(let fraction):
            SectionCard(title: t(.updateDownloadingTitle), systemImage: "arrow.down.circle") {
                ProgressView(value: fraction) {
                    Text("\(Int((fraction * 100).rounded())) %")
                        .font(.caption.monospacedDigit())
                }
            }

        case .verifying:
            SectionCard(title: t(.updateVerifyingTitle), systemImage: "checkmark.shield") {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(t(.updateVerifyingDetail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .readyToRelaunch(_, let version):
            SectionCard(title: t(.updateReadyTitle), systemImage: "arrow.triangle.2.circlepath") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t(.updateReadyDetail, version))
                            .font(.callout)
                        Text(t(.updateReadySubtitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(t(.updateActionRelaunch)) { updater.installAndRelaunch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(env.coordinator.isRunning)
                }
            }

        case .failed(let error):
            CalloutView(
                kind: .warning,
                text: t(.updateFailedBanner, error.message),
                detail: error.remedy ?? error.diagnostics
            )

        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    private func available(_ release: UpdateService.Release) -> some View {
        SectionCard(title: t(.updateAvailableTitle), systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t(.updateAvailableVersion, release.version))
                            .font(.callout.weight(.medium))
                        Text(t(.updateAvailableSubtitle, AppInfo.version, ByteCount.format(release.sizeBytes)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(t(.updateActionInstall)) {
                        Task { await updater.downloadAndStage(release) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(env.coordinator.isRunning)
                }

                if !release.notes.isEmpty {
                    DisclosureGroup(t(.updateChanges)) {
                        Text(release.notes)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
        }
    }
}
