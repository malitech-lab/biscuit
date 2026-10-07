import Foundation

/// Processor architecture an image targets.
///
/// Values are Microsoft's `PROCESSOR_ARCHITECTURE_*` constants as they appear in
/// the WIM's `<ARCH>` element.
public enum WindowsArchitecture: Int, Sendable, Hashable, Codable {
    case x86 = 0
    case mips = 1
    case alpha = 2
    case powerPC = 3
    case arm = 5
    case ia64 = 6
    case x64 = 9
    case arm64 = 12

    public var displayName: String {
        switch self {
        case .x86: return "x86"
        case .mips: return "MIPS"
        case .alpha: return "Alpha"
        case .powerPC: return "PowerPC"
        case .arm: return "ARM"
        case .ia64: return "Itanium"
        case .x64: return "x64"
        case .arm64: return "ARM64"
        }
    }

    /// Whether an ordinary PC can boot this.
    ///
    /// The distinction that matters in practice: an ARM64 image written to a
    /// stick for a normal desktop produces a medium that looks finished and
    /// cannot boot.
    public var isCommonPCArchitecture: Bool { self == .x64 || self == .x86 }
}

public struct WindowsVersion: Sendable, Hashable, Codable {
    public let major: Int
    public let minor: Int
    public let build: Int
    public let servicePackBuild: Int?

    public init(major: Int, minor: Int, build: Int, servicePackBuild: Int? = nil) {
        self.major = major
        self.minor = minor
        self.build = build
        self.servicePackBuild = servicePackBuild
    }

    /// `10.0.26100.1`
    public var displayName: String {
        var text = "\(major).\(minor).\(build)"
        if let servicePackBuild { text += ".\(servicePackBuild)" }
        return text
    }

    /// Marketing name, derived from the build number.
    ///
    /// Windows 11 reports itself as major version 10 — the `<MAJOR>` element
    /// says `10` for both Windows 10 and 11 — so the build number is the only
    /// thing that distinguishes them. 22000 is the first Windows 11 build.
    public var productGeneration: String? {
        guard major == 10, minor == 0 else { return nil }
        return build >= 22_000 ? "Windows 11" : "Windows 10"
    }
}

/// Compression a WIM declares in its header.
public enum WIMCompression: String, Sendable, Hashable, Codable {
    /// Not named `none`: on an optional `WIMCompression?`, a bare `.none`
    /// resolves to `Optional.none` rather than to this case, so
    /// `compression == .none` silently asks whether the value is `nil`. That
    /// mistake was made here once already, in a test that then passed for the
    /// wrong reason.
    case uncompressed
    case xpress
    case lzx
    case lzms

    public var displayName: String {
        switch self {
        case .uncompressed: return "none"
        case .xpress: return "XPRESS"
        case .lzx: return "LZX"
        case .lzms: return "LZMS"
        }
    }
}

/// One image inside a WIM. A Windows ISO holds one per edition.
public struct WIMImage: Sendable, Hashable, Codable, Identifiable {
    public var id: Int { index }

    public let index: Int
    /// e.g. "Windows 11 Pro"
    public let name: String
    public let description: String?
    /// e.g. "Professional". Microsoft's internal edition identifier.
    public let editionID: String?
    public let architecture: WindowsArchitecture?
    public let version: WindowsVersion?
    public let languages: [String]
    public let defaultLanguage: String?
    public let totalBytes: UInt64?

    public init(
        index: Int,
        name: String,
        description: String? = nil,
        editionID: String? = nil,
        architecture: WindowsArchitecture? = nil,
        version: WindowsVersion? = nil,
        languages: [String] = [],
        defaultLanguage: String? = nil,
        totalBytes: UInt64? = nil
    ) {
        self.index = index
        self.name = name
        self.description = description
        self.editionID = editionID
        self.architecture = architecture
        self.version = version
        self.languages = languages
        self.defaultLanguage = defaultLanguage
        self.totalBytes = totalBytes
    }
}

/// What a WIM says about itself.
///
/// Read straight out of the file rather than through `wimlib-imagex info`, for
/// two reasons. The metadata lives in an uncompressed XML blob whose offset is
/// in the header, so reading it needs no decompressor — about eighty lines
/// against a process launch. And wimlib is an *optional* dependency here, only
/// required to split an oversized `install.wim`; making inspection depend on it
/// would mean the app could say nothing at all about an ISO on a machine
/// without Homebrew.
///
/// Format confirmed against a real file produced by wimlib 1.14.5: 208-byte
/// header, `rhXmlData` resource descriptor at offset 72, payload UTF-16LE with
/// a byte-order mark.
public struct WIMMetadata: Sendable, Hashable, Codable {
    public let imageCount: Int
    /// Which part of a split set this is. 1/1 for an ordinary WIM.
    public let partNumber: Int
    public let totalParts: Int
    public let images: [WIMImage]
    public let compression: WIMCompression

