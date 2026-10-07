import CryptoKit
import Foundation
import Testing
@testable import BiscuitKit

@Suite("Katalog-Modell")
struct CatalogueModelTests {
    private func makeImage(
        id: String = "debian.stable.netinst",
        url: String = "https://cdimage.debian.org/x.iso",
        downloadSHA: String? = String(repeating: "a", count: 64),
        expandedSHA: String? = nil,
        expanded: UInt64? = nil,
        compression: CompressionFormat = .none
    ) -> CatalogueImage {
        CatalogueImage(
            id: id,
            name: "Debian",
            summary: "stable netinst",
            url: URL(string: url)!,
            downloadSizeBytes: 700_000_000,
            downloadSHA256: downloadSHA,
            expandedSizeBytes: expanded,
            expandedSHA256: expandedSHA,
            compression: compression,
            provenance: .init(strength: .publisherSignature, publisher: "Debian")
        )
    }

    private func catalogue(_ images: [CatalogueImage]) -> ImageCatalogue {
        ImageCatalogue(generatedAt: Date(), entries: images.map { .image($0) })
    }

    @Test("Verschachtelte Kategorien werden rekursiv aufgelöst")
    func recursiveFlattening() {
        // The Raspberry Pi catalogue nests five levels deep, so two levels of
        // hand-rolled iteration would silently drop most entries.
        let deep = CatalogueNode.category(.init(name: "A", children: [
            .category(.init(name: "B", children: [
                .category(.init(name: "C", children: [
                    .image(makeImage(id: "deep.one")),
                    .image(makeImage(id: "deep.two"))
                ]))
            ])),
            .image(makeImage(id: "shallow"))
        ]))
        let model = ImageCatalogue(generatedAt: Date(), entries: [deep])
        #expect(model.allImages.count == 3)
        #expect(model.image(id: "deep.two") != nil)
    }

    @Test("Katalog überlebt die JSON-Codierung")
    func codableRoundTrip() throws {
        let original = ImageCatalogue(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), entries: [
            .category(.init(name: "Linux", summary: "Distributionen", children: [
                .image(makeImage(id: "a")),
                .image(makeImage(id: "b", expanded: 9_000_000_000, compression: .xz))
            ]))
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ImageCatalogue.self, from: try encoder.encode(original))
        #expect(decoded == original)
    }

    @Test("Doppelte Kennungen werden abgelehnt")
    func rejectsDuplicateIDs() {
        // Two entries with the same id would make a cached download ambiguous.
        let model = catalogue([makeImage(id: "same"), makeImage(id: "same")])
        #expect(throws: BiscuitError.self) { try model.validate() }
    }

    @Test("Nicht-HTTPS-URLs werden abgelehnt")
    func rejectsPlainHTTP() {
        let model = catalogue([makeImage(url: "http://example.com/x.iso")])
        #expect(throws: BiscuitError.self) { try model.validate() }
    }

    @Test("Fehlerhafte Prüfsummen werden abgelehnt")
    func rejectsMalformedDigest() {
        #expect(throws: BiscuitError.self) {
            try catalogue([makeImage(downloadSHA: "zzzz")]).validate()
        }
        #expect(throws: BiscuitError.self) {
            try catalogue([makeImage(downloadSHA: String(repeating: "a", count: 63))]).validate()
        }
    }

    @Test("Leerer Katalog wird abgelehnt")
    func rejectsEmpty() {
        #expect(throws: BiscuitError.self) {
            try ImageCatalogue(generatedAt: Date(), entries: []).validate()
        }
    }

    @Test("Unbekannte Formatversion wird abgelehnt")
    func rejectsFutureFormat() {
        let model = ImageCatalogue(
            formatVersion: ImageCatalogue.supportedFormatVersion + 1,
            generatedAt: Date(),
            entries: [.image(makeImage())]
        )
        #expect(throws: BiscuitError.self) { try model.validate() }
    }

    @Test("Erwartete entpackte Größe folgt der Kompression")
    func expandedSizeLogic() {
        // For an uncompressed image the download size is the expanded size; for
        // a compressed one only an explicit figure will do, because the
        // download size says nothing about what it becomes.
        #expect(makeImage(compression: .none).expectedExpandedSize == .exact(700_000_000))
        #expect(makeImage(compression: .xz).expectedExpandedSize == .unknown)
        #expect(
            makeImage(expanded: 9_000_000_000, compression: .xz).expectedExpandedSize
                == .exact(9_000_000_000)
        )
    }

    @Test("Ein Eintrag ohne jede Prüfsumme gilt als nicht verifizierbar")
    func unverifiableEntry() {
        #expect(!makeImage(downloadSHA: nil).isVerifiable)
        #expect(makeImage(downloadSHA: nil, expandedSHA: String(repeating: "b", count: 64)).isVerifiable)
    }
}

