import BiscuitKit
import SwiftUI

/// Last stop before data loss.
///
/// The sheet restates exactly which physical device is about to be erased and
/// what is currently on it, because the most expensive failure mode in a tool
/// like this is a user who was sure they had selected the other drive. The
/// confirm button is deliberately not the default action, so Return cannot
/// trigger it.
struct ConfirmationSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var isPresented: Bool

    private var coordinator: JobCoordinator { env.coordinator }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let device = coordinator.selectedDevice {
                        deviceSummary(device)
                    }
                    operationSummary
                    if let device = coordinator.selectedDevice, !device.volumes.isEmpty {
                        dataLossWarning(device)
                    }
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 520)
        .frame(minHeight: 320, maxHeight: 620)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.strategy == .eraseOnly
                     ? t(.confirmTitleErase)
                     : t(.confirmTitleWrite))
                    .font(.headline)
                Text(t(.confirmIrreversible))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private func deviceSummary(_ device: StorageDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t(.confirmSectionTarget))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                DetailRow(label: t(.confirmFieldDevice), value: device.displayName)
                DetailRow(label: t(.confirmFieldCapacity), value: ByteCount.format(device.sizeBytes))
                DetailRow(label: t(.confirmFieldConnection), value: device.bus.displayName)
                DetailRow(label: t(.confirmFieldIdentifier), value: device.rawDevicePath)
                if let volumes = device.volumeSummary {
                    DetailRow(label: t(.confirmFieldVolumes), value: volumes)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var operationSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t(.confirmSectionOperation))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                DetailRow(label: t(.confirmFieldMethod), value: coordinator.strategy.displayName)
                if let source = coordinator.source, coordinator.strategy != .eraseOnly {
                    DetailRow(label: t(.confirmFieldSource), value: source.url.lastPathComponent)
                    DetailRow(label: t(.confirmFieldSize), value: ByteCount.format(source.sizeBytes))
                }
                if coordinator.strategy == .eraseOnly, coordinator.source != nil {
                    // Letzte Gelegenheit, den Widerspruch zu bemerken.
                    DetailRow(
                        label: t(.confirmFieldSource),
                        value: t(.confirmSourceUnused)
                    )
                }
                if coordinator.strategy == .eraseOnly {
                    DetailRow(label: t(.confirmFieldFilesystem), value: coordinator.eraseFilesystem.rawValue)
                    DetailRow(label: t(.confirmFieldScheme), value: coordinator.erasePartitionScheme.rawValue)
                }
                if coordinator.strategy != .rawImage {
                    DetailRow(
                        label: t(.confirmFieldName),
                        value: VolumeLabel.sanitise(
                            coordinator.volumeLabel,
                            filesystem: coordinator.strategy == .eraseOnly
                                ? coordinator.eraseFilesystem
                                : .fat32
                        )
                    )
                }
                if let answerFile = coordinator.answerFile, coordinator.acceptsAnswerFile {
                    DetailRow(
                        label: t(.confirmFieldAnswerFile),
                        value: answerFile.displaySummary
                    )
                }
                DetailRow(
                    label: t(.confirmFieldVerification),
                    value: coordinator.verifyAfterWrite && coordinator.strategy == .rawImage
                        ? t(.confirmVerificationByteForByte)
                        : t(.confirmVerificationNotApplicable)
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func dataLossWarning(_ device: StorageDevice) -> some View {
        CalloutView(
            kind: .error,
            text: t(.confirmDataLoss),
            detail: device.volumes
                .compactMap { volume in
                    guard let name = volume.name else { return nil }
                    return "\(name) (\(ByteCount.format(volume.sizeBytes)))"
                }
                .joined(separator: ", ")
        )
    }

    private var footer: some View {
        HStack {
            Button(t(.actionCancel)) { isPresented = false }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button(coordinator.strategy == .eraseOnly ? t(.actionErase) : t(.actionWrite), role: .destructive) {
                isPresented = false
                coordinator.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(20)
    }
}
