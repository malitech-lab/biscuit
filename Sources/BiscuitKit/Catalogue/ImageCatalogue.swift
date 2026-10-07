import Foundation

/// A catalogue of downloadable operating system images.
///
/// Modelled on the schema Raspberry Pi Imager uses — recursive categories,
/// `extract_size` for the capacity check, a checksum of the *decompressed*
/// image — because that format is well thought through and explicitly designed
/// to be hosted by third parties (`rpi-imager --repo <url>`). Biscuit hosts its
/// own catalogue rather than fetching theirs: their `robots.txt` is
/// `Disallow: /` and their terms forbid scraping, so consuming their file from
/// another product would be taking a liberty nobody granted.
///
/// ## Where trust comes from
///
/// The obvious design — have the app fetch each publisher's `SHA256SUMS.gpg`
/// and verify it — founders on a practical detail: macOS ships no GnuPG, and
/// the five distributions worth supporting use four different signature
/// layouts (detached binary, `.sign`, clearsigned inline, and Arch signing the
/// ISO itself rather than the checksum file). Implementing OpenPGP in the app
/// to serve that is a large amount of security-critical code for a problem that
/// can be moved.
///
/// So it is moved. The release pipeline fetches each publisher's checksums,
/// verifies the GPG signature against a pinned fingerprint — on a machine where
/// `gpg` exists and the four layouts can be handled with four short shell
/// snippets — and writes the resulting SHA-256 into this catalogue. The
/// catalogue is then signed with the project's Ed25519 key, the same key that
/// signs releases.
///
/// The app therefore has exactly **one** verification path: Ed25519 over the
/// catalogue, then SHA-256 over what it downloaded. The chain is
/// publisher GPG → CI → Ed25519 → app, and every link is checked by something
/// that can actually check it.
public struct ImageCatalogue: Codable, Sendable, Equatable {
    /// Bumped on an incompatible change. An app that does not understand the
    /// version refuses the catalogue rather than guessing at its meaning.
    public static let supportedFormatVersion = 1

    public let formatVersion: Int
    public let generatedAt: Date
    /// How long the client may use this copy before refreshing. Advisory.
    public let refreshIntervalHours: Int
    public let entries: [CatalogueNode]

    public init(
        formatVersion: Int = ImageCatalogue.supportedFormatVersion,
        generatedAt: Date,
        refreshIntervalHours: Int = 24,
        entries: [CatalogueNode]
    ) {
        self.formatVersion = formatVersion
        self.generatedAt = generatedAt
        self.refreshIntervalHours = refreshIntervalHours
        self.entries = entries
    }

    /// Every image in the tree, flattened.
    public var allImages: [CatalogueImage] {
        entries.flatMap(\.allImages)
    }

    public func image(id: String) -> CatalogueImage? {
        allImages.first { $0.id == id }
    }
}

/// Either a grouping or an image. Nesting is arbitrary — the Raspberry Pi
/// catalogue reaches five levels — so this is genuinely recursive rather than
/// a two-level list.
public indirect enum CatalogueNode: Codable, Sendable, Equatable {
    case category(CatalogueCategory)
    case image(CatalogueImage)

    public var allImages: [CatalogueImage] {
        switch self {
        case .image(let image): return [image]
        case .category(let category): return category.children.flatMap(\.allImages)
        }
    }

    public var displayName: String {
        switch self {
        case .image(let image): return image.name
        case .category(let category): return category.name
        }
    }

    // Encoded with an explicit discriminator so a hand-edited catalogue is
    // readable and a decoding failure names the offending node.
    private enum CodingKeys: String, CodingKey { case kind, category, image }
    private enum Kind: String, Codable { case category, image }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .category:
            self = .category(try container.decode(CatalogueCategory.self, forKey: .category))
        case .image:
            self = .image(try container.decode(CatalogueImage.self, forKey: .image))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .category(let value):
            try container.encode(Kind.category, forKey: .kind)
            try container.encode(value, forKey: .category)
        case .image(let value):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(value, forKey: .image)
        }
    }
}

public struct CatalogueCategory: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let summary: String?
    public let children: [CatalogueNode]

    public init(name: String, summary: String? = nil, children: [CatalogueNode]) {
        self.name = name
        self.summary = summary
        self.children = children
    }
}

/// One downloadable image.
public struct CatalogueImage: Codable, Sendable, Equatable, Identifiable {
    /// Stable across catalogue regenerations, so a cached download can be
    /// matched to its entry. Something like `debian.stable.netinst.amd64`.
    public let id: String
    public let name: String
    public let summary: String
    public let version: String?
    public let releaseDate: Date?
    public let url: URL

    /// Bytes to download. Used for the progress bar and to reject a mirror that
    /// hands back something unexpected.
    public let downloadSizeBytes: UInt64?

    /// SHA-256 of the file as downloaded.
    ///
    /// Checked first because it can be: it fails fast on a truncated or
    /// substituted download, before anything is decompressed.
    public let downloadSHA256: String?

