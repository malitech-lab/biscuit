import Foundation

/// One of Microsoft's official ISO download pages.
public struct WindowsDownloadPage: Sendable, Equatable, Identifiable {
    public enum Architecture: String, Sendable, Equatable {
        case x64
        case arm64

        public var displayName: String {
            switch self {
            case .x64: return "x64"
            case .arm64: return "ARM64"
            }
        }
    }

    public let id: String
    /// Product name. Not localised — "Windows 11" is a proper noun.
    public let productName: String
    public let architecture: Architecture
    /// Path under microsoft.com, without a locale segment.
    public let path: String
    /// Short explanation of who this is for, localised.
    public let audience: StringKey

    public init(
        id: String,
        productName: String,
        architecture: Architecture,
        path: String,
        audience: StringKey
    ) {
        self.id = id
        self.productName = productName
        self.architecture = architecture
        self.path = path
        self.audience = audience
    }

    public var displayName: String { "\(productName) · \(architecture.displayName)" }

    /// The page URL, with Microsoft's locale segment when one is known.
    ///
    /// Microsoft serves the page without a locale segment too, redirecting by
    /// `Accept-Language`. Passing the segment explicitly means the user lands
    /// on the page in the language Biscuit is running in, rather than whatever
    /// their browser happens to ask for.
    public func url(locale: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.microsoft.com"
        if let locale, let segment = Self.localeSegment(for: locale) {
            components.path = "/\(segment)/\(path)"
        } else {
            components.path = "/\(path)"
        }
        // The components above are all literals or drawn from a fixed table, so
        // this cannot fail; the force-unwrap-free form keeps it provable.
        guard let url = components.url else {
            return URL(string: "https://www.microsoft.com/\(path)")!
        }
        return url
    }

    /// Maps a Biscuit language code to Microsoft's locale segment.
    ///
    /// Deliberately a short allow-list rather than anything derived from the
    /// system locale: an unknown segment produces a 404, and a 404 is worse
    /// than the undecorated URL, which redirects correctly on its own.
    static func localeSegment(for language: String) -> String? {
        switch language.lowercased().prefix(2) {
        case "de": return "de-de"
        case "en": return "en-us"
        default: return nil
        }
    }
}

/// What Biscuit can and cannot do about Windows images.
///
/// ## Why there is no Windows download
///
/// Microsoft's ISOs are not served from stable URLs. The download page drives a
/// three-step session API, and the final step is gated by a device-fingerprinting
/// service (ThreatMetrix, `org_id=y6jn8c31`). Measured directly: steps one and
/// two answer normally from a plain HTTP client, and the third returns
/// `ErrorSettings.SentinelReject`. Passing it requires being an actual browser,
/// which is precisely what Biscuit is not.
///
/// Tools that automate this anyway — Fido is the well-known one — are in a
/// permanent race with Microsoft's anti-automation work, and have lost it
/// repeatedly. Putting that race inside Biscuit would mean the download button
/// breaks on Microsoft's schedule, in a build already shipped, with no way to
/// fix it except a new release.
///
/// Moving the dance into CI does not help either: the rejection is of the
/// client, not of the app, so a GitHub runner is refused for the same reason.
/// The static CDN links the API eventually hands out are long-lived, but they
/// can only be *obtained* from behind the gate, so a catalogue of them cannot
/// be built or kept fresh.
///
/// So Biscuit hands off to the browser, which passes the gate because it is one,
/// and then does the part it is actually good at: checking what came back. The
/// user loses one click and gains a download path that cannot rot.
public struct WindowsDownloadGuide: Sendable {
    public static let pages: [WindowsDownloadPage] = [
        WindowsDownloadPage(
            id: "windows11.x64",
            productName: "Windows 11",
            architecture: .x64,
            path: "software-download/windows11",
            audience: .windowsAudiencePC
        ),
        WindowsDownloadPage(
            id: "windows11.arm64",
            productName: "Windows 11",
            architecture: .arm64,
            path: "software-download/windows11arm64",
            audience: .windowsAudienceARM
        ),
        WindowsDownloadPage(
            id: "windows10.x64",
            productName: "Windows 10",
            architecture: .x64,
            path: "software-download/windows10ISO",
            audience: .windowsAudienceLegacy
        )
    ]

    public init() {}

    public static func page(id: String) -> WindowsDownloadPage? {
        pages.first { $0.id == id }
    }

    /// What to pick on Microsoft's page, so the user is not left guessing.
    ///
    /// The page offers a multi-edition ISO and a language list; nothing else
    /// needs choosing. Said once here rather than repeated across the UI.
    public static var instructions: [StringKey] {
        [.windowsStepEdition, .windowsStepLanguage, .windowsStepDownload, .windowsStepDrop]
    }
}
