import BiscuitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(t(.settingsTabGeneral), systemImage: "gearshape") }
            UpdateSettings()
                .tabItem { Label(t(.settingsTabUpdates), systemImage: "arrow.triangle.2.circlepath") }
            DiagnosticsSettings()
                .tabItem { Label(t(.settingsTabDiagnostics), systemImage: "stethoscope") }
        }
        .frame(width: 500, height: 360)
    }
}

private struct GeneralSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                Picker(t(.settingsLanguage), selection: Binding(
                    get: { env.language.selection },
                    set: { env.language.selection = $0 }
                )) {
                    Text(t(.settingsLanguageSystem)).tag(LanguagePreference.system)
                    ForEach(L10n.availableLanguages, id: \.self) { code in
                        Text(LanguagePreference.displayName(for: code))
                            .tag(LanguagePreference.explicit(code))
                    }
                }
            } footer: {
                Text(t(.settingsLanguageHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(t(.optionsVerify), isOn: Binding(
                    get: { env.coordinator.verifyAfterWrite },
                    set: { env.coordinator.verifyAfterWrite = $0 }
                ))
                Toggle(t(.optionsEject), isOn: Binding(
                    get: { env.coordinator.ejectWhenDone },
                    set: { env.coordinator.ejectWhenDone = $0 }
                ))
            } footer: {
                Text(t(.settingsVerifyFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @Environment(AppEnvironment.self) private var env

    private var updater: UpdateService { env.updater }

    var body: some View {
        Form {
            Section {
                Toggle(t(.settingsAutoCheck), isOn: Binding(
                    get: { updater.automaticChecksEnabled },
                    set: { updater.automaticChecksEnabled = $0 }
                ))

                HStack {
                    Text(t(.settingsLastCheck))
                    Spacer()
                    Text(updater.lastCheck.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? t(.settingsNever))
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button(t(.settingsCheckNow)) {
                        Task { await updater.checkForUpdates(userInitiated: true) }
                    }
                    .disabled(updater.isChecking)
                    if updater.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t(.settingsUpdateSource, AppInfo.repository))
                        .font(.caption)
                    if AppInfo.updatePublicKey.isEmpty {
                        Text(t(.settingsNoSigningKey))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(t(.settingsSigningExplained))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticsSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section(t(.settingsEnvironment)) {
                LabeledContent("Biscuit", value: "\(AppInfo.version) (\(AppInfo.build))")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent(t(.settingsArchitecture), value: Self.architecture)
                LabeledContent(
                    t(.settingsHelperConnected),
                    value: env.broker.isConnected ? t(.settingsYes) : t(.settingsNo)
                )
                LabeledContent("wimlib", value: BundledTools.wimlibPath ?? t(.settingsNotFound))
                LabeledContent(
                    t(.catalogueCacheSize, ""),
                    value: ByteCount.format(env.catalogue.cacheSizeBytes)
                )
            }

            Section {
                Button(t(.catalogueClearCache)) {
                    Task { await env.catalogue.clearImageCache() }
                }
                .disabled(env.catalogue.cacheSizeBytes == 0)
            } footer: {
                Text(t(.catalogueCacheFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(t(.settingsCopyDiagnostics)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
            } footer: {
                Text(t(.settingsDiagnosticsFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await env.catalogue.refreshCacheSize() }
    }

    private static var architecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }

    /// Deliberately English and unlocalised: this text is pasted into bug
    /// reports, where a translated field name makes comparison harder.
    private var report: String {
        var lines = [
            "Biscuit \(AppInfo.version) (\(AppInfo.build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "architecture: \(Self.architecture)",
            "language: \(L10n.resolvedLanguage)",
            "helper: \(BundledTools.helperPath.path)",
            "wimlib: \(BundledTools.wimlibPath ?? "not found")",
            "",
            "disks:"
        ]
        for device in env.monitor.devices {
            lines.append(
                "  \(device.bsdName) \(device.displayName) \(ByteCount.format(device.sizeBytes)) "
                + "bus=\(device.bus.rawValue) removable=\(device.isRemovableMedia) "
                + "ejectable=\(device.isEjectable) system=\(device.isSystemDisk) "
                + "eligible=\(device.isEligibleTarget)"
            )
        }
        lines.append("")
        lines.append(env.coordinator.exportableLog())
        return lines.joined(separator: "\n")
    }
}
