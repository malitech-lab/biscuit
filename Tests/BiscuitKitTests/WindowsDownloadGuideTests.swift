import Foundation
import Testing
@testable import BiscuitKit

@Suite("Windows-Download-Wegweiser")
struct WindowsDownloadGuideTests {
    @Test("Jede Seite hat eine eindeutige Kennung und einen HTTPS-Pfad")
    func pagesAreWellFormed() {
        let pages = WindowsDownloadGuide.pages
        #expect(pages.count >= 3)
        #expect(Set(pages.map(\.id)).count == pages.count, "doppelte Kennung")

        for page in pages {
            let url = page.url()
            #expect(url.scheme == "https", "\(page.id) nicht HTTPS")
            #expect(url.host == "www.microsoft.com", "\(page.id) zeigt nicht auf microsoft.com")
            #expect(!page.productName.isEmpty)
        }
    }

    @Test("Die Locale wird in den Pfad eingesetzt")
    func localeSegment() {
        guard let page = WindowsDownloadGuide.page(id: "windows11.x64") else {
            Issue.record(Comment("Seite fehlt")); return
        }
        #expect(page.url(locale: "de").path == "/de-de/software-download/windows11")
        #expect(page.url(locale: "en").path == "/en-us/software-download/windows11")
    }

    @Test("Eine unbekannte Sprache liefert die Adresse ohne Locale")
    func unknownLocaleFallsBack() {
        // An invented segment would 404; the bare path redirects correctly on
        // its own, so that is the safer fallback.
        guard let page = WindowsDownloadGuide.page(id: "windows11.x64") else {
            Issue.record(Comment("Seite fehlt")); return
        }
        #expect(page.url(locale: "fr").path == "/software-download/windows11")
        #expect(page.url(locale: "zz").path == "/software-download/windows11")
        #expect(page.url().path == "/software-download/windows11")
    }

    @Test("x64 und ARM64 zeigen auf verschiedene Seiten")
    func architecturesDiffer() {
        // Pointing both at the x64 page would hand ARM users a stick that
        // cannot boot their device — and nothing would report it.
        let x64 = WindowsDownloadGuide.page(id: "windows11.x64")
        let arm = WindowsDownloadGuide.page(id: "windows11.arm64")
        #expect(x64?.url() != arm?.url())
        #expect(arm?.architecture == .arm64)
        #expect(x64?.architecture == .x64)
    }

    @Test("Die Anleitung endet damit, die Datei in Biscuit zu ziehen")
    func instructionsEndAtTheDropStep() {
        // The hand-off is only complete when the user comes back, so the last
        // step has to say so.
        #expect(WindowsDownloadGuide.instructions.last == .windowsStepDrop)
        #expect(WindowsDownloadGuide.instructions.count >= 3)
    }

    @Test("Alle verwendeten Schlüssel sind in beiden Sprachen vorhanden")
    func stringsExist() {
        // L10nCompletenessTests covers the enum; this covers the keys this
        // feature actually reaches for.
        var keys = WindowsDownloadGuide.instructions
        keys.append(contentsOf: WindowsDownloadGuide.pages.map(\.audience))
        keys.append(contentsOf: [.windowsWhyNoDownload, .windowsOpenPage, .windowsPageHint])

        for language in ["en", "de"] {
            // Read as a property list, not via `Bundle.localizedString`, which
            // echoes the key back on a miss and would make this always pass.
            guard let url = L10n.resourceBundle.url(
                forResource: "Localizable", withExtension: "strings",
                subdirectory: nil, localization: language
            ),
                let table = try? PropertyListSerialization.propertyList(
                    from: Data(contentsOf: url), options: [], format: nil
                ) as? [String: String]
            else {
                Issue.record(Comment("Keine Localizable.strings für \(language)"))
                return
            }

            for key in keys {
                let value = table[key.rawValue]
                #expect(value != nil, "\(key.rawValue) fehlt in \(language)")
                #expect(value?.isEmpty == false, "\(key.rawValue) ist leer in \(language)")
            }
        }
    }
}

/// Checks Microsoft's pages are still where the guide says they are.
///
/// This is the whole risk of the hand-off design: Biscuit never touches the
/// download API, so the only thing that can break is a moved page. If that
/// happens the user lands on a 404 with no explanation, so it is worth a test
/// that notices.
@Suite("Microsoft-Seiten live", .serialized)
struct WindowsDownloadPageLiveTests {
    @Test("Jede Download-Seite antwortet mit 200", .timeLimit(.minutes(3)))
    func pagesAreReachable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        // Microsoft serves a different body to unrecognised clients; the point
        // here is reachability, so a browser agent keeps the check honest.
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var unreachable: [String] = []
        for page in WindowsDownloadGuide.pages {
            // Locale-decorated, because that is the form the app actually opens.
            let url = page.url(locale: "en")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            do {
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code != 200 { unreachable.append("\(page.id): HTTP \(code)") }
            } catch {
                // An offline runner is not a failure of this code.
                Issue.record(Comment("\(page.id) nicht erreichbar: \(error.localizedDescription)"))
                return
            }
        }
        #expect(unreachable.isEmpty, "Seiten nicht erreichbar: \(unreachable.joined(separator: ", "))")
    }
}
