import Foundation
import Testing
@testable import BiscuitKit

@Suite("WIM-Metadaten")
struct WIMMetadataTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: name, withExtension: "wim", subdirectory: "Fixtures"
            ),
            "Fixture \(name).wim fehlt"
        )
    }

    // MARK: - Against a real file

    /// The header layout is taken on faith from documentation unless something
    /// checks it against a file a real implementation produced.
    @Test("Eine echte wimlib-Datei wird korrekt gelesen")
    func readsRealWimlibFile() throws {
        let metadata = try #require(try WIMMetadata.read(from: try fixture("real-wimlib")))
        #expect(metadata.imageCount == 1)
        #expect(metadata.partNumber == 1)
        #expect(metadata.totalParts == 1)
        #expect(!metadata.isSplit)

        let image = try #require(metadata.images.first)
        #expect(image.index == 1)
        #expect(image.name == "Testabbild")
        #expect(image.totalBytes == 11)
        // Not a Windows image, so there is no <WINDOWS> block to read.
        #expect(image.architecture == nil)
        #expect(image.version == nil)
        #expect(image.languages.isEmpty)
    }

    // MARK: - Windows metadata

    @Test("Editionen, Sprachen und Version werden ausgelesen")
    func readsWindowsMetadata() throws {
        let metadata = try #require(try WIMMetadata.read(from: try fixture("windows11-x64")))
        #expect(metadata.imageCount == 2)
        #expect(metadata.images.count == 2)

        let home = try #require(metadata.images.first { $0.index == 1 })
        #expect(home.name == "Windows 11 Home")
        #expect(home.editionID == "Core")
        #expect(home.architecture == .x64)
        #expect(home.languages == ["de-DE"])
        #expect(home.defaultLanguage == "de-DE")
        #expect(home.totalBytes == 16_039_280_640)

        let version = try #require(home.version)
        #expect(version.major == 10)
        #expect(version.build == 26_100)
        #expect(version.servicePackBuild == 1742)
        #expect(version.displayName == "10.0.26100.1742")

        let pro = try #require(metadata.images.first { $0.index == 2 })
        #expect(pro.editionID == "Professional")
        #expect(pro.languages.sorted() == ["de-DE", "en-US"])
    }

    @Test("Windows 11 wird an der Build-Nummer erkannt, nicht an der Hauptversion")
    func detectsGenerationFromBuild() {
        // Both Windows 10 and 11 report <MAJOR>10</MAJOR>, so the major version
        // alone would label every Windows 11 ISO as Windows 10.
        #expect(WindowsVersion(major: 10, minor: 0, build: 26_100).productGeneration == "Windows 11")
        #expect(WindowsVersion(major: 10, minor: 0, build: 22_000).productGeneration == "Windows 11")
        #expect(WindowsVersion(major: 10, minor: 0, build: 21_999).productGeneration == "Windows 10")
        #expect(WindowsVersion(major: 10, minor: 0, build: 19_045).productGeneration == "Windows 10")
        #expect(WindowsVersion(major: 6, minor: 1, build: 7601).productGeneration == nil)
    }

    @Test("Die gemeinsame Architektur wird erkannt")
    func commonArchitecture() throws {
        let x64 = try #require(try WIMMetadata.read(from: try fixture("windows11-x64")))
        #expect(x64.commonArchitecture == .x64)
        #expect(x64.commonArchitecture?.isCommonPCArchitecture == true)

        let arm = try #require(try WIMMetadata.read(from: try fixture("windows11-arm64")))
        #expect(arm.commonArchitecture == .arm64)
        // The distinction that matters: this medium will not boot a normal PC.
        #expect(arm.commonArchitecture?.isCommonPCArchitecture == false)
    }

    @Test("Die gemeinsame Version und alle Sprachen werden zusammengefasst")
    func commonVersionAndLanguages() throws {
        let metadata = try #require(try WIMMetadata.read(from: try fixture("windows11-x64")))
        #expect(metadata.commonVersion?.build == 26_100)
        #expect(metadata.allLanguages == ["de-DE", "en-US"])
    }

    @Test("Ein geteiltes Set wird als solches erkannt")
    func detectsSplitSet() throws {
        // Writing only part 2 of three produces unusable media, so the fact has
        // to survive inspection rather than be inferred from the file name.
        let metadata = try #require(try WIMMetadata.read(from: try fixture("split-part2")))
        #expect(metadata.isSplit)
        #expect(metadata.partNumber == 2)
        #expect(metadata.totalParts == 3)
    }

    // MARK: - Rejecting bad input

    @Test("Eine Datei ohne WIM-Magie ergibt nil, keinen Fehler")
    func nonWIMReturnsNil() throws {
        // Callers probe files with no promise about their type, so "not a WIM"
        // is an answer rather than a failure.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-wim-\(UUID().uuidString.prefix(6)).bin")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try WIMMetadata.read(from: url) == nil)
    }

    @Test("Eine zu kurze Datei ergibt nil")
    func truncatedFileReturnsNil() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("short-\(UUID().uuidString.prefix(6)).wim")
        try Data("MSWIM\0\0\0".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try WIMMetadata.read(from: url) == nil)
    }

    /// Each rejection asserts *which* check fired.
    ///
    /// The first version of these tests only asserted that something was
    /// thrown, and the oversize fixture happened to trip the
    /// size-mismatch check first — so the test passed while the 16 MiB cap it
    /// claimed to cover was never executed. Naming the expected message is what
    /// makes the difference between testing a behaviour and testing that an
    /// error exists.
    @Test("Eine absurde XML-Größe greift die Obergrenze, nicht einen Nebeneffekt")
    func absurdXMLSizeHitsTheCap() throws {
        // The size field is 56 bits wide. Without a cap this is an allocation
        // of up to 64 PiB driven by bytes out of a downloaded file.
        let error = try #require(throws: BiscuitError.self) {
            _ = try WIMMetadata.read(from: try fixture("corrupt-xmlsize"))
        }
        #expect(error.message == t(.errorWimMetadataUnreadable))
        #expect(
            error.diagnostics?.contains("exceeds cap") == true,
            "nicht die Obergrenze, sondern: \(error.diagnostics ?? "-")"
        )
    }

    @Test("Ein Bereich jenseits des Dateiendes wird abgelehnt")
    func outOfBoundsRangeIsRejected() throws {
        let error = try #require(throws: BiscuitError.self) {
            _ = try WIMMetadata.read(from: try fixture("xml-out-of-bounds"))
        }
        #expect(
            error.diagnostics?.contains("exceeds file size") == true,
            "nicht die Bereichsprüfung, sondern: \(error.diagnostics ?? "-")"
        )
    }

    @Test("Komprimierte Metadaten werden gemeldet, nicht als Müll gelesen")
    func compressedXMLIsReported() throws {
        // Reading a compressed blob as UTF-16 would yield plausible-looking
        // nonsense rather than an error.
        let error = try #require(throws: BiscuitError.self) {
            _ = try WIMMetadata.read(from: try fixture("compressed-xml"))
        }
        #expect(error.message == t(.errorWimMetadataCompressed))
    }

    @Test("Ein Abbild ohne INDEX wird übersprungen")
    func imageWithoutIndexIsSkipped() {
        // Without an index the image cannot be referenced when applying, so
        // inventing one would produce a medium that fails later.
        let images = WIMMetadata.parseImages(
            fromXML: "<WIM><IMAGE><NAME>Ohne Index</NAME></IMAGE>"
                + "<IMAGE INDEX=\"2\"><NAME>Mit Index</NAME></IMAGE></WIM>"
        )
        #expect(images.count == 1)
        #expect(images[0].index == 2)
        #expect(images[0].name == "Mit Index")
    }

    @Test("Das äußere TOTALBYTES wird nicht mit dem des Abbilds verwechselt")
    func outerTotalBytesIsNotConfused() {
        // <TOTALBYTES> appears both inside <IMAGE> and at the top level, where
        // it means the archive size. A regex over the blob would conflate them.
        let images = WIMMetadata.parseImages(
            fromXML: "<WIM><TOTALBYTES>999</TOTALBYTES>"
                + "<IMAGE INDEX=\"1\"><NAME>X</NAME><TOTALBYTES>123</TOTALBYTES></IMAGE>"
                + "</WIM>"
        )
        #expect(images.count == 1)
        #expect(images[0].totalBytes == 123)
    }

    @Test("Unvollständiges XML liefert, was lesbar war")
    func malformedXMLYieldsWhatParsed() {
        // A truncated blob should still produce the images that came through.
        let images = WIMMetadata.parseImages(
            fromXML: "<WIM><IMAGE INDEX=\"1\"><NAME>Eins</NAME></IMAGE><IMAGE INDEX=\"2\"><NAME>Zw"
        )
        #expect(images.count == 1)
        #expect(images[0].name == "Eins")
    }

    @Test("Eine unbekannte Architekturnummer wird nicht geraten")
    func unknownArchitectureStaysNil() {
        let images = WIMMetadata.parseImages(
            fromXML: "<WIM><IMAGE INDEX=\"1\"><NAME>X</NAME>"
                + "<WINDOWS><ARCH>77</ARCH></WINDOWS></IMAGE></WIM>"
        )
        #expect(images[0].architecture == nil)
    }

    @Test("Das BOM wird entfernt und UTF-16 dekodiert")
    func stripsByteOrderMark() {
        let xml = "<WIM><IMAGE INDEX=\"1\"><NAME>Füße</NAME></IMAGE></WIM>"
        var blob = Data([0xFF, 0xFE])
        blob.append(xml.data(using: .utf16LittleEndian)!)
        let images = WIMMetadata.parseImages(fromUTF16LE: blob)
        #expect(images.count == 1)
        // Non-ASCII survives the round trip, which is the point of decoding
        // rather than scanning bytes.
        #expect(images[0].name == "Füße")
    }

    @Test("Eine ungerade Byte-Länge stürzt nicht ab")
    func oddLengthIsTolerated() {
        var blob = Data([0xFF, 0xFE])
        blob.append("<WIM></WIM>".data(using: .utf16LittleEndian)!)
        blob.append(0x00)
        #expect(WIMMetadata.parseImages(fromUTF16LE: blob).isEmpty)
    }
}

