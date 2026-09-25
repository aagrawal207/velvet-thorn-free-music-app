import CryptoKit
import ImageIO
import StoreKitTest
import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class GanaBajanaStoreScreenshotsUITests: XCTestCase {
    private let hiddenHomeSections = ["madeForYou", "newReleases", "becauseYouLike", "charts", "discovery"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["GANABAJANA_STORE_CAPTURE"] == "1" else {
            throw XCTSkip("Local store captures require GANABAJANA_STORE_CAPTURE=1 in the test runner.")
        }
    }

    func test01SearchLibraryShortcuts() throws {
        let ui = try launchCaptureApp()
        try requireControl(ui.app.buttons["search.library.likes"], in: ui)
        try requireControl(ui.app.buttons["search.library.cached"], in: ui)
        XCTAssertTrue(ui.app.buttons["search.library.likes"].label.contains("0 songs"))
        try requireControl(ui.app.buttons["search.library.open"], in: ui)
        try requireControl(ui.app.buttons["search.radio.open"], in: ui)
        try ui.requireHittable(ui.app.staticTexts["search.recents.empty"])
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.filter.")).firstMatch.exists)
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.library.playlist.")).firstMatch.exists)
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.station.")).firstMatch.exists)
        try capture("01-search", in: ui)
    }

    func test02RadioSetup() throws {
        let ui = try launchCaptureApp()
        try openRadioBrowser(ui)
        try ui.tap(ui.app.buttons["search.station.focus"])
        try ui.requireHittable(ui.app.buttons["radio.setup.cancel"])
        XCTAssertTrue(ui.app.navigationBars["Set up radio"].exists)
        XCTAssertFalse(ui.app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "radio.setup.language.")).firstMatch.exists)
        try ui.requireHittable(ui.element("radio.setup.listeningLanguages"))
        XCTAssertEqual(ui.element("radio.setup.listeningLanguages").label, "Languages follow your listening")
        XCTAssertTrue(ui.app.buttons["radio.setup.era.anytime"].isSelected)
        XCTAssertEqual(ui.element("radio.setup.selectionCount").label, "0 of 4 hints")
        XCTAssertFalse(ui.app.buttons["radio.setup.clearArtists"].isEnabled)
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "radio.setup.artist.")).firstMatch.exists)
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "radio.setup.addArtist.")).firstMatch.exists)
        let start = ui.app.buttons["radio.setup.start"]
        try requireControl(start, in: ui)
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(start.value as? String, "Style defaults")
        try ui.requireHittable(ui.element("radio.setup.selectionCount"))
        try capture("02-radio-setup", in: ui)
    }

    func test03AppIcons() throws {
        let ui = try launchCaptureApp()
        try openMediaFreeSettings(ui)
        let link = ui.app.buttons["settings.appIcon"]
        try ui.reveal(link, maxSwipes: 24)
        try requireControl(link, in: ui)
        try ui.tap(link)
        try ui.requireHittable(ui.app.buttons["settings.icon.Beat"])
        XCTAssertTrue(ui.app.navigationBars["App icon"].exists)
        let icons = [("Beat", "Leafnote"), ("Notes", "Drift"), ("Boombox", "Moonleaf"),
                     ("Speaker", "Ripple"), ("Waves", "Tide"), ("Thorn", "Thorn"), ("Sonnet", "Sonnet")]
        for (id, title) in icons {
            let button = ui.app.buttons["settings.icon.\(id)"]
            try requireControl(button, in: ui)
            XCTAssertEqual(button.label, title)
            XCTAssertEqual(button.isSelected, id == "Beat", "Use a dedicated installation with the primary Leafnote icon.")
        }
        XCTAssertEqual(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.icon.")).count, 7)
        XCTAssertFalse(ui.element("settings.icon.pending").exists)
        XCTAssertFalse(ui.element("settings.icon.error").exists)
        try capture("03-app-icons", in: ui)
    }

    func test04CustomizeHome() throws {
        let ui = try launchCaptureApp()
        try openMediaFreeSettings(ui)
        let customize = ui.app.buttons["settings.customizeHome"]
        try ui.reveal(customize, maxSwipes: 24)
        try ui.tap(customize)
        try ui.expectSwitch("home.customization.show.recentlyPlayed", isOn: true)
        for section in hiddenHomeSections {
            try ui.expectSwitch("home.customization.show.\(section)", isOn: false)
        }
        try ui.reveal(ui.app.switches["home.customization.show.recentlyPlayed"], direction: .down)
        for section in ["recentlyPlayed"] + hiddenHomeSections {
            try requireControl(ui.app.switches["home.customization.show.\(section)"], in: ui)
        }
        XCTAssertTrue(ui.app.navigationBars["Customize Home"].exists)
        let reset = ui.app.buttons["home.customization.reset"]
        try ui.reveal(reset, maxSwipes: 12)
        XCTAssertTrue(reset.isEnabled)
        try ui.reveal(ui.app.switches["home.customization.show.recentlyPlayed"], direction: .down, maxSwipes: 12)
        try capture("04-customize-home", in: ui)
    }

    func test05ICloudStatus() throws {
        let ui = try launchCaptureApp()
        try openMediaFreeSettings(ui)
        let link = ui.app.buttons["settings.icloud"]
        try ui.reveal(link)
        try requireControl(link, in: ui)
        try ui.tap(link)
        try ui.expectSwitch("settings.icloud.enabled", isOn: true)
        XCTAssertTrue(ui.app.navigationBars["iCloud sync"].exists)
        XCTAssertEqual(ui.element("settings.icloud.status").label, "Waiting to sync with iCloud")
        XCTAssertFalse(ui.element("settings.icloud.lastSaved").exists)
        XCTAssertFalse(ui.element("settings.icloud.error").exists)
        let deliveryNote = ui.element("settings.icloud.deliveryNote")
        try ui.reveal(deliveryNote)
        XCTAssertTrue(deliveryNote.label.contains("does not confirm upload or delivery"))
        try requireControl(ui.app.switches["settings.icloud.enabled"], in: ui)
        try requireControl(ui.app.buttons["settings.icloud.syncNow"], in: ui)
        try capture("05-icloud-waiting", in: ui)
    }

    func test06EmptyLibrary() throws {
        let ui = try launchCaptureApp()
        try selectTab("library", in: ui)
        try ui.requireHittable(ui.app.buttons["library.likes"])
        let empty = ui.element("library.playlists.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertTrue(ui.app.staticTexts["Your library"].exists)
        XCTAssertTrue(empty.staticTexts["A place for your next mix"].exists)
        XCTAssertTrue(ui.app.staticTexts["Keep a little of what you love."].exists)
        XCTAssertFalse(ui.app.buttons["library.recents.all"].exists)
        try requireControl(empty.buttons["library.playlists.createFirst"], in: ui)
        try capture("06-empty-library", in: ui)
    }

    func test10CoreListeningScreens() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_STORE_LIVE_CAPTURE"] == "1" else {
            throw XCTSkip("Populated captures require GANABAJANA_STORE_LIVE_CAPTURE=1 and live providers.")
        }
        let ui = try launchCaptureApp()
        let songs = [("No Surprises", "Radiohead"), ("Dreams", "Fleetwood Mac"),
                     ("Yellow", "Coldplay"), ("Sunset Lover", "Petit Biscuit"),
                     ("Kesariya", "Arijit Singh"), ("Tum Hi Ho", "Arijit Singh")]
        var playedIDs: [String] = []
        for (title, artist) in songs {
            try searchLiveCapture("\(title) \(artist)", in: ui)
            let candidates = ui.app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[cd] %@ AND label CONTAINS[cd] %@",
                "track.play.", title, artist))
            try ui.wait("The live catalog must return the requested song and artist", timeout: 90) { candidates.firstMatch.exists }
            let row = candidates.firstMatch
            try ui.reveal(row)
            let id = String(row.identifier.dropFirst("track.play.".count))
            XCTAssertFalse(id.hasPrefix("fixture."))
            try ui.tap(row)
            try openListeningPlayer(in: ui)
            try ui.expectCurrentTrack(id)
            try waitForLiveCapturePlayback(in: ui)
            let like = ui.app.buttons["player.like"]
            if !like.isSelected { try ui.tap(like) }
            XCTAssertTrue(like.isSelected)
            // Real elapsed playback, without seeks or injected events, supplies the recap and mixes.
            try ui.waitForAdvance(from: 0, by: 55, timeout: 100)
            playedIDs.append(id)
            if title != songs.last?.0 { try ui.closePlayer() }
        }

        try captureListeningPages(in: ui, recordingIDs: playedIDs)
    }

    func test11ResumeCoreListeningScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GANABAJANA_STORE_LIVE_CAPTURE"] == "1",
              let store = environment["GANABAJANA_STORE_RESUME"], store.hasPrefix("store-capture-"),
              let recordings = environment["GANABAJANA_STORE_RECORDINGS"] else {
            throw XCTSkip("Resume requires the original capture store and its observed recording IDs.")
        }
        let ui = AppUITestDriver(testCase: self, prefix: "store-capture-resume")
        addTeardownBlock { await ui.finish() }
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                  "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": store]
        ui.app.launch()
        try selectTab("library", in: ui)
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.wait("The original six liked songs must have survived the interrupted capture") {
            ui.element("library.likes.count").label == "6 songs"
        }
        try openListeningPlayer(in: ui)
        let ids = recordings.split(separator: ",").map(String.init)
        XCTAssertEqual(ids.count, 6)
        try ui.expectCurrentTrack(try XCTUnwrap(ids.last))
        XCTAssertEqual(ui.app.buttons["player.playPause"].label, "Play")
        try captureListeningPages(in: ui, recordingIDs: ids)
    }

    private func openListeningPlayer(in ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["miniPlayer.open"])
        try ui.requireHittable(ui.app.buttons["player.close"])
        try ui.requireHittable(ui.app.buttons["player.playPause"])
        try ui.requireHittable(ui.element("player.elapsed"))
    }

    private func captureListeningPages(in ui: AppUITestDriver, recordingIDs playedIDs: [String]) throws {
        if ui.app.buttons["player.playPause"].label == "Pause" { try ui.tap(ui.app.buttons["player.playPause"]) }
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try captureListeningScreen("02-player", in: ui, recordingIDs: playedIDs)
        try ui.tap(ui.app.buttons["player.browse"])
        try ui.tap(ui.app.buttons["player.browse.album"])
        try ui.wait("The album must finish opening", timeout: 60) {
            !ui.app.buttons["player.close"].exists && ui.app.staticTexts["ALBUM"].exists
                && ui.app.buttons["collection.play"].exists
                && ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play.")).count >= 3
        }
        try captureListeningScreen("03-album", in: ui, recordingIDs: playedIDs)

        try openListeningPlayer(in: ui)
        try ui.tap(ui.app.buttons["player.artistName"])
        let artistTitle = ui.app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "collection.title", "Arijit Singh")).firstMatch
        try ui.wait("The real artist page must finish opening", timeout: 90) {
            ui.app.buttons["collection.follow"].firstMatch.exists && artistTitle.exists && artistTitle.isHittable
                && ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play.")).count >= 3
        }
        try captureListeningScreen("04-artist", in: ui, recordingIDs: playedIDs)

        try selectTab("home", in: ui)
        try ui.wait("Home must show the actual recent listens and generated mixes", timeout: 120) {
            ui.element("home.group.recentlyPlayed").exists && ui.element("home.group.madeForYou").exists
        }
        try captureListeningScreen("01-home", in: ui, recordingIDs: playedIDs)

        try selectTab("recap", in: ui)
        try ui.requireHittable(ui.element("recap.totalListening"))
        XCTAssertTrue(ui.element("recap.topArtist").exists)
        try captureListeningScreen("05-recap", in: ui, recordingIDs: playedIDs)

        try selectTab("library", in: ui)
        try selectTab("library", in: ui)
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.wait("Liked songs must contain the six real selections") {
            ui.element("library.likes.count").exists && ui.element("library.likes.count").label == "6 songs"
        }
        try captureListeningScreen("06-liked-songs", in: ui, recordingIDs: playedIDs)
    }

    private func searchLiveCapture(_ query: String, in ui: AppUITestDriver) throws {
        try selectTab("search", in: ui)
        let field = ui.app.textFields["search.field"]
        try ui.requireHittable(field)
        if ui.app.buttons["search.clear"].exists { try ui.tap(ui.app.buttons["search.clear"]) }
        try ui.tap(field)
        try ui.dismissKeyboardIntroduction()
        field.typeText(query)
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try ui.wait("The keyboard must close before choosing a live song") { !ui.app.keyboards.firstMatch.exists }
    }

    private func waitForLiveCapturePlayback(in ui: AppUITestDriver) throws {
        let retry = ui.app.buttons["player.retry"]
        try ui.wait("Playback must advance or expose a retry", timeout: 100) {
            retry.exists || (ui.positionIfVisible() ?? 0) >= 3
        }
        if retry.exists { try ui.tap(retry) }
        try ui.waitForAdvance(from: 0, by: 3, timeout: 100)
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(ui.app.buttons["player.playPause"].label, "Pause")
    }

    private func captureListeningScreen(_ name: String, in ui: AppUITestDriver, recordingIDs: [String]) throws {
        try ui.wait("A store image needs settled content without a keyboard, alert or error banner", timeout: 30) {
            ui.app.state == .runningForeground && !ui.app.keyboards.firstMatch.exists
                && !ui.app.alerts.firstMatch.exists && !ui.element("message.text").exists
                && !ui.app.buttons["player.retry"].exists
        }
        Thread.sleep(forTimeInterval: 3)
        let device = try deviceSpecification()
        let screenshot = XCUIScreen.main.screenshot()
        let raw = screenshot.pngRepresentation
        let source = try XCTUnwrap(CGImageSourceCreateWithData(raw as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int(device.pixels.width))
        XCTAssertEqual(image.height, Int(device.pixels.height))
        let basename = "\(name)-en-US-\(device.name)"
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = basename
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["GANABAJANA_STORE_OUTPUT"])
        let root = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(device.name, isDirectory: true)
        for directory in ["raw", "final", "metadata"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let rawURL = root.appendingPathComponent("raw/\(basename).png")
        let finalURL = root.appendingPathComponent("final/\(basename).png")
        guard !FileManager.default.fileExists(atPath: finalURL.path) else {
            throw AppUIWorkflowFailure(message: "Use a fresh capture directory; an existing image must not be overwritten.")
        }
        try raw.write(to: rawURL, options: .atomic)
        let opaque = try opaqueCapture(image)
        let final = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(final, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, opaque, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = final as Data
        try bytes.write(to: finalURL, options: .atomic)
        let infoPath = try XCTUnwrap(environment["GANABAJANA_STORE_APP_INFO"])
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: infoPath)), format: nil) as? [String: Any])
        let metadata: [String: Any] = [
            "file": finalURL.lastPathComponent, "screen": name, "width": image.width, "height": image.height,
            "md5": Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "rawSHA256": SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
            "capturedAt": ISO8601DateFormatter().string(from: Date()), "device": device.name,
            "simulatorUDID": environment["SIMULATOR_UDID"] ?? "Unavailable", "osVersion": UIDevice.current.systemVersion,
            "version": info["CFBundleShortVersionString"] ?? "Unavailable", "build": info["CFBundleVersion"] ?? "Unavailable",
            "sourceState": "Post-build-5 working tree including R10 artwork backgrounds and song deduplication, and the R11 container-free transport with the progress-to-heart trail",
            "appearance": "dark", "locale": "en-US", "store": ui.app.launchEnvironment["GANABAJANA_TEST_STORE"] ?? ui.storeName,
            "recordingIDs": recordingIDs,
            "launchArguments": ui.app.launchArguments, "contentSource": "Live providers; actual selections and elapsed playback; no seeded history",
            "conversion": "Opaque PNG; original dimensions, pixel samples and color space"
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("metadata/\(basename).json"), options: .atomic)
    }

    private func opaqueCapture(_ image: CGImage) throws -> CGImage {
        let replacement: CGImageAlphaInfo
        let logicalAlphaByte: Int
        switch image.alphaInfo {
        case .premultipliedFirst, .first: replacement = .noneSkipFirst; logicalAlphaByte = 0
        case .premultipliedLast, .last: replacement = .noneSkipLast; logicalAlphaByte = 3
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: throw AppUIWorkflowFailure(message: "Unsupported capture alpha format.")
        }
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 32)
        let provider = try XCTUnwrap(image.dataProvider)
        let samples = try XCTUnwrap(provider.data) as Data
        let littleEndian = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let alphaByte = littleEndian ? 3 - logicalAlphaByte : logicalAlphaByte
        for y in 0..<image.height {
            for x in 0..<image.width where samples[y * image.bytesPerRow + x * 4 + alphaByte] != 255 {
                throw AppUIWorkflowFailure(message: "The native screenshot contains transparency.")
            }
        }
        // Reinterpret only opaque alpha samples; retain the exact RGB samples and source color space.
        let bitmapInfo = CGBitmapInfo(rawValue: (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | replacement.rawValue)
        return try XCTUnwrap(CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: try XCTUnwrap(image.colorSpace),
            bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent))
    }

    func test90NativeTipProducts() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_STORE_IAP_CAPTURE"] == "1" else {
            throw XCTSkip("Native product review capture also requires GANABAJANA_STORE_IAP_CAPTURE=1.")
        }
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TipJar", withExtension: "storekit"))
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: configuration)
        } catch {
            throw XCTSkip("Native StoreKit session unavailable: \(error). Check the SDK/runtime pairing or use Xcode Run with TipJar.storekit.")
        }
        session.resetToDefaultState()
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")
        defer { session.resetToDefaultState() }

        let ui = try launchCaptureApp()
        try openMediaFreeSettings(ui)
        let link = ui.app.buttons["settings.tipJar"]
        try ui.reveal(link, maxSwipes: 24)
        try ui.tap(link)
        try ui.wait("Native StoreKit must load products or report its error", timeout: 45) {
            ui.app.buttons["com.agraabhi.ganabajana.tip.small"].exists || ui.element("tipJar.loadError").exists
        }
        if ui.element("tipJar.loadError").exists {
            throw XCTSkip("No complete native product capture: \(ui.element("tipJar.loadError").label). No prices were substituted.")
        }
        let products = [("small", "Small tip"), ("medium", "Generous tip"), ("large", "Big tip"),
                        ("grand", "Grand tip"), ("patron", "Patron tip")]
        let rows = products.map { ui.app.buttons["com.agraabhi.ganabajana.tip.\($0.0)"] }
        var observedLabels: [String] = []
        for ((_, name), row) in zip(products, rows) {
            try ui.reveal(row, maxSwipes: 12)
            try requireControl(row, in: ui)
            XCTAssertTrue(row.isEnabled)
            let text = ui.accessibleText(row)
            XCTAssertTrue(text.contains(name))
            XCTAssertNotNil(text.range(of: #"\$\s*[0-9]+(?:[.,][0-9]{2})?"#, options: .regularExpression),
                            "The USA StoreKit product row must expose its actual localized price.")
            observedLabels.append(text)
        }
        XCTAssertFalse(ui.element("tipJar.count").exists)
        XCTAssertFalse(ui.element("tipJar.pending").exists)
        XCTAssertFalse(ui.element("tipJar.loading").exists)
        let explanation = ui.element("tipJar.explanation")
        try ui.reveal(explanation, direction: .down, maxSwipes: 12)
        XCTAssertTrue(explanation.label.contains("unlock no features or music"))
        try capture("90-iap-native-products", in: ui)
        let viewport = try ui.scrollable().frame.intersection(ui.app.windows.firstMatch.frame)
        if rows.contains(where: { !isFullyVisible($0, within: viewport) }) {
            try ui.reveal(try XCTUnwrap(rows.last))
            try capture("91-iap-native-products-lower", in: ui)
        }
        ui.note("iap-native-product-labels", observedLabels.joined(separator: "\n"))
    }

    private func launchCaptureApp() throws -> AppUITestDriver {
        _ = try deviceSpecification()
        let ui = AppUITestDriver(testCase: self, prefix: "store-capture")
        addTeardownBlock { await ui.finish() }
        XCUIDevice.shared.orientation = .portrait
        // The shared launcher waits for a bottom Home tab; iPad uses top-level tab buttons.
        // Omitting --seed-ui retains the production providers and an empty, isolated library.
        ui.app.launchArguments = ["--uitesting", "--skip-welcome", "--reset-ui",
                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                  "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        XCTAssertFalse(ui.app.launchArguments.contains("--seed-ui"), "Store drafts must show the unseeded product rather than fixture marketing content")
        ui.app.launch()
        try selectTab("search", in: ui)
        try ui.requireHittable(ui.app.textFields["search.field"], timeout: 25)
        if ui.app.buttons["search.dismissKeyboard"].exists {
            try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        }
        try ui.wait("The empty Search launch must settle without a keyboard") { !ui.app.keyboards.firstMatch.exists }
        XCTAssertFalse(ui.app.buttons["search.clear"].exists)
        XCTAssertFalse(ui.app.buttons["search.recents.clear"].exists)
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        XCTAssertFalse(ui.app.buttons["miniPlayer.open"].exists)
        let expected = try deviceSpecification()
        try ui.wait("The coordinator's destination must be full-screen portrait") {
            let frame = ui.app.windows.firstMatch.frame
            return abs(frame.width - expected.points.width) < 1 && abs(frame.height - expected.points.height) < 1
        }
        return ui
    }

    private func selectTab(_ name: String, in ui: AppUITestDriver) throws {
        let direct = ui.app.buttons["tab.\(name)"].firstMatch
        let bottom = ui.app.tabBars.buttons[name.capitalized].firstMatch
        try ui.wait("The \(name) tab must be available on this device") { direct.exists || bottom.exists }
        try ui.tap(direct.exists && direct.isHittable ? direct : bottom)
    }

    private func openRadioBrowser(_ ui: AppUITestDriver) throws {
        let radio = ui.app.buttons["search.radio.open"]
        try ui.reveal(radio)
        try requireControl(radio, in: ui)
        try ui.tap(radio)
        try ui.wait("Radio browsing must open through the Search navigation link") {
            ui.app.navigationBars["Radio"].exists && ui.element("search.radio.content").exists
        }
        try ui.requireHittable(ui.element("search.radio.header"))
        try ui.requireHittable(ui.element("search.radio.group.moods"))
        let focus = ui.app.buttons["search.station.focus"]
        try ui.reveal(focus)
        try requireControl(focus, in: ui)
    }

    private func prepareMediaFreeHome(_ ui: AppUITestDriver) throws {
        try selectTab("home", in: ui)
        try ui.requireHittable(ui.app.buttons["home.settings"])
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        let customize = ui.app.buttons["settings.customizeHome"]
        try ui.reveal(customize, maxSwipes: 24)
        try ui.tap(customize)
        // Home remains visible behind iPad sheets; hidden shelves keep later captures free of media.
        for section in hiddenHomeSections {
            try ui.setSwitch("home.customization.show.\(section)", to: false)
        }
        try ui.expectSwitch("home.customization.show.recentlyPlayed", isOn: true)
        try ui.tap(ui.app.navigationBars["Customize Home"].buttons.firstMatch)
        try ui.requireHittable(ui.app.buttons["settings.done"])
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])
        try ui.wait("Only the real empty Home should remain behind Settings") {
            ui.app.staticTexts["Nothing here yet"].exists
                && !ui.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.group.")).firstMatch.exists
        }
    }

    private func openMediaFreeSettings(_ ui: AppUITestDriver) throws {
        try prepareMediaFreeHome(ui)
        try requireControl(ui.app.buttons["home.settings"], in: ui)
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
    }

    private func requireControl(_ element: XCUIElement, in ui: AppUITestDriver,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, file: file, line: line)
    }

    private func isFullyVisible(_ element: XCUIElement, within viewport: CGRect) -> Bool {
        element.exists && !element.frame.isEmpty && viewport.contains(element.frame) && element.isHittable
    }

    private func deviceSpecification() throws -> (name: String, pixels: CGSize, points: CGSize) {
        switch ProcessInfo.processInfo.environment["GANABAJANA_STORE_DEVICE"] {
        case "iphone17promax": return ("iphone17promax", CGSize(width: 1320, height: 2868), CGSize(width: 440, height: 956))
        case "ipadpro13": return ("ipadpro13", CGSize(width: 2064, height: 2752), CGSize(width: 1032, height: 1376))
        default: throw AppUIWorkflowFailure(message: "Set GANABAJANA_STORE_DEVICE to iphone17promax or ipadpro13 and supply the matching destination.")
        }
    }

    private func capture(_ name: String, in ui: AppUITestDriver) throws {
        try ui.wait("Capture requires the settled app without keyboard, alert or message banner") {
            ui.app.state == .runningForeground && !ui.app.keyboards.firstMatch.exists
                && !ui.app.alerts.firstMatch.exists && !ui.element("message.text").exists
        }
        let forbiddenPrefixes = ["track.", "collection.", "miniPlayer.", "player.", "lyrics.", "home.group.",
                                 "search.featuredArtist", "search.recent.", "radio.setup.artist.", "radio.setup.addArtist.",
                                 "signin.", "settings.youtubeStatus", "settings.youtubeError"]
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: forbiddenPrefixes.map {
            NSPredicate(format: "identifier BEGINSWITH %@", $0)
        })
        for element in ui.app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex {
            let frame = element.frame
            if !frame.isEmpty, frame.intersects(ui.app.windows.firstMatch.frame), element.isHittable {
                throw AppUIWorkflowFailure(message: "Unexpected media or account UI in capture: \(element.identifier)")
            }
        }
        let device = try deviceSpecification()
        let screenshot = XCUIScreen.main.screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage)
        guard image.width == Int(device.pixels.width), image.height == Int(device.pixels.height) else {
            throw AppUIWorkflowFailure(message: "Wrong native capture size \(image.width)x\(image.height) for \(device.name). Supply the matching portrait destination; do not resize.")
        }
        let basename = "\(name)-en-US-\(device.name)"
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = basename
        attachment.lifetime = .keepAlways
        add(attachment)
        ui.note("provenance-\(basename)", """
        Raw, unframed app screenshot. Local draft for Breezy, App Store record 6815025307.
        Requested device: \(device.name); pixels: \(image.width)x\(image.height); OS: \(UIDevice.current.systemVersion).
        Locale: en-US; portrait; app default dark appearance; standard text size.
        App version/build must be verified by the coordinator against the compiled app used for this capture.
        Isolated store: \(ui.storeName). Launch arguments: \(ui.app.launchArguments).
        Real catalog providers; no seeded media/history. Native iCloud activation is disabled by the UI-test host.
        """)
    }
}
