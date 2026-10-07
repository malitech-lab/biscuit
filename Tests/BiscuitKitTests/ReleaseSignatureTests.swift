import CryptoKit
import Foundation
import Testing
@testable import BiscuitKit

/// The signature check is the project's only trust anchor, so it is tested
/// against the exact `openssl` invocation the release script uses rather than
/// only against CryptoKit signing CryptoKit. A mismatch between OpenSSL's raw
/// Ed25519 output and `Curve25519.Signing` would make every release
/// uninstallable, and would not be caught by a CryptoKit-only round trip.
@Suite("Release-Signatur")
struct ReleaseSignatureTests {
    /// Locates an OpenSSL that can do Ed25519. macOS ships LibreSSL, which
    /// cannot, so this is nil on a machine without Homebrew's openssl@3.
    private static let openssl: String? = {
        let candidates = [
            "/opt/homebrew/opt/openssl@3/bin/openssl",
            "/usr/local/opt/openssl@3/bin/openssl",
            "/opt/homebrew/bin/openssl",
            "/usr/local/bin/openssl"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate)
            process.arguments = ["genpkey", "-algorithm", "ED25519", "-out", "/dev/null"]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return candidate }
        }
        return nil
    }()

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("Mit openssl erzeugte Signatur wird von CryptoKit akzeptiert")
    func opensslInteroperability() throws {
        guard let openssl = Self.openssl else {
            // Not a silent pass: the message names the missing dependency.
            Issue.record(
                Comment("openssl@3 mit Ed25519 nicht gefunden — Interop-Test übersprungen. brew install openssl@3")
            )
            return
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let keyURL = scratch.appendingPathComponent("release.key")
        let publicDER = scratch.appendingPathComponent("release.der")
        let payloadURL = scratch.appendingPathComponent("archive.zip")
        let signatureURL = scratch.appendingPathComponent("archive.zip.sig")

        // Same commands as Scripts/keygen.sh and Scripts/package-release.sh.
        try #require(try run(openssl, ["genpkey", "-algorithm", "ED25519", "-out", keyURL.path]) == 0)
        try #require(try run(openssl, [
            "pkey", "-in", keyURL.path, "-pubout", "-outform", "DER", "-out", publicDER.path
        ]) == 0)

        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 253) })
        try payload.write(to: payloadURL)

        try #require(try run(openssl, [
            "pkeyutl", "-sign",
            "-inkey", keyURL.path,
            "-rawin",
            "-in", payloadURL.path,
            "-out", signatureURL.path
        ]) == 0)

        // The public key as the build embeds it: tail 32 bytes of DER SPKI,
        // base64 encoded.
        let der = try Data(contentsOf: publicDER)
        try #require(der.count >= ReleaseSignature.publicKeyByteCount)
        let rawKey = der.suffix(ReleaseSignature.publicKeyByteCount)
        let publicKeyBase64 = Data(rawKey).base64EncodedString()

        let signature = try Data(contentsOf: signatureURL)
        #expect(signature.count == ReleaseSignature.signatureByteCount)

        // The actual assertion: our verifier accepts OpenSSL's output.
        try ReleaseSignature.verify(
            fileAt: payloadURL,
            signature: signature,
            publicKeyBase64: publicKeyBase64
        )

        // A single flipped byte in the payload must be rejected.
        var tampered = payload
        tampered[12345] ^= 0x01
        let tamperedURL = scratch.appendingPathComponent("tampered.zip")
        try tampered.write(to: tamperedURL)
        #expect(throws: BiscuitError.self) {
            try ReleaseSignature.verify(
                fileAt: tamperedURL,
                signature: signature,
                publicKeyBase64: publicKeyBase64
            )
        }

        // A signature from a different key must be rejected.
        let otherKey = scratch.appendingPathComponent("other.key")
        let otherSignature = scratch.appendingPathComponent("other.sig")
        try #require(try run(openssl, ["genpkey", "-algorithm", "ED25519", "-out", otherKey.path]) == 0)
        try #require(try run(openssl, [
            "pkeyutl", "-sign", "-inkey", otherKey.path,
            "-rawin", "-in", payloadURL.path, "-out", otherSignature.path
        ]) == 0)
        #expect(throws: BiscuitError.self) {
            try ReleaseSignature.verify(
                fileAt: payloadURL,
                signature: try Data(contentsOf: otherSignature),
                publicKeyBase64: publicKeyBase64
            )
        }
    }

    @Test("CryptoKit-eigener Roundtrip")
    func cryptoKitRoundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let payload = Data("biscuit release".utf8)
        let signature = try privateKey.signature(for: payload)

        let publicKey = try ReleaseSignature.parsePublicKey(base64: publicKeyBase64)
        try ReleaseSignature.verify(payload: payload, signature: signature, publicKey: publicKey)
    }

    @Test("Ungültige Schlüssel und Signaturen werden abgelehnt")
    func malformedInputs() throws {
        #expect(throws: BiscuitError.self) {
            _ = try ReleaseSignature.parsePublicKey(base64: "")
        }
        #expect(throws: BiscuitError.self) {
            _ = try ReleaseSignature.parsePublicKey(base64: "nicht-base64!")
        }
        #expect(throws: BiscuitError.self) {
            // 16 bytes instead of 32.
            _ = try ReleaseSignature.parsePublicKey(
                base64: Data(repeating: 0, count: 16).base64EncodedString()
            )
        }

        let publicKey = Curve25519.Signing.PrivateKey().publicKey
        #expect(throws: BiscuitError.self) {
            try ReleaseSignature.verify(
                payload: Data("x".utf8),
                signature: Data(repeating: 0, count: 32),
                publicKey: publicKey
            )
        }
    }
}