/// Cross-checks the reader against `wiminfo`, when wimlib is installed.
@Suite("WIM-Abgleich mit wimlib", .serialized)
struct WIMCrossCheckTests {
    @Test("wiminfo und der eigene Leser stimmen überein", .timeLimit(.minutes(2)))
    func agreesWithWiminfo() async throws {
        let tool = "/opt/homebrew/bin/wiminfo"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            // wimlib is optional, so its absence is not a failure.
            return
        }
        guard let url = Bundle.module.url(
            forResource: "real-wimlib", withExtension: "wim", subdirectory: "Fixtures"
        ) else {
            Issue.record(Comment("Fixture fehlt")); return
        }

        let result = try await ProcessRunner.run(tool, arguments: [url.path], timeout: 60)
        guard result.succeeded else {
            Issue.record(Comment("wiminfo fehlgeschlagen: \(result.combinedOutput)"))
            return
        }

        let mine = try #require(try WIMMetadata.read(from: url))
        // Parses "Image Count:  1" out of wiminfo's report.
        let reported = result.standardOutput
            .split(separator: "\n")
            .first { $0.lowercased().contains("image count") }
            .flatMap { line in Int(line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces) ?? "") }

        #expect(reported == mine.imageCount, "wiminfo sagt \(reported ?? -1), gelesen \(mine.imageCount)")
    }
}

