import BiscuitKit
import SwiftUI

/// Builds an `autounattend.xml` from a short list of choices.
///
/// The options are deliberately few. The point is not to expose the unattend
/// schema — that is what dropping your own file is for — but to cover the
/// handful of things people actually come looking for, and to be honest about
/// what each one costs.
struct AnswerTemplateSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var isPresented: Bool

    @State private var bypassHardware = false
    @State private var bypassAccount = false
    @State private var skipPages = false
    @State private var declineTelemetry = false
    @State private var accountName = ""
    @State private var accountPassword = ""

    /// Taken from the inspected image, not asked for: Setup matches
    /// `processorArchitecture` strictly and ignores a mismatched file silently.
    private var architecture: WindowsArchitecture {
        env.coordinator.source?.windowsMetadata?.commonArchitecture ?? .x64
    }

    private var template: AnswerFileTemplate {
        AnswerFileTemplate(
            architecture: architecture,
            bypassHardwareChecks: bypassHardware,
            bypassMicrosoftAccount: bypassAccount,
            skipSetupPages: skipPages,
            declineTelemetry: declineTelemetry,
            localAccount: accountName.isEmpty
                ? nil
                : .init(
                    name: accountName,
                    password: accountPassword.isEmpty ? nil : accountPassword
                ),
            // Follows the app's language, which is the one choice the user has
            // already made explicitly.
            locale: Self.setupLocale(for: L10n.resolvedLanguage)
        )
    }

    static func setupLocale(for language: String) -> String? {
        switch language.lowercased().prefix(2) {
        case "de": return "de-DE"
        case "en": return "en-US"
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t(.answerTemplateTitle)).font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(t(.answerTemplateIntro))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $bypassHardware) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t(.answerTemplateBypassHardware))
                            Text(t(.answerTemplateBypassHardwareDetail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Shown only once the option is on, so the consequence
                    // appears next to the decision rather than as background
                    // noise above it.
                    if bypassHardware {
                        CalloutView(kind: .warning, text: t(.answerTemplateBypassConsequence))
                    }

                    Toggle(isOn: $bypassAccount) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t(.answerTemplateBypassAccount))
                            Text(t(.answerTemplateBypassAccountDetail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(t(.answerTemplateSkipPages), isOn: $skipPages)
                    Toggle(t(.answerTemplateDeclineTelemetry), isOn: $declineTelemetry)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        TextField(t(.answerTemplateAccountName), text: $accountName)
                        SecureField(t(.answerTemplateAccountPassword), text: $accountPassword)
                        if !accountPassword.isEmpty {
                            CalloutView(
                                kind: .warning, text: t(.answerTemplatePasswordWarning)
                            )
                        }
                    }

                    Text(t(.answerTemplateArchitecture, architecture.displayName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button(t(.actionCancel)) { isPresented = false }
                Button(t(.answerTemplateGenerate)) {
                    env.coordinator.applyAnswerTemplate(template)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                // Nothing selected would produce a file that changes nothing.
                .disabled(template.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 460, minHeight: 440)
    }
}
