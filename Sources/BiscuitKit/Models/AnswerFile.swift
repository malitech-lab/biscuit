import Foundation

/// A Windows Setup answer file (`autounattend.xml`) to place on the media.
///
/// Carried as *contents* rather than a path, for the same reason the source
/// image is passed as a descriptor: the file almost always lives in
/// `~/Downloads`, macOS privacy protection guards that directory, and a root
/// process is not exempt. The app holds the user's consent, reads the file, and
/// hands over the bytes.
///
/// The contents are never written to any log. Answer files routinely contain a
/// local account password, a product key and sometimes domain credentials, all
/// in plain text — Windows' `PlainText=false` option only base64-encodes them,
/// which is not encryption.
public struct AnswerFile: Codable, Sendable, Hashable {
    /// Windows Setup looks for this exact name in the root of removable media.
    public static let standardFileName = "autounattend.xml"

    /// Hard cap. Real answer files are 2–50 KB; anything far beyond that is
    /// either not an answer file or an attempt to push a large payload through
    /// the IPC frame, which is bounded at 4 MiB.
    public static let maximumSizeBytes = 512 * 1024

    /// Expected XML namespace of the root element.
    public static let unattendNamespace = "urn:schemas-microsoft-com:unattend"

    /// Original file name, for display only. The file is always written as
    /// `autounattend.xml`.
    public let originalFileName: String
    public let contents: Data
    public let findings: [Finding]

    public var sizeBytes: Int { contents.count }

    public init(originalFileName: String, contents: Data, findings: [Finding]) {
        self.originalFileName = originalFileName
        self.contents = contents
        self.findings = findings
    }

    /// Something worth telling the user before the file is written.
    public struct Finding: Codable, Sendable, Hashable {
        public enum Severity: String, Codable, Sendable {
            /// Prevents use of the file.
            case blocking
            /// Written anyway, but the user should know.
            case warning
            /// Purely informational.
            case info
        }

        public enum Kind: String, Codable, Sendable {
            case notXML = "not_xml"
            case wrongRootElement = "wrong_root_element"
            case missingNamespace = "missing_namespace"
            case tooLarge = "too_large"
            case empty = "empty"
            case containsPassword = "contains_password"
            case containsProductKey = "contains_product_key"
            case containsDomainCredentials = "contains_domain_credentials"
            case renamed = "renamed"
        }

        public let kind: Kind
        public let severity: Severity
        /// Extra context, already localised where it is user-facing.
        public let detail: String?

        public init(kind: Kind, severity: Severity, detail: String? = nil) {
            self.kind = kind
            self.severity = severity
            self.detail = detail
        }
    }

    public var isUsable: Bool {
        !findings.contains { $0.severity == .blocking }
    }

    public var containsSecrets: Bool {
        findings.contains { finding in
            switch finding.kind {
            case .containsPassword, .containsProductKey, .containsDomainCredentials:
                return true
            default:
                return false
            }
        }
    }

    /// Summary for the UI. Never includes file contents.
    public var displaySummary: String {
        "\(originalFileName) · \(ByteCount.format(UInt64(sizeBytes)))"
    }
}

// MARK: - Inspection

/// Validates a candidate answer file before it is written.
///
/// A malformed answer file is worse than none: Windows Setup either aborts with
/// an unhelpful message or ignores the file silently, and either way the user
/// finds out twenty minutes later on the target machine. Catching it here costs
/// a millisecond.
public struct AnswerFileInspector: Sendable {
    public init() {}

    public func inspect(fileName: String, contents: Data) -> AnswerFile {
        var findings: [AnswerFile.Finding] = []

        if contents.isEmpty {
            findings.append(.init(kind: .empty, severity: .blocking))
            return AnswerFile(originalFileName: fileName, contents: contents, findings: findings)
        }

        if contents.count > AnswerFile.maximumSizeBytes {
            findings.append(.init(
                kind: .tooLarge,
                severity: .blocking,
                detail: ByteCount.format(UInt64(contents.count))
            ))
            return AnswerFile(originalFileName: fileName, contents: contents, findings: findings)
        }

        // Structure
        let structure = Self.inspectStructure(contents)
        findings.append(contentsOf: structure)

        // Only scan for secrets once the file is plausibly an answer file;
        // otherwise the warnings would be noise on an unrelated document.
        if !structure.contains(where: { $0.severity == .blocking }) {
            findings.append(contentsOf: Self.scanForSecrets(contents))
        }

        if fileName.lowercased() != AnswerFile.standardFileName {
            findings.append(.init(
                kind: .renamed,
                severity: .info,
                detail: AnswerFile.standardFileName
            ))
        }

        return AnswerFile(originalFileName: fileName, contents: contents, findings: findings)
    }

