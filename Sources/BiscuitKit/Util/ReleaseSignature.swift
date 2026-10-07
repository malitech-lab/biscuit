import CryptoKit
import Foundation

/// Verifies the detached Ed25519 signature that every release archive carries.
///
/// This is the project's entire trust anchor. Because the app is not notarised,
/// Gatekeeper vouches for nothing; what makes an automatic update safe is that
/// the archive must be signed by the release key whose public half is compiled
/// into the running build. An attacker who controls the network, the GitHub
/// account, or the release assets still cannot produce an archive that installs.
///
/// Wire format, fixed by `Scripts/package-release.sh`:
/// - signature: 64 raw bytes, as produced by
///   `openssl pkeyutl -sign -rawin` with an Ed25519 key;
/// - public key: 32 raw bytes, base64 encoded — the tail of the DER SPKI
///   encoding, which is what `Curve25519.Signing.PublicKey(rawRepresentation:)`
///   expects.
///
/// Lives in the shared module rather than the app so it is covered by tests
/// that round-trip against the real `openssl` invocation used at release time.
public enum ReleaseSignature {
    public static let publicKeyByteCount = 32
    public static let signatureByteCount = 64

    public static func parsePublicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorUpdateNoKey),
                remedy: t(.errorUpdateNoKeyRemedy)
            )
        }
        guard let data = Data(base64Encoded: trimmed), data.count == publicKeyByteCount else {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorUpdateKeyInvalid),
                diagnostics: "expected \(publicKeyByteCount) bytes base64, "
                    + "got \(Data(base64Encoded: trimmed)?.count ?? -1)"
            )
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: data)
        } catch {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorUpdateKeyNotEd25519),
                diagnostics: String(describing: error)
            )
        }
    }

    /// Verifies `signature` over the bytes of the file at `url`.
    ///
    /// The payload is memory-mapped rather than read: a release archive is tens
    /// of megabytes and there is no reason to copy it onto the heap.
    public static func verify(
        fileAt url: URL,
        signature: Data,
        publicKeyBase64: String
    ) throws {
        let publicKey = try parsePublicKey(base64: publicKeyBase64)
        try verifyLength(of: signature)

        let payload: Data
        do {
            payload = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorArchiveUnreadable),
                diagnostics: String(describing: error)
            )
        }

        try verify(payload: payload, signature: signature, publicKey: publicKey)
    }

    public static func verify(
        payload: Data,
        signature: Data,
        publicKey: Curve25519.Signing.PublicKey
    ) throws {
        try verifyLength(of: signature)
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorSignatureInvalid),
                remedy: t(.errorSignatureInvalidRemedy)
            )
        }
    }

    private static func verifyLength(of signature: Data) throws {
        guard signature.count == signatureByteCount else {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorSignatureWrongLength),
                diagnostics: "\(signature.count) statt \(signatureByteCount) Bytes"
            )
        }
    }
}