    /// Whether any blob is stored as a *solid* resource.
    ///
    /// `nil` means the blob table could not be inspected, which is treated as
    /// "assume solid" by ``canBeSplit`` — see there for why.
    public let hasSolidResources: Bool?

    public init(
        imageCount: Int,
        partNumber: Int,
        totalParts: Int,
        images: [WIMImage],
        compression: WIMCompression = .uncompressed,
        hasSolidResources: Bool? = nil
    ) {
        self.imageCount = imageCount
        self.partNumber = partNumber
        self.totalParts = totalParts
        self.images = images
        self.compression = compression
        self.hasSolidResources = hasSolidResources
    }

    /// Whether `wimlib-imagex split` will accept this file.
    ///
    /// Not derivable from the file extension, and not derivable from the header
    /// either — both of which this code tried first. Measured against
    /// wimlib 1.14.5:
    ///
    /// - A solid WIM and a non-solid LZMS WIM carry **identical header flags**
    ///   (`0x00080082`), yet `split` accepts the second and refuses the first
    ///   with "Splitting of WIM containing solid resources is not supported"
    ///   (exit code 68).
    /// - The distinguishing bit is `0x10` on the individual blob-table
    ///   descriptors, not anything in the header.
    ///
    /// So the extension-based guess this replaced — "ends in `.wim`, therefore
    /// splittable" — was wrong for any solid-compressed `install.wim`, as
    /// produced by `dism /compress:recovery` and by UUP-based ISO builders. The
    /// cost of being wrong was a job that failed partway through writing.
    ///
    /// When the answer is unknown the result is `false`, deliberately: a wrong
    /// "cannot split" costs a re-export, while a wrong "can split" costs a
    /// half-written medium.
    public var canBeSplit: Bool {
        hasSolidResources == false
    }

    /// True when the file is one piece of a split set.
    public var isSplit: Bool { totalParts > 1 }

    /// Architecture shared by every image, if they agree.
    public var commonArchitecture: WindowsArchitecture? {
        let found = Set(images.compactMap(\.architecture))
        return found.count == 1 ? found.first : nil
    }

    /// Version shared by every image, if they agree.
    public var commonVersion: WindowsVersion? {
        let found = images.compactMap(\.version)
        guard let first = found.first, found.count == images.count,
              found.allSatisfy({ $0 == first })
        else { return nil }
        return first
    }

    /// Languages offered across all images.
    public var allLanguages: [String] {
        Array(Set(images.flatMap(\.languages))).sorted()
    }
}

// MARK: - Reading

public extension WIMMetadata {
    static let magic = Data("MSWIM\0\0\0".utf8)
    static let headerSize = 208
    /// Offset of the `rhXmlData` resource descriptor within the header.
    static let xmlResourceOffset = 72

    /// Upper bound on the XML blob.
    ///
    /// The size field in the resource descriptor is 56 bits wide, so a corrupt
    /// or hostile file can claim a preposterous length. Without a cap this
    /// would be an allocation of up to 64 PiB driven by untrusted bytes.
    /// Microsoft's install.wim metadata runs to a few tens of kilobytes; 16 MiB
    /// is generous and still bounded.
    static let maximumXMLBytes = 16 * 1024 * 1024