/// Splittability, measured against wimlib rather than guessed from the name.
///
/// The inspector used to decide this from the file extension: `.wim` splittable,
/// `.esd` not. That is wrong for a solid-compressed `install.wim`, which
/// `dism /compress:recovery` and UUP-based ISO builders both produce. The
/// consequence was a job that failed partway through writing the medium.
///
/// Every fixture here was produced by wimlib 1.14.5 and its splittability
/// confirmed by actually running `wimlib-imagex split` on it.
@Suite("WIM-Kompression und Teilbarkeit")
struct WIMCompressionTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: name, withExtension: "wim", subdirectory: "Fixtures"
            ),
            "Fixture \(name).wim fehlt"
        )
    }

    @Test("Die Kompressionsart wird aus den Header-Flaggen gelesen")
    func readsCompression() throws {
        #expect(try WIMMetadata.read(from: try fixture("real-wimlib"))?.compression == .uncompressed)
        #expect(try WIMMetadata.read(from: try fixture("compress-lzx"))?.compression == .lzx)
        #expect(try WIMMetadata.read(from: try fixture("compress-xpress"))?.compression == .xpress)
        #expect(try WIMMetadata.read(from: try fixture("compress-solid"))?.compression == .lzms)
    }

    @Test("Solid-Ressourcen werden erkannt — die Header-Flaggen genügen dafür nicht")
    func detectsSolidResources() throws {
        // The measurement that drove this design: these two files carry
        // identical header flags (0x00080082), and only one can be split.
        let solid = try #require(try WIMMetadata.read(from: try fixture("compress-solid")))
        let nonSolid = try #require(try WIMMetadata.read(from: try fixture("compress-lzms-nonsolid")))

        #expect(solid.compression == nonSolid.compression, "Annahme des Tests hinfällig")
        #expect(solid.hasSolidResources == true)
        #expect(nonSolid.hasSolidResources == false)
        #expect(solid.canBeSplit == false, "solid wäre zum Teilen geschickt worden")
        #expect(nonSolid.canBeSplit == true)
    }

    @Test("Unkomprimierte und klassisch komprimierte Abbilder sind teilbar")
    func classicCompressionIsSplittable() throws {
        for name in ["real-wimlib", "compress-lzx", "compress-xpress"] {
            let metadata = try #require(try WIMMetadata.read(from: try fixture(name)))
            #expect(metadata.canBeSplit, "\(name) sollte teilbar sein")
        }
    }

    @Test("Unbekannte Teilbarkeit gilt als nicht teilbar")
    func unknownMeansNotSplittable() {
        // A wrong "cannot split" costs a re-export; a wrong "can split" costs a
        // half-written medium. The asymmetry decides the default.
        let unknown = WIMMetadata(
            imageCount: 1, partNumber: 1, totalParts: 1, images: [],
            compression: .lzms, hasSolidResources: nil
        )
        #expect(unknown.canBeSplit == false)
    }
}

