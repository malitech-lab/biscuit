import BiscuitKit
import AppKit
import SwiftUI

/// Browse the signed image catalogue and download an entry.
struct CatalogueBrowser: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var isPresented: Bool
    @State private var selection: CatalogueImage?
    @State private var tab: Tab = .images
    @State private var macOSSelection: MacOSInstaller?
    @State private var windowsSelection: WindowsDownloadPage?

    private enum Tab: Hashable { case images, macOS, windows }

    private var service: CatalogueService { env.catalogue }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text(t(.catalogueTabImages)).tag(Tab.images)
                Text(t(.catalogueTabMacOS)).tag(Tab.macOS)
                Text(t(.catalogueTabWindows)).tag(Tab.windows)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            // Apple's installers come from a different place and carry a
            // different guarantee, so they get their own tab rather than being
            // mixed into a list whose entries all claim a pinned checksum.
            switch tab {
            case .images: content
            case .macOS: macOSContent
            case .windows: windowsContent
            }
            Divider()
            switch tab {
            case .images: footer
            case .macOS: macOSFooter
            case .windows: windowsFooter
            }
        }
        .frame(width: 620, height: 520)
        .task {
            if service.catalogueState.catalogue == nil {
                await service.loadCatalogue()
            }
        }
        .task(id: tab) {
            if tab == .macOS, service.macOSInstallers.isEmpty {
                await service.loadMacOSInstallers()
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(t(.catalogueTitle)).font(.headline)
                Text(t(.catalogueSubtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await service.loadCatalogue(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(t(.catalogueRefresh))
            .disabled(service.catalogueState == .loading)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch service.catalogueState {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(t(.catalogueLoading)).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let error):
            VStack(spacing: 14) {
                CalloutView(kind: .error, text: error.message, detail: error.remedy)
                Button(t(.catalogueRetry)) {
                    Task { await service.loadCatalogue(forceRefresh: true) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .ready(let catalogue, let origin):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    originNotice(origin)
                    ForEach(Array(catalogue.entries.enumerated()), id: \.offset) { _, node in
                        CatalogueNodeView(node: node, depth: 0, selection: $selection)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func originNotice(_ origin: CatalogueService.CatalogueState.Origin) -> some View {
        switch origin {
        case .network:
            EmptyView()
        case .cache(let date, let stale):
            // Only worth saying when the copy is a fallback. A cache entry
            // inside its refresh window is the normal case, not news.
            if stale {
                CalloutView(
                    kind: .warning,
                    text: t(.catalogueOffline),
                    detail: t(
                        .catalogueOfflineDetail,
                        date.formatted(date: .abbreviated, time: .shortened)
                    )
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch service.downloadState {
            case .downloading(let image, let progress):
                downloadProgress(image: image, progress: progress)
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t(.catalogueVerifying)).font(.callout)
                }
            case .failed(_, let error):
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            case .finished, .idle:
                if let selection {
                    Text(selection.name).font(.callout).lineLimit(1)
                } else {
                    Text(t(.catalogueSelectPrompt))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if service.downloadState.isBusy {
                Button(t(.actionCancel)) { service.cancelDownload() }
            } else {
                Button(t(.actionCancel)) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(t(.catalogueDownload)) {
                    guard let selection else { return }
                    env.coordinator.useCatalogueImage(selection, service: service)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(16)
    }

    private func downloadProgress(
        image: CatalogueImage,
        progress: ImageDownloader.ProgressSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(image.name).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Text(
                    progress.bytesExpected.map {
                        "\(ByteCount.format(progress.bytesReceived)) / \(ByteCount.format($0))"
                    } ?? ByteCount.format(progress.bytesReceived)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            HStack(spacing: 8) {
                if let rate = progress.bytesPerSecond {
                    Text(ByteCount.formatRate(bytesPerSecond: rate))
                }
                if let remaining = progress.secondsRemaining, remaining > 0 {
                    Text("· \(ByteCount.formatDuration(remaining))")
                }
                // Mentioned so a download that begins at 60 % does not look
                // like a display fault.
                if progress.resumedFrom > 0 {
                    Text("· \(t(.catalogueResumed, ByteCount.format(progress.resumedFrom)))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// Renders one node and, for a category, its children.
///
/// A concrete `View` type rather than a `@ViewBuilder` function because the
/// structure is genuinely recursive: a function returning `some View` that
/// calls itself defines its opaque type in terms of itself, which the compiler
/// rejects. The Raspberry Pi catalogue nests five levels deep, so flattening
/// this to a fixed depth is not an option either.
private struct CatalogueNodeView: View {
    let node: CatalogueNode
    let depth: Int
    @Binding var selection: CatalogueImage?

    var body: some View {
        switch node {
        case .category(let category):
            VStack(alignment: .leading, spacing: 6) {
                Text(category.name)
                    .font(depth == 0 ? .headline : .subheadline.weight(.medium))
                if let summary = category.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ForEach(Array(category.children.enumerated()), id: \.offset) { _, child in
                        CatalogueNodeView(node: child, depth: depth + 1, selection: $selection)
                    }
                }
                .padding(.leading, depth == 0 ? 0 : 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .image(let image):
            CatalogueRow(
                image: image,
                isSelected: selection?.id == image.id,
                onSelect: { selection = image }
            )
        }
    }
}

// MARK: - macOS installers

private struct MacOSInstallerRow: View {
    let installer: MacOSInstaller
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Image(systemName: "applelogo")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(installer.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(ByteCount.format(installer.sizeBytes))
                        Text("·")
                        Text(installer.build)
                        if installer.isDeferred {
                            Text("·")
                            Text(t(.catalogueMacOSDeferred)).foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct CatalogueRow: View {
    let image: CatalogueImage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(image.name).font(.callout.weight(.medium)).lineLimit(1)
                        if let version = image.version {
                            Text(version).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(image.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)

                    HStack(spacing: 8) {
                        if let size = image.downloadSizeBytes {
                            Label(ByteCount.format(size), systemImage: "arrow.down.circle")
                        }
                        if case .exact(let expanded) = image.expectedExpandedSize,
                           image.compression.isCompressed {
                            Label(ByteCount.format(expanded), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        provenanceBadge
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Says how much the checksum is actually worth.
    ///
    /// "Verified" means something different when a publisher's GPG signature
    /// was checked than when a number was read off a web page over TLS, and
    /// flattening the two into one green tick would be a small lie told often.
    @ViewBuilder
    private var provenanceBadge: some View {
        switch image.provenance.strength {
        case .publisherSignature:
            Label(t(.catalogueProvenanceSignature), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .publisherChecksum:
            Label(t(.catalogueProvenanceChecksum), systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
        case .none:
            Label(t(.catalogueProvenanceNone), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - macOS tab

extension CatalogueBrowser {
    @ViewBuilder
    var macOSContent: some View {
        switch service.macOSState {
        case .listing:
            VStack(spacing: 10) {
                ProgressView()
                Text(t(.catalogueMacOSLoading)).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let error):
            VStack(spacing: 14) {
                CalloutView(kind: .error, text: error.message, detail: error.remedy)
                Button(t(.catalogueRetry)) {
                    Task { await service.loadMacOSInstallers() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .idle, .ready, .fetching:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Says plainly where the trust comes from here, because it
                    // is a different answer from the one on the other tab.
                    CalloutView(kind: .info, text: t(.catalogueMacOSTrust))

                    ForEach(service.macOSInstallers) { installer in
                        MacOSInstallerRow(
                            installer: installer,
                            isSelected: macOSSelection?.id == installer.id,
                            onSelect: { macOSSelection = installer }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    var macOSFooter: some View {
        HStack(spacing: 12) {
            if case .fetching(let installer, let fraction, let detail) = service.macOSState {
                VStack(alignment: .leading, spacing: 3) {
                    Text(installer.displayName).font(.caption.weight(.medium))
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(detail.isEmpty ? t(.catalogueMacOSFetching) : detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 380, alignment: .leading)
            } else if let macOSSelection {
                VStack(alignment: .leading, spacing: 1) {
                    Text(macOSSelection.displayName).font(.callout).lineLimit(1)
                    Text(t(.catalogueMacOSSizeHint, ByteCount.format(macOSSelection.sizeBytes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(t(.catalogueSelectPrompt)).font(.callout).foregroundStyle(.secondary)
            }

            Spacer()

            if service.macOSState.isBusy {
                Button(t(.actionCancel)) { service.cancelMacOSFetch() }
            } else {
                Button(t(.actionCancel)) { isPresented = false }
                Button(t(.catalogueDownload)) {
                    guard let installer = macOSSelection else { return }
                    env.coordinator.useMacOSInstaller(installer, service: service)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(macOSSelection == nil)
            }
        }
        .padding(16)
    }
}

// MARK: - Windows tab

/// A hand-off rather than a download, and the UI says why.
///
/// Microsoft gates the final step of its download API behind device
/// fingerprinting, so there is no honest way to automate this. Claiming
/// otherwise with a download button that breaks on Microsoft's schedule would
/// be worse than one extra click.
extension CatalogueBrowser {
    @ViewBuilder
    var windowsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CalloutView(kind: .info, text: t(.windowsWhyNoDownload))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(WindowsDownloadGuide.instructions.enumerated()), id: \.offset) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(item.offset + 1).")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .trailing)
                            Text(t(item.element)).font(.callout)
                        }
                    }
                }
                .padding(.horizontal, 2)

                Divider()

                ForEach(WindowsDownloadGuide.pages) { page in
                    WindowsPageRow(
                        page: page,
                        isSelected: windowsSelection?.id == page.id,
                        onSelect: { windowsSelection = page }
                    )
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    var windowsFooter: some View {
        HStack(spacing: 12) {
            if let page = windowsSelection {
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.displayName).font(.callout).lineLimit(1)
                    Text(t(.windowsPageHint)).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(t(.catalogueSelectPrompt)).font(.callout).foregroundStyle(.secondary)
            }

            Spacer()

            Button(t(.actionCancel)) { isPresented = false }
            Button(t(.windowsOpenPage)) {
                guard let page = windowsSelection else { return }
                // Opened in the language Biscuit is running in, so the user does
                // not land on a page in a language they did not choose.
                NSWorkspace.shared.open(page.url(locale: L10n.resolvedLanguage))
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(windowsSelection == nil)
        }
        .padding(16)
    }
}

private struct WindowsPageRow: View {
    let page: WindowsDownloadPage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Image(systemName: "window.horizontal.closed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.displayName).font(.callout.weight(.medium))
                    Text(t(page.audience))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