    /// Reads the metadata, or returns `nil` when the file is not a WIM.
    ///
    /// Returns `nil` rather than throwing for the "not a WIM" case, because
    /// callers probe files they have no promise about. A file that *is* a WIM
    /// but cannot be read throws, so a genuine problem is not silently mistaken
    /// for an unrecognised format.
    static func read(from url: URL) throws -> WIMMetadata? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataUnreadable),
                diagnostics: "open \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: headerSize), header.count == headerSize
        else { return nil }
        guard header.prefix(magic.count) == magic else { return nil }

        let headerFlags = header.readLE32(at: 16)
        let imageCount = Int(header.readLE32(at: 44))
        let partNumber = Int(header.readLE16(at: 40))
        let totalParts = Int(header.readLE16(at: 42))

        // Resource descriptor: 56-bit size, 8-bit flags, then two 64-bit fields.
        let sizeAndFlags = header.readLE64(at: xmlResourceOffset)
        let storedSize = sizeAndFlags & 0x00FF_FFFF_FFFF_FFFF
        let offset = header.readLE64(at: xmlResourceOffset + 8)
        let uncompressedSize = header.readLE64(at: xmlResourceOffset + 16)

        let compression = Self.compression(fromHeaderFlags: headerFlags)
        let solid = try? Self.hasSolidResources(handle: handle, header: header, url: url)

        // An empty descriptor is legal: a WIM need not carry XML at all.
        guard storedSize > 0 else {
            return WIMMetadata(
                imageCount: imageCount, partNumber: partNumber,
                totalParts: totalParts, images: [],
                compression: compression, hasSolidResources: solid
            )
        }

        // The blob is only readable directly when it is stored uncompressed,
        // which is what every WIM in practice does. Reported rather than
        // guessed at, so a compressed blob does not turn into garbage XML.
        guard storedSize == uncompressedSize else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataCompressed),
                remedy: t(.errorWimMetadataCompressedRemedy),
                diagnostics: "xml stored=\(storedSize) uncompressed=\(uncompressedSize)"
            )
        }

        guard storedSize <= UInt64(maximumXMLBytes) else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataUnreadable),
                diagnostics: "xml size \(storedSize) exceeds cap \(maximumXMLBytes)"
            )
        }

        // Bounds-checked against the real file length before seeking, so a
        // bogus offset cannot be turned into a read past the end.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
            ?? nil
        if let fileSize, offset &+ storedSize > fileSize {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataUnreadable),
                diagnostics: "xml range \(offset)+\(storedSize) exceeds file size \(fileSize)"
            )
        }

        try handle.seek(toOffset: offset)
        guard let raw = try handle.read(upToCount: Int(storedSize)),
              raw.count == Int(storedSize)
        else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataUnreadable),
                diagnostics: "short read of xml at \(offset)"
            )
        }

        let images = parseImages(fromUTF16LE: raw)
        return WIMMetadata(
            imageCount: imageCount, partNumber: partNumber,
            totalParts: totalParts, images: images,
            compression: compression, hasSolidResources: solid
        )
    }

    /// Header flag bits, as `WIM_HDR_FLAG_*`.
    static func compression(fromHeaderFlags flags: UInt32) -> WIMCompression {
        guard flags & 0x0000_0002 != 0 else { return .uncompressed }
        if flags & 0x0008_0000 != 0 { return .lzms }
        if flags & 0x0004_0000 != 0 { return .lzx }
        if flags & 0x0002_0000 != 0 { return .xpress }
        return .uncompressed
    }

    /// Size of one blob-table descriptor on disk.
    ///
    /// 24-byte resource header, 2-byte part number, 4-byte reference count,
    /// 20-byte SHA-1. Confirmed against wimlib output: tables of 150 and 200
    /// bytes held exactly 3 and 4 entries.
    static let blobEntrySize = 50
    /// `WIM_RESHDR_FLAG_SOLID`
    static let solidFlag: UInt8 = 0x10
    /// Cap on the blob table, for the same reason as the XML cap.
    static let maximumBlobTableBytes = 64 * 1024 * 1024

    /// Scans the blob table for a solid resource.
    ///
    /// Throws when the table cannot be read, so the caller can distinguish
    /// "definitely not solid" from "do not know" — the two must not collapse
    /// into the same `false`.
    static func hasSolidResources(
        handle: FileHandle,
        header: Data,
        url: URL
    ) throws -> Bool {
        // rhOffsetTable sits at offset 48, immediately before rhXmlData.
        let sizeAndFlags = header.readLE64(at: 48)
        let storedSize = sizeAndFlags & 0x00FF_FFFF_FFFF_FFFF
        let offset = header.readLE64(at: 56)
        let uncompressedSize = header.readLE64(at: 64)

        guard storedSize > 0 else { return false }
        // A compressed table would need the WIM decompressor, which is the one
        // thing this reader deliberately does not carry.
        guard storedSize == uncompressedSize else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataCompressed),
                diagnostics: "blob table stored=\(storedSize) uncompressed=\(uncompressedSize)"
            )
        }
        guard storedSize <= UInt64(maximumBlobTableBytes),
              storedSize % UInt64(blobEntrySize) == 0
        else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataUnreadable),
                diagnostics: "blob table size \(storedSize) implausible"
            )
        }

        try handle.seek(toOffset: offset)
        guard let table = try handle.read(upToCount: Int(storedSize)),
              table.count == Int(storedSize)
        else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorWimMetadataUnreadable),
                diagnostics: "short read of blob table at \(offset)"
            )
        }

        let entries = Int(storedSize) / blobEntrySize
        for index in 0..<entries {
            let base = table.startIndex + index * blobEntrySize
            // The flag byte is the most significant byte of the 64-bit
            // size-and-flags field, so byte 7 of the descriptor.
            let flags = table[base + 7]
            if flags & solidFlag != 0 { return true }
        }
        return false
    }

    /// Decodes the UTF-16LE payload and pulls out the image list.
    static func parseImages(fromUTF16LE raw: Data) -> [WIMImage] {
        var bytes = raw
        // Strip the byte-order mark wimlib and Microsoft both write.
        if bytes.count >= 2, bytes[bytes.startIndex] == 0xFF, bytes[bytes.startIndex + 1] == 0xFE {
            bytes = bytes.dropFirst(2)
        }
        // An odd length means a truncated code unit; dropping it beats
        // returning nil for the whole blob.
        if bytes.count % 2 != 0 { bytes = bytes.dropLast() }

        guard let xml = String(data: bytes, encoding: .utf16LittleEndian) else { return [] }
        return parseImages(fromXML: xml)
    }

    static func parseImages(fromXML xml: String) -> [WIMImage] {
        let delegate = WIMXMLDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        // A real XML parser rather than regular expressions: the blob is
        // attacker-adjacent (it comes out of a downloaded ISO) and the element
        // nesting matters — `<TOTALBYTES>` appears both inside `<IMAGE>` and at
        // the top level, and a regex would conflate them.
        guard parser.parse() else { return delegate.images }
        return delegate.images
    }
}