/// Confirms the splittability verdict against the tool that enforces it.
@Suite("Teilbarkeit gegen wimlib", .serialized)
struct WIMSplitAgreementTests {
    @Test("wimlib teilt genau die Abbilder, die als teilbar gelten", .timeLimit(.minutes(3)))
    func verdictMatchesWimlib() async throws {
        let tool = "/opt/homebrew/bin/wimlib-imagex"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-split-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for name in ["real-wimlib", "compress-lzx", "compress-solid", "compress-lzms-nonsolid"] {
            guard let url = Bundle.module.url(
                forResource: name, withExtension: "wim", subdirectory: "Fixtures"
            ) else { continue }

            let predicted = try WIMMetadata.read(from: url)?.canBeSplit ?? false
            let result = try await ProcessRunner.run(
                tool,
                arguments: ["split", url.path, scratch.appendingPathComponent("\(name).swm").path, "0.001"],
                timeout: 60
            )
            // Judged by exit status, not by searching the output for "solid".
            // That substring check was the first attempt and produced a false
            // positive immediately: wimlib echoes the input path in its
            // success message, and the fixture is named
            // "compress-lzms-nonsolid.wim". Matching a substring against text
            // that contains the input is how that happens.
            let actual = result.succeeded

            #expect(
                predicted == actual,
                "\(name): vorhergesagt teilbar=\(predicted), wimlib exit=\(result.exitCode)"
            )
            if !actual {
                // 68 is wimlib's "requested operation is unsupported". Asserted
                // so a different failure — a missing file, a bad argument —
                // cannot masquerade as the solid-resource refusal.
                #expect(result.exitCode == 68, "\(name): unerwarteter Exit \(result.exitCode)")
            }
        }
    }
}

