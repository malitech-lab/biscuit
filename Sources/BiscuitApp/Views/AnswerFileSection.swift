import BiscuitKit
import SwiftUI
import UniformTypeIdentifiers

/// Optional Windows Setup answer file.
///
/// Only rendered when a Windows installer is the selected source. Offering it
/// for a raw image write would promise something the medium cannot deliver —
/// a byte-for-byte copy has nowhere to put an extra file.
struct AnswerFileSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isTargeted = false
    @State private var showImporter = false
    @State private var showTemplate = false

    private var coordinator: JobCoordinator { env.coordinator }

    var body: some View {
        if coordinator.acceptsAnswerFile {
            SectionCard(
                title: t(.answerFileSectionTitle),
                systemImage: "doc.text.magnifyingglass",
                subtitle: t(.answerFileSectionSubtitle)
            ) {
                if let answerFile = coordinator.answerFile {
                    summary(for: answerFile)
                } else {
                    dropZone
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.xml],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                coordinator.selectAnswerFile(url)
            }
            .sheet(isPresented: $showTemplate) {
                AnswerTemplateSheet(isPresented: $showTemplate)
            }
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(t(.answerFileDropHere))
                .font(.callout)
            HStack(spacing: 8) {
                Button(t(.answerFileChoose)) { showImporter = true }
                    .buttonStyle(.link)
                Text("·").foregroundStyle(.tertiary)
                // For everyone who does not already own an autounattend.xml,
                // which is almost everyone.
                Button(t(.answerTemplateOpen)) { showTemplate = true }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in coordinator.selectAnswerFile(url) }
            }
            return true
        }
        .accessibilityLabel(t(.answerFileAccessibility))
    }

    /// Size, prefixed by the origin when Biscuit built the file.
    static func provenanceLine(_ answerFile: AnswerFile, wasGenerated: Bool) -> String {
        let size = ByteCount.format(UInt64(answerFile.sizeBytes))
        return wasGenerated ? "\(t(.answerTemplateGenerated)) · \(size)" : size
    }

    // MARK: - Summary

    @ViewBuilder
    private func summary(for answerFile: AnswerFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: answerFile.isUsable
                      ? "doc.text.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(answerFile.isUsable ? Color.accentColor : .red)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(answerFile.originalFileName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    // Says where the file came from. A generated one carries
                    // choices the user made in Biscuit and can be rebuilt; a
                    // dropped one is theirs and must not be confused with it.
                    Text(Self.provenanceLine(
                        answerFile,
                        wasGenerated: coordinator.answerTemplate != nil
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    coordinator.clearAnswerFile()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(t(.answerFileRemove))
            }

            ForEach(Array(answerFile.findings.enumerated()), id: \.offset) { _, finding in
                if let text = Self.describe(finding) {
                    CalloutView(kind: Self.calloutKind(for: finding), text: text)
                }
            }

            // Spelled out separately from the per-finding notes: the
            // consequence matters more than the fact.
            if answerFile.containsSecrets {
                CalloutView(
                    kind: .warning,
                    text: t(.answerFileSecretsWarning),
                    detail: t(.answerFileSecretsDetail)
                )
            }
        }
    }

    private static func calloutKind(for finding: AnswerFile.Finding) -> CalloutView.Kind {
        switch finding.severity {
        case .blocking: return .error
        case .warning: return .warning
        case .info: return .info
        }
    }

    /// Returns nil for findings that are covered by the dedicated secrets
    /// callout, so the same thing is not said twice.
    private static func describe(_ finding: AnswerFile.Finding) -> String? {
        switch finding.kind {
        case .notXML:
            return t(.answerFileFindingNotXML)
        case .wrongRootElement:
            return t(.answerFileFindingWrongRoot, finding.detail ?? "?")
        case .missingNamespace:
            return t(.answerFileFindingMissingNamespace)
        case .tooLarge:
            return t(.answerFileFindingTooLarge, finding.detail ?? "?")
        case .empty:
            return t(.answerFileFindingEmpty)
        case .renamed:
            return t(.answerFileWillBeRenamed)
        case .containsPassword, .containsProductKey, .containsDomainCredentials:
            return nil
        }
    }
}