// MARK: - XML

/// Collects `<IMAGE>` elements.
private final class WIMXMLDelegate: NSObject, XMLParserDelegate {
    var images: [WIMImage] = []

    private var elementPath: [String] = []
    private var text = ""

    private var index: Int?
    private var name: String?
    // Not `description`: that is `NSObject.description`, and shadowing it
    // with a private stored property is rejected outright.
    private var imageDescription: String?
    private var editionID: String?
    private var arch: Int?
    private var major: Int?
    private var minor: Int?
    private var build: Int?
    private var spBuild: Int?
    private var languages: [String] = []
    private var defaultLanguage: String?
    private var totalBytes: UInt64?

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        elementPath.append(element.uppercased())
        text = ""
        if element.uppercased() == "IMAGE" {
            resetImage()
            index = attributes["INDEX"].flatMap(Int.init)
                ?? attributes["Index"].flatMap(Int.init)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement element: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = element.uppercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inImage = elementPath.contains("IMAGE")
        let inVersion = elementPath.contains("VERSION")
        let inLanguages = elementPath.contains("LANGUAGES")

        if inImage {
            switch name {
            case "NAME" where !inLanguages: self.name = value
            case "DESCRIPTION": imageDescription = value
            case "EDITIONID": editionID = value
            case "ARCH": arch = Int(value)
            case "MAJOR" where inVersion: major = Int(value)
            case "MINOR" where inVersion: minor = Int(value)
            case "BUILD" where inVersion: build = Int(value)
            case "SPBUILD" where inVersion: spBuild = Int(value)
            case "LANGUAGE" where inLanguages:
                if !value.isEmpty { languages.append(value) }
            case "DEFAULT" where inLanguages: defaultLanguage = value
            // Only the one nested in <IMAGE>; the top-level element of the same
            // name is the archive size and means something different.
            case "TOTALBYTES": totalBytes = UInt64(value)
            case "IMAGE": finishImage()
            default: break
            }
        }

        elementPath.removeLast()
        text = ""
    }

    private func finishImage() {
        // An image with no index is unusable — it cannot be referenced when
        // applying — so it is skipped rather than invented.
        guard let index else { resetImage(); return }
        images.append(
            WIMImage(
                index: index,
                name: name ?? imageDescription ?? "Image \(index)",
                description: imageDescription,
                editionID: editionID,
                architecture: arch.flatMap(WindowsArchitecture.init(rawValue:)),
                version: major.map { major in
                    WindowsVersion(
                        major: major, minor: minor ?? 0,
                        build: build ?? 0, servicePackBuild: spBuild
                    )
                },
                languages: languages,
                defaultLanguage: defaultLanguage,
                totalBytes: totalBytes
            )
        )
        resetImage()
    }

    private func resetImage() {
        index = nil; name = nil; imageDescription = nil; editionID = nil
        arch = nil; major = nil; minor = nil; build = nil; spBuild = nil
        languages = []; defaultLanguage = nil; totalBytes = nil
    }
}

// MARK: - Little-endian reads

private extension Data {
    func readLE16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        guard base + 1 < endIndex else { return 0 }
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readLE32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        guard base + 3 < endIndex else { return 0 }
        var value: UInt32 = 0
        for byte in 0..<4 { value |= UInt32(self[base + byte]) << (8 * UInt32(byte)) }
        return value
    }

    func readLE64(at offset: Int) -> UInt64 {
        let base = startIndex + offset
        guard base + 7 < endIndex else { return 0 }
        var value: UInt64 = 0
        for byte in 0..<8 { value |= UInt64(self[base + byte]) << (8 * UInt64(byte)) }
        return value
    }
}