/// The split-versus-convert decision.
///
/// Tested directly rather than through an ISO: the branch only fires for inner
/// files above 4 GiB, and a 5 GB fixture is not practical. The wiring is
/// covered by `WindowsISOInspectionTests`.
@Suite("Teilen oder konvertieren")
struct OversizeHandlingTests {
    private func entry(_ name: String, gibibytes: UInt64 = 5) -> MountScan.Entry {
        MountScan.Entry(
            name: name,
            relativePath: "sources/\(name)",
            sizeBytes: gibibytes * 1024 * 1024 * 1024
        )
    }

    private func metadata(solid: Bool?, compression: WIMCompression) -> WIMMetadata {
        WIMMetadata(
            imageCount: 1, partNumber: 1, totalParts: 1, images: [],
            compression: compression, hasSolidResources: solid
        )
    }

    @Test("Ein gewöhnliches install.wim wird geteilt")
    func ordinaryWIMIsSplit() {
        let result = ISOInspector.oversizeHandling(
            metadata: metadata(solid: false, compression: .lzx),
            oversized: [entry("install.wim")]
        )
        #expect(result.handling == .split)
        #expect(result.notes == [t(.noteWillSplitWIM)])
    }

    @Test("Ein solid-komprimiertes install.wim wird konvertiert, nicht geteilt")
    func solidWIMIsConverted() {
        // The bug this replaced: the extension said `.wim`, so it was sent to
        // be split, and `wimlib-imagex split` refused with exit 68 after the
        // medium was already partly written.
        let result = ISOInspector.oversizeHandling(
            metadata: metadata(solid: true, compression: .lzms),
            oversized: [entry("install.wim")]
        )
        #expect(result.handling == .convert)
        // And it says so, rather than silently doing something slower than the
        // user was told to expect.
        #expect(result.notes.contains(t(.noteSolidWIMCannotSplit, "LZMS")))
        #expect(result.notes.contains(t(.noteWillConvertESD)))
    }

    @Test("Ein ESD wird konvertiert, ohne überflüssigen Hinweis")
    func esdIsConvertedQuietly() {
        // An `.esd` was never going to be split, so the "looks splittable but
        // is not" note would only be noise here.
        let result = ISOInspector.oversizeHandling(
            metadata: metadata(solid: true, compression: .lzms),
            oversized: [entry("install.esd")]
        )
        #expect(result.handling == .convert)
        #expect(!result.notes.contains(t(.noteSolidWIMCannotSplit, "LZMS")))
    }

    @Test("Ohne Metadaten entscheidet die Endung")
    func fallsBackToExtension() {
        let wim = ISOInspector.oversizeHandling(
            metadata: nil, oversized: [entry("install.wim")]
        )
        #expect(wim.handling == .split)

        let esd = ISOInspector.oversizeHandling(
            metadata: nil, oversized: [entry("install.esd")]
        )
        #expect(esd.handling == .convert)
    }