@Suite("Versionsvergleich")
struct SemanticVersionTests {
    @Test("v-Präfix wird entfernt")
    func normalisation() {
        #expect(SemanticVersion.normalise("v1.2.3") == "1.2.3")
        #expect(SemanticVersion.normalise("V1.2.3") == "1.2.3")
        #expect(SemanticVersion.normalise("  1.2.3  ") == "1.2.3")
        #expect(SemanticVersion.normalise("1.2.3") == "1.2.3")
    }

    @Test("Numerischer Vergleich, nicht lexikografisch")
    func numericOrdering() {
        #expect(SemanticVersion.isNewer("1.2.0", than: "1.1.9"))
        #expect(SemanticVersion.isNewer("2.0.0", than: "1.99.99"))
        // The classic lexicographic bug: "10" < "9" as a string.
        #expect(SemanticVersion.isNewer("1.10.0", than: "1.9.0"))
        #expect(SemanticVersion.isNewer("0.0.11", than: "0.0.2"))
        #expect(!SemanticVersion.isNewer("1.0.0", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("1.0.0", than: "1.0.1"))
    }

    @Test("Fehlende Komponenten gelten als Null")
    func missingComponents() {
        #expect(SemanticVersion.isNewer("1.1", than: "1.0.9"))
        #expect(!SemanticVersion.isNewer("1.0", than: "1.0.0"))
        #expect(SemanticVersion.isNewer("2", than: "1.9.9"))
    }

    @Test("Vorabversionen sortieren unter dem Release")
    func prereleaseOrdering() {
        #expect(SemanticVersion.isNewer("1.0.0", than: "1.0.0-beta.1"))
        #expect(!SemanticVersion.isNewer("1.0.0-beta.1", than: "1.0.0"))
        #expect(SemanticVersion.isNewer("1.0.0-beta.2", than: "1.0.0-beta.1"))
        #expect(SemanticVersion.isNewer("1.0.0-beta.10", than: "1.0.0-beta.9"))
    }

    @Test("Ein Downgrade wird nie als Update gemeldet")
    func noDowngrade() {
        // This is what stops a re-tagged old release from being installed.
        #expect(!SemanticVersion.isNewer("0.9.0", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("1.0.0-rc.1", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("0.0.1", than: "99.0.0"))
    }

    @Test("Unsinnige Eingaben führen nicht zu falschen Updates")
    func garbageInput() {
        #expect(!SemanticVersion.isNewer("", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("abc", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("1.0.0", than: "1.0.0"))
    }
}
