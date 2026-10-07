import BiscuitKit
import SwiftUI

/// Step 3: method and options.
///
/// The strategy picker only offers what the inspected source actually supports.
/// Letting the user pick a method that cannot boot — writing a Windows ISO raw,
/// for instance — would produce a stick that fails silently at the firmware
/// stage, which is the single most common failure in tools of this kind.
struct OptionsSection: View {
    @Environment(AppEnvironment.self) private var env

    private var coordinator: JobCoordinator { env.coordinator }

    var body: some View {
        SectionCard(title: t(.optionsSectionTitle), systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                strategyPicker

                if let explanation = currentExplanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                labelField

                if coordinator.strategy == .eraseOnly {
                    eraseOptions
                }

                toggles
            }
        }
    }

    // MARK: - Pieces

    private var strategyPicker: some View {
        Picker(t(.optionsMethod), selection: Binding(
            get: { coordinator.strategy },
            set: { coordinator.strategy = $0 }
        )) {
            ForEach(coordinator.availableStrategies, id: \.self) { strategy in
                Text(strategy.displayName).tag(strategy)
            }
        }
        .pickerStyle(.radioGroup)
        .disabled(coordinator.isRunning)
    }

    private var currentExplanation: String? {
        coordinator.availableStrategies.contains(coordinator.strategy)
            ? coordinator.strategy.explanation
            : nil
    }

    private var labelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t(.optionsVolumeName))
                    .font(.callout)
                    .frame(width: 140, alignment: .leading)
                TextField(
                    "BISCUIT",
                    text: Binding(
                        get: { coordinator.volumeLabel },
                        set: { coordinator.volumeLabel = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(coordinator.isRunning || coordinator.strategy == .rawImage)
            }

            if coordinator.strategy == .rawImage {
                Text(t(.optionsVolumeNameRawHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if effectiveLabel != coordinator.volumeLabel {
                Text(t(.optionsVolumeNameAdjusted, effectiveLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Mirrors the sanitisation the helper applies, so the user sees the real
    /// result before committing rather than being surprised afterwards.
    private var effectiveLabel: String {
        let filesystem: TargetFilesystem = coordinator.strategy == .eraseOnly
            ? coordinator.eraseFilesystem
            : .fat32
        return VolumeLabel.sanitise(coordinator.volumeLabel, filesystem: filesystem)
    }

    private var eraseOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t(.optionsFilesystem))
                    .font(.callout)
                    .frame(width: 140, alignment: .leading)
                Picker("", selection: Binding(
                    get: { coordinator.eraseFilesystem },
                    set: { coordinator.eraseFilesystem = $0 }
                )) {
                    ForEach(TargetFilesystem.allCases, id: \.self) { filesystem in
                        Text(filesystem.displayName).tag(filesystem)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Text(t(.optionsPartitionScheme))
                    .font(.callout)
                    .frame(width: 140, alignment: .leading)
                Picker("", selection: Binding(
                    get: { coordinator.erasePartitionScheme },
                    set: { coordinator.erasePartitionScheme = $0 }
                )) {
                    ForEach(PartitionScheme.allCases, id: \.self) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                }
                .labelsHidden()
            }
        }
        .disabled(coordinator.isRunning)
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { coordinator.verifyAfterWrite },
                set: { coordinator.verifyAfterWrite = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t(.optionsVerify))
                    Text(verifyExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(coordinator.isRunning || coordinator.strategy == .eraseOnly)

            Toggle(isOn: Binding(
                get: { coordinator.ejectWhenDone },
                set: { coordinator.ejectWhenDone = $0 }
            )) {
                Text(t(.optionsEject))
            }
            .disabled(coordinator.isRunning)
        }
    }

    private var verifyExplanation: String {
        switch coordinator.strategy {
        case .rawImage:
            return t(.optionsVerifyRawHint)
        case .windowsFAT32:
            return t(.optionsVerifyFileCopyHint)
        case .macOSInstaller:
            return t(.optionsVerifyInstallerHint)
        case .eraseOnly:
            return t(.optionsVerifyEraseHint)
        }
    }
}