@Suite("Katalog laden", .serialized)
struct CatalogueLoaderTests {
    /// Signs a catalogue the way the release pipeline does.
    private func makeSigned() throws -> (data: Data, signature: Data, publicKey: String) {
        let model = ImageCatalogue(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), entries: [
            .image(CatalogueImage(
                id: "test.image",
                name: "Test",
                summary: "x",
                url: URL(string: "https://example.com/a.img.xz")!,
                downloadSizeBytes: 100,
                downloadSHA256: String(repeating: "a", count: 64),
                compression: .xz,
                provenance: .init(strength: .publisherChecksum, publisher: "Test")
            ))
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(model)

        let key = Curve25519.Signing.PrivateKey()
        return (data, try key.signature(for: data), key.publicKey.rawRepresentation.base64EncodedString())
    }

    private func makeCacheDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-cat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Ein korrekt signierter Katalog wird angenommen")
    func acceptsSignedCatalogue() throws {
        let fixture = try makeSigned()
        try ReleaseSignature.verify(
            payload: fixture.data,
            signature: fixture.signature,
            publicKey: try ReleaseSignature.parsePublicKey(base64: fixture.publicKey)
        )
    }

    @Test("Ein verändertes Byte bricht die Signatur")
    func rejectsTamperedCatalogue() throws {
        // The catalogue decides which checksum a download is held to, so it is
        // exactly as security-critical as an app update and is protected the
        // same way.
        var fixture = try makeSigned()
        var bytes = [UInt8](fixture.data)
        bytes[bytes.count / 2] ^= 0x01
        fixture.data = Data(bytes)

        #expect(throws: BiscuitError.self) {
            try ReleaseSignature.verify(
                payload: fixture.data,
                signature: fixture.signature,
                publicKey: try ReleaseSignature.parsePublicKey(base64: fixture.publicKey)
            )
        }
    }

    @Test("Eine Signatur eines fremden Schlüssels wird abgelehnt")
    func rejectsForeignSignature() throws {
        let fixture = try makeSigned()
        let attacker = Curve25519.Signing.PrivateKey()
        let forged = try attacker.signature(for: fixture.data)

        #expect(throws: BiscuitError.self) {
            try ReleaseSignature.verify(
                payload: fixture.data,
                signature: forged,
                publicKey: try ReleaseSignature.parsePublicKey(base64: fixture.publicKey)
            )
        }
    }

    @Test("Ohne eingebetteten Schlüssel wird kein Katalog verwendet")
    func refusesWithoutKey() async throws {
        let cache = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }

        let loader = CatalogueLoader(configuration: .init(
            catalogueURL: URL(string: "https://example.invalid/catalogue.json")!,
            signatureURL: URL(string: "https://example.invalid/catalogue.json.sig")!,
            publicKeyBase64: "",
            cacheDirectory: cache
        ))

        let result = await loader.load()
        guard case .failure = result else {
            Issue.record("ohne Schlüssel hätte der Katalog abgelehnt werden müssen")
            return
        }
    }

    @Test("Ein unerreichbarer Katalog ohne Cache meldet einen Fehler")
    func reportsFailureWithoutCache() async throws {
        let cache = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }

        let loader = CatalogueLoader(configuration: .init(
            catalogueURL: URL(string: "https://localhost:1/catalogue.json")!,
            signatureURL: URL(string: "https://localhost:1/catalogue.json.sig")!,
            publicKeyBase64: Curve25519.Signing.PrivateKey()
                .publicKey.rawRepresentation.base64EncodedString(),
            cacheDirectory: cache
        ))

        let result = await loader.load()
        guard case .failure = result else {
            Issue.record("erwartete einen Fehler ohne Netz und ohne Cache")
            return
        }
    }
}

/// Pins the JSON shape the generator produces against the model that decodes it.
///
/// The two live in different languages and different files, so a renamed field
/// produces a catalogue that builds cleanly in CI and fails to decode in the
/// app — the kind of break that is only noticed once it is published.
@Suite("Katalog-Format gegen Generator")
struct CatalogueFixtureTests {
    private func loadFixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "sample-catalogue",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "sample-catalogue.json fehlt — erzeugen mit: python3 Scripts/build-catalogue.py --sample"
        )
        return try Data(contentsOf: url)
    }

    private func decode(_ data: Data) throws -> ImageCatalogue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImageCatalogue.self, from: data)
    }

    @Test("Der vom Generator erzeugte Katalog lässt sich decodieren")
    func generatorOutputDecodes() throws {
        let catalogue = try decode(try loadFixture())
        try catalogue.validate()
        #expect(catalogue.formatVersion == ImageCatalogue.supportedFormatVersion)
        #expect(catalogue.allImages.count == 2)
    }

    @Test("Alle Felder kommen an, nicht nur die Pflichtfelder")
    func allFieldsSurvive() throws {
        let catalogue = try decode(try loadFixture())

        let plain = try #require(catalogue.image(id: "sample.plain"))
        #expect(plain.compression == .none)
        #expect(plain.downloadSHA256 == String(repeating: "a", count: 64))
        #expect(plain.provenance.strength == .publisherSignature)
        #expect(plain.provenance.signingKeyFingerprint?.count == 40)
        #expect(plain.provenance.verifiedAt != nil)

        let compressed = try #require(catalogue.image(id: "sample.compressed"))
        #expect(compressed.compression == .xz)
        // The decisive field for the capacity check — a compressed entry
        // without it would let a too-small disk be accepted.
        #expect(compressed.expectedExpandedSize == .exact(9_000_000_000))
        #expect(compressed.expandedSHA256 == String(repeating: "c", count: 64))
        #expect(compressed.provenance.strength == .publisherChecksum)
        #expect(compressed.notes.count == 1)
    }

    @Test("Weggelassene Felder werden als nil decodiert, nicht als Fehler")
    func optionalFieldsMayBeAbsent() throws {
        // The generator omits keys it has no value for, so the model must treat
        // absence as nil rather than refusing the whole catalogue.
        let catalogue = try decode(try loadFixture())
        let plain = try #require(catalogue.image(id: "sample.plain"))
        #expect(plain.expandedSHA256 == nil)
        #expect(plain.releaseDate == nil)
    }
}