    // MARK: - Structure

    private static func inspectStructure(_ contents: Data) -> [AnswerFile.Finding] {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: contents, options: [.nodePreserveWhitespace])
        } catch {
            return [.init(
                kind: .notXML,
                severity: .blocking,
                // Parser messages are diagnostics: English and unlocalised.
                detail: (error as NSError).localizedDescription
            )]
        }

        guard let root = document.rootElement() else {
            return [.init(kind: .notXML, severity: .blocking, detail: "no root element")]
        }

        var findings: [AnswerFile.Finding] = []

        // Windows Setup requires the root element to be <unattend>. Anything
        // else is simply a different document that happens to be XML.
        if root.name?.lowercased() != "unattend" {
            findings.append(.init(
                kind: .wrongRootElement,
                severity: .blocking,
                detail: root.name ?? "?"
            ))
            return findings
        }

        let namespaces = (root.namespaces ?? []).compactMap(\.stringValue)
        let declaresNamespace = namespaces.contains(AnswerFile.unattendNamespace)
            || root.uri == AnswerFile.unattendNamespace
        if !declaresNamespace {
            // A warning rather than a blocker: Setup is lenient here, and
            // refusing a file that would have worked is its own kind of failure.
            findings.append(.init(
                kind: .missingNamespace,
                severity: .warning,
                detail: AnswerFile.unattendNamespace
            ))
        }

        return findings
    }

    // MARK: - Secrets

    /// Element names that carry credentials or licence material in plain text.
    ///
    /// Matched on element names rather than on values: a value-based heuristic
    /// would either miss short passwords or flag every string in the file.
    private static let secretElements: [(element: String, kind: AnswerFile.Finding.Kind)] = [
        ("password", .containsPassword),
        ("administratorpassword", .containsPassword),
        ("productkey", .containsProductKey),
        ("domainpassword", .containsDomainCredentials),
        ("credentials", .containsDomainCredentials)
    ]

    private static func scanForSecrets(_ contents: Data) -> [AnswerFile.Finding] {
        guard let document = try? XMLDocument(data: contents, options: []),
              let root = document.rootElement()
        else { return [] }

        var found: Set<AnswerFile.Finding.Kind> = []

        func walk(_ element: XMLElement) {
            let name = (element.name ?? "").lowercased()
            for candidate in secretElements where name == candidate.element {
                // An empty element carries nothing worth warning about.
                let value = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasChildren = (element.children ?? []).contains { $0.kind == .element }
                if hasChildren || !(value ?? "").isEmpty {
                    found.insert(candidate.kind)
                }
            }
            for child in element.children ?? [] {
                if let childElement = child as? XMLElement { walk(childElement) }
            }
        }
        walk(root)

        return found
            .sorted { $0.rawValue < $1.rawValue }
            .map { .init(kind: $0, severity: .warning) }
    }
}

// MARK: - Validation on the write path

public extension AnswerFile {
    /// Re-derives the findings from the bytes, ignoring whatever came with them.
    ///
    /// `findings` is part of the `Codable` representation, so it travels over
    /// the socket alongside the contents. `isUsable` is computed *from* those
    /// findings — which means a client that sends `findings: []` is declaring
    /// its own file acceptable, and the helper that merely reads `isUsable` is
    /// taking its word for it.
    ///
    /// That is what the helper used to do, under a comment claiming it
    /// re-validated rather than trusted the app. The claim was wrong: the
    /// bytes were never re-examined. This is the function that makes it true.
    func independentlyInspected() -> AnswerFile {
        AnswerFileInspector().inspect(fileName: originalFileName, contents: contents)
    }

    /// Throws unless the *contents* stand on their own.
    ///
    /// Intended for the privileged side, which must not draw conclusions from
    /// anything the unprivileged side computed for it.
    func assertWritable() throws {
        // Checked against the raw byte count first, independently of any
        // finding: this is the one limit that bounds work rather than merely
        // describing the file.
        guard contents.count <= Self.maximumSizeBytes else {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorAnswerFileRejected),
                diagnostics: "answer file is \(contents.count) bytes,"
                    + " limit \(Self.maximumSizeBytes)"
            )
        }

        let verdict = independentlyInspected()
        let blocking = verdict.findings.filter { $0.severity == .blocking }
        guard blocking.isEmpty else {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorAnswerFileRejected),
                diagnostics: "re-inspection rejected: "
                    + blocking.map(\.kind.rawValue).joined(separator: ", ")
            )
        }
    }
}
