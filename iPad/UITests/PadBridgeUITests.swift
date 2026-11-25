import XCTest
import Network

final class PadBridgeUITests: XCTestCase {
    @MainActor func testNativePairingReceivesMacFrame() throws {
        let app = XCUIApplication()
        app.launch()
        let code = app.secureTextFields["pairing-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap(); code.typeText("PB2 127.0.0.1 " + String(repeating: "0", count: 64) + " tls://127.0.0.1:9443")
        app.buttons["connect-button"].tap()
        XCTAssertTrue(app.staticTexts["Mode pengujian · bukan layar Mac"].waitForExistence(timeout: 10))
        let frame = app.descendants(matching: .any)["remote-screen"].firstMatch
        expectation(for: NSPredicate(format: "value == %@", "Frame diterima"), evaluatedWith: frame)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native iPad connected to Mac test frame"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let fullScreen = app.buttons["remote-fullscreen"]
        let normalHeight = frame.frame.height
        fullScreen.tap()
        XCTAssertEqual(fullScreen.label, "Keluar layar penuh")
        XCTAssertFalse(app.buttons["Putuskan"].exists)
        XCTAssertGreaterThan(frame.frame.height, normalHeight)

        let keyboardToggle = app.buttons["remote-keyboard"]
        XCTAssertTrue(keyboardToggle.isEnabled, "Start the test host with --test-server --test-keyboard")
        keyboardToggle.tap()
        let field = app.textFields["remote-keyboard-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("abc\u{8}\n")
        XCTAssertEqual(frame.value as? String, "Frame diterima")
        keyboardToggle.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        fullScreen.tap()
        app.buttons["Putuskan"].tap()
        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connect-saved"].exists, "Test-server credentials must not be saved")
    }

    @MainActor func testTriesRelayWhenLocalPairingFails() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Relay fixture listening")
        let attempted = expectation(description: "Viewer opened relay connection")
        var accepted: NWConnection?
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                accepted = connection
                connection.start(queue: .main)
                attempted.fulfill()
            }
        }
        listener.start(queue: .main)
        defer { accepted?.cancel(); listener.cancel() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port).rawValue

        let app = XCUIApplication()
        app.launch()
        let code = app.secureTextFields["pairing-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("PB2 127.0.0.1 " + String(repeating: "a", count: 64) + " tls://127.0.0.1:\(port)")
        app.buttons["connect-button"].tap()
        wait(for: [attempted], timeout: 8)
        app.buttons["Batal"].tap()
        XCTAssertFalse(app.buttons["connect-saved"].exists, "An unauthenticated relay must not save the profile")
    }
}