/// Decodes a catalogue produced by a real run of the generator against the
/// live distribution servers.
///
/// The sample fixture pins the shape; this one pins reality. They differ in a
/// way that matters: the sample is written by hand in the generator, so a
/// change to a *source* — Fedora switching checksum formats, say — would not
/// show up there at all.
@Suite("Echter Katalog")
struct LiveCatalogueFixtureTests {
    @Test("Ein echt erzeugter Katalog wird akzeptiert")
    func liveCatalogueDecodes() throws {
        guard let url = Bundle.module.url(
            forResource: "live-catalogue", withExtension: "json", subdirectory: "Fixtures"
        ) else {
            Issue.record(Comment("live-catalogue.json fehlt — erzeugen mit Scripts/build-catalogue.py"))
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalogue = try decoder.decode(ImageCatalogue.self, from: try Data(contentsOf: url))
        try catalogue.validate()

        #expect(catalogue.allImages.count >= 3)
        // Every entry must be checkable against something; an entry nobody can
        // verify is worse than a missing one.
        for image in catalogue.allImages {
            #expect(image.isVerifiable, "\(image.id) hat keine Prüfsumme")
            #expect(image.url.scheme == "https")
        }
        // At least the signature-verified sources must have come through.
        #expect(
            catalogue.allImages.contains { $0.provenance.strength == .publisherSignature },
            "kein Eintrag mit geprüfter Publisher-Signatur"
        )
    }
}

/// Verifies a catalogue signed by the real release script with the real
/// `openssl` invocation, against the Swift verifier that ships in the app.
///
/// Both halves of this chain already have unit tests. What they do not prove is
/// that they agree — and a mismatch between the signing script and the
/// verifying code would make every published catalogue unusable, discovered
/// only after it went live.
@Suite("Signierter Katalog aus der Pipeline")
struct SignedCatalogueFixtureTests {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "\(name).\(ext) fehlt — erzeugen mit Scripts/sign-catalogue.sh"
        )
        return try Data(contentsOf: url)
    }

    private func publicKey() throws -> String {
        String(decoding: try fixture("signed-catalogue", "pubkey"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("Die Signatur des Skripts wird vom App-Verifizierer akzeptiert")
    func scriptSignatureIsAccepted() throws {
        let catalogue = try fixture("signed-catalogue", "json")
        let signature = try fixture("signed-catalogue.json", "sig")

        #expect(signature.count == ReleaseSignature.signatureByteCount)
        try ReleaseSignature.verify(
            payload: catalogue,
            signature: signature,
            publicKey: try ReleaseSignature.parsePublicKey(base64: try publicKey())
        )
    }

    @Test("Der signierte Katalog ist auch inhaltlich gültig")
    func signedCatalogueValidates() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalogue = try decoder.decode(
            ImageCatalogue.self, from: try fixture("signed-catalogue", "json")
        )
        try catalogue.validate()
        #expect(!catalogue.allImages.isEmpty)
    }

    @Test("Ein einziges geändertes Byte macht die Signatur ungültig")
    func tamperingIsDetected() throws {
        var bytes = [UInt8](try fixture("signed-catalogue", "json"))
        // Flip a bit in the middle of the payload — a modified URL or checksum
        // would look much like this.
        bytes[bytes.count / 2] ^= 0x01

        #expect(throws: BiscuitError.self) {
            try ReleaseSignature.verify(
                payload: Data(bytes),
                signature: try fixture("signed-catalogue.json", "sig"),
                publicKey: try ReleaseSignature.parsePublicKey(base64: try publicKey())
            )
        }
    }

    @Test("Ein fremder Schlüssel wird abgelehnt")
    func foreignKeyIsRejected() throws {
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
            .base64EncodedString()
        #expect(throws: BiscuitError.self) {
            try ReleaseSignature.verify(
                payload: try fixture("signed-catalogue", "json"),
                signature: try fixture("signed-catalogue.json", "sig"),
                publicKey: try ReleaseSignature.parsePublicKey(base64: other)
            )
        }
    }
}