    /// Size after decompression. Drives the capacity check, so it is the figure
    /// that decides whether a disk is accepted.
    public let expandedSizeBytes: UInt64?

    /// SHA-256 of the decompressed image, when the publisher provides one.
    ///
    /// The stronger check, because it covers what actually reaches the disk.
    public let expandedSHA256: String?

    public let compression: CompressionFormat
    /// Where the checksums came from and how they were established.
    public let provenance: Provenance
    /// Non-fatal things the user should know, already localised at build time.
    public let notes: [String]

    public init(
        id: String,
        name: String,
        summary: String,
        version: String? = nil,
        releaseDate: Date? = nil,
        url: URL,
        downloadSizeBytes: UInt64? = nil,
        downloadSHA256: String? = nil,
        expandedSizeBytes: UInt64? = nil,
        expandedSHA256: String? = nil,
        compression: CompressionFormat = .none,
        provenance: Provenance,
        notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.releaseDate = releaseDate
        self.url = url
        self.downloadSizeBytes = downloadSizeBytes
        self.downloadSHA256 = downloadSHA256
        self.expandedSizeBytes = expandedSizeBytes
        self.expandedSHA256 = expandedSHA256
        self.compression = compression
        self.provenance = provenance
        self.notes = notes
    }

    /// How the checksums in this entry were obtained.
    ///
    /// Recorded rather than assumed, so the UI can be honest about how much the
    /// user is trusting and whom. "Verified" means something different when a
    /// GPG signature was checked than when a checksum was simply read off a web
    /// page over TLS.
    public struct Provenance: Codable, Sendable, Equatable {
        public enum Strength: String, Codable, Sendable {
            /// The publisher's checksum file carried a GPG signature that the
            /// release pipeline verified against a pinned fingerprint.
            case publisherSignature = "publisher_signature"
            /// Checksum taken from a publisher API or file over TLS, with no
            /// signature to check.
            case publisherChecksum = "publisher_checksum"
            /// No checksum from the publisher at all.
            case none
        }

        public let strength: Strength
        /// Who published the image, for display.
        public let publisher: String
        /// Where the checksum came from, for the diagnostics pane.
        public let checksumSource: String?
        /// Fingerprint the signature was verified against, if any.
        public let signingKeyFingerprint: String?
        /// When the pipeline last confirmed this.
        public let verifiedAt: Date?

        public init(
            strength: Strength,
            publisher: String,
            checksumSource: String? = nil,
            signingKeyFingerprint: String? = nil,
            verifiedAt: Date? = nil
        ) {
            self.strength = strength
            self.publisher = publisher
            self.checksumSource = checksumSource
            self.signingKeyFingerprint = signingKeyFingerprint
            self.verifiedAt = verifiedAt
        }
    }

    /// Best available expectation of the decompressed size.
    public var expectedExpandedSize: ExpandedSize {
        if let expandedSizeBytes { return .exact(expandedSizeBytes) }
        if compression == .none, let downloadSizeBytes { return .exact(downloadSizeBytes) }
        return .unknown
    }

    /// True when the download can be checked against something.
    public var isVerifiable: Bool {
        downloadSHA256 != nil || expandedSHA256 != nil
    }
}

// MARK: - Validation

public extension ImageCatalogue {
    /// Rejects a catalogue that is structurally wrong before any of it is shown.
    ///
    /// A malformed entry that reaches the UI becomes a download with no
    /// checksum, which is precisely what the catalogue exists to avoid.
    func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorCatalogueVersionUnsupported),
                remedy: t(.errorCatalogueVersionUnsupportedRemedy),
                diagnostics: "catalogue format \(formatVersion), supported \(Self.supportedFormatVersion)"
            )
        }

        let images = allImages
        guard !images.isEmpty else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorCatalogueEmpty)
            )
        }

        var seen = Set<String>()
        for image in images {
            guard seen.insert(image.id).inserted else {
                throw BiscuitError(
                    kind: .updateFailed,
                    message: t(.errorCatalogueInvalid),
                    diagnostics: "duplicate image id: \(image.id)"
                )
            }
            // Downloads must be over TLS: the checksum protects the content,
            // but a plaintext URL leaks what the user is installing and invites
            // a redirect to a mirror that is merely slow and wrong.
            guard image.url.scheme == "https" else {
                throw BiscuitError(
                    kind: .updateFailed,
                    message: t(.errorCatalogueInvalid),
                    diagnostics: "non-https url for \(image.id): \(image.url.scheme ?? "?")"
                )
            }
            for digest in [image.downloadSHA256, image.expandedSHA256].compacted() {
                guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
                    throw BiscuitError(
                        kind: .updateFailed,
                        message: t(.errorCatalogueInvalid),
                        diagnostics: "malformed sha256 for \(image.id)"
                    )
                }
            }
        }
    }
}

private extension Sequence {
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? {
        compactMap { $0 }
    }
}