    @Test("Unbekannte Teilbarkeit führt zur Konvertierung")
    func unknownSplittabilityConverts() {
        // `hasSolidResources == nil` means the blob table was unreadable. The
        // safe side is the slower one.
        let result = ISOInspector.oversizeHandling(
            metadata: metadata(solid: nil, compression: .lzms),
            oversized: [entry("install.wim")]
        )
        #expect(result.handling == .convert)
    }

    @Test("Eine gemischte Menge wird konvertiert")
    func mixedSetConverts() {
        // If any oversized file cannot be split, splitting is not a plan for
        // the set as a whole.
        let result = ISOInspector.oversizeHandling(
            metadata: nil,
            oversized: [entry("install.wim"), entry("payload.esd")]
        )
        #expect(result.handling == .convert)
    }
}

/// `install.esd` goes through the same reader as `install.wim`.
///
/// The assumption was that it would, because the XML blob is stored
/// uncompressed regardless of the archive's compression. That was measured
/// across all four variants wimlib produces — none, XPRESS, LZX and
/// solid/LZMS — but never against a file actually shaped like an ESD and
/// named like one. These tests close that gap.
///
/// Fixture produced by `wimlib-imagex export --solid --compress=LZMS`, which is
/// what Microsoft's ESDs are, and confirmed to be refused by
/// `wimlib-imagex split` with exit code 68.
@Suite("ESD-Abbilder")
struct ESDMetadataTests {
    private func esdFixture() throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: "windows-esd", withExtension: "esd", subdirectory: "Fixtures"
            ),
            "Fixture windows-esd.esd fehlt"
        )
    }

    @Test("Die Metadaten eines ESD werden gelesen")
    func readsESDMetadata() throws {
        // Same reader, different extension and compression: nothing about the
        // header layout depends on either.
        let metadata = try #require(try WIMMetadata.read(from: try esdFixture()))
        #expect(metadata.imageCount == 2)
        #expect(metadata.images.count == 2)
        #expect(metadata.compression == .lzms)
        #expect(metadata.commonArchitecture == .x64)
        #expect(metadata.commonVersion?.build == 26_100)
        #expect(metadata.images.map(\.editionID) == ["Core", "Professional"])
    }

    @Test("Ein ESD gilt als nicht teilbar")
    func esdIsNotSplittable() throws {
        let metadata = try #require(try WIMMetadata.read(from: try esdFixture()))
        #expect(metadata.hasSolidResources == true)
        #expect(!metadata.canBeSplit)
    }

    @Test("Die Entscheidung lautet konvertieren, ohne irreführenden Hinweis")
    func decisionIsConvert() throws {
        let metadata = try #require(try WIMMetadata.read(from: try esdFixture()))
        let entry = MountScan.Entry(
            name: "install.esd",
            relativePath: "sources/install.esd",
            sizeBytes: 5 * 1024 * 1024 * 1024
        )
        let result = ISOInspector.oversizeHandling(metadata: metadata, oversized: [entry])
        #expect(result.handling == .convert)
        // The "looks splittable by name but is not" note belongs only to a
        // `.wim`; on an `.esd` it would be noise.
        #expect(!result.notes.contains(t(.noteSolidWIMCannotSplit, "LZMS")))
        #expect(result.notes.contains(t(.noteWillConvertESD)))
    }

    /// Confirms the fixture really is what the tests above assume.
    @Test("wimlib lehnt dieses ESD tatsächlich zum Teilen ab", .timeLimit(.minutes(2)))
    func wimlibRefusesToSplitIt() async throws {
        let tool = "/opt/homebrew/bin/wimlib-imagex"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-esd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let result = try await ProcessRunner.run(
            tool,
            arguments: [
                "split", try esdFixture().path,
                scratch.appendingPathComponent("out.swm").path, "0.001"
            ],
            timeout: 60
        )
        // 68 is wimlib's "requested operation is unsupported".
        #expect(!result.succeeded)
        #expect(result.exitCode == 68, "unerwarteter Exit \(result.exitCode)")
    }
}
