import BiscuitKit
import SwiftUI
import UniformTypeIdentifiers

/// Step 1: choose and inspect the source image.
struct SourceSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isTargeted = false
    @State private var showImporter = false
    @State private var showCatalogue = false

    private var coordinator: JobCoordinator { env.coordinator }

    var body: some View {
        SectionCard(
            title: t(.sourceSectionTitle),
            systemImage: "doc.badge.gearshape",
            subtitle: t(.sourceSectionSubtitle)
        ) {
            if coordinator.state == .inspectingSource {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(t(.sourceAnalysing))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if let source = coordinator.source {
                summary(for: source)
            } else {
                dropZone
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await coordinator.selectSource(url) }
        }
        // Without this the "open catalogue" link set its state flag and nothing
        // happened: the whole browser was unreachable from the UI.
        .sheet(isPresented: $showCatalogue) {
            CatalogueBrowser(isPresented: $showCatalogue)
                .frame(minWidth: 640, minHeight: 520)
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)

            Text(t(.sourceDropHere))
                .font(.callout)

            HStack(spacing: 14) {
                Button(t(.sourceChooseFile)) { showImporter = true }
                    .buttonStyle(.link)
                Text("·").foregroundStyle(.tertiary)
                Button(t(.catalogueOpen)) { showCatalogue = true }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
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
            handleDrop(providers)
        }
        .accessibilityLabel(t(.sourceDropAccessibility))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in await coordinator.selectSource(url) }
        }
        return true
    }

    // MARK: - Summary

    @ViewBuilder
    private func summary(for source: MediaSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.symbol(for: source.payload))
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("\(source.payload.displayName) · \(ByteCount.format(source.sizeBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    coordinator.clearSource()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(t(.sourceRemove))
            }

            if let origin = coordinator.catalogueOrigin {
                CalloutView(
                    kind: origin.provenance.strength == .publisherSignature ? .success : .info,
                    text: t(.sourceFromCatalogue, origin.provenance.publisher),
                    detail: origin.expandedSHA256 != nil
                        ? t(.sourceDigestWillBeChecked)
                        : nil
                )
            }

            // Raised out of the grey notes list on purpose. An ARM64 image
            // written for an ordinary PC yields a stick that completes without
            // error and then does not boot, and a caption nobody reads is not
            // enough warning for that.
            if let metadata = source.windowsMetadata,
               let architecture = metadata.commonArchitecture,
               !architecture.isCommonPCArchitecture {
                CalloutView(
                    kind: .warning,
                    text: t(.noteWindowsArchitectureUnusual, architecture.displayName),
                    detail: metadata.commonVersion.map {
                        t(.noteWindowsVersion, $0.productGeneration ?? "", $0.displayName)
                    }
                )
            }

            // Likewise: one piece of a split set cannot be installed from.
            if let metadata = source.windowsMetadata, metadata.isSplit {
                CalloutView(
                    kind: .warning,
                    text: t(.noteWindowsSplitSet, metadata.partNumber, metadata.totalParts)
                )
            }

            if source.supportedStrategies.isEmpty {
                CalloutView(
                    kind: .error,
                    text: t(.sourceNotBootable),
                    detail: source.detectionNotes.joined(separator: " ")
                )
            } else if !source.detectionNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(source.detectionNotes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if source.payload == .windowsInstaller,
               let largest = source.largestInnerFileBytes,
               largest > 4 * 1024 * 1024 * 1024 - 1,
               !BundledTools.isWimlibAvailable {
                CalloutView(
                    kind: .error,
                    text: t(.sourceWimlibMissing),
                    detail: t(.sourceWimlibMissingDetail, ByteCount.format(largest))
                )
            }
        }
    }

    private static func symbol(for payload: ImagePayload) -> String {
        switch payload {
        case .windowsInstaller: return "window.horizontal.closed"
        case .macOSInstallerApp: return "applelogo"
        case .hybridISO: return "opticaldisc"
        case .rawDiskImage: return "internaldrive"
        case .nonBootableISO: return "exclamationmark.triangle"
        }
    }

    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.diskImage, .application, .folder]
        if let iso = UTType(filenameExtension: "iso") { types.append(iso) }
        if let img = UTType(filenameExtension: "img") { types.append(img) }
        if let dmg = UTType(filenameExtension: "dmg") { types.append(dmg) }
        return types
    }
}
