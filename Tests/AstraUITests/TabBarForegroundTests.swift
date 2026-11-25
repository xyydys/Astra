import XCTest

final class TabBarForegroundTests: XCTestCase {
    func testMusicHomeAWithTopGlass() {
        captureHome(label: "A-top-glass", extraArguments: [])
    }

    func testMusicHomeBWithoutTopGlass() {
        captureHome(label: "B-no-top-glass", extraArguments: ["--astra-ab-hide-music-top-glass"])
    }

    private func captureHome(label: String, extraArguments: [String]) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-contentMode", "music"] + extraArguments
        app.launch()

        sleep(5)
        snap("\(label)-01-cold-home")

        // Use physical tab taps. Avoid accessibility hierarchy queries, which
        // previously stalled this test on the hosted simulator.
        func tap(_ x: CGFloat, _ y: CGFloat) {
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        }

        XCUIDevice.shared.press(.home)
        sleep(2)
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended)
        app.activate()
        sleep(3)
        snap("\(label)-02-resumed-home")
        tap(0.68, 0.948)
        sleep(3)
        snap("\(label)-03-my")
        tap(0.15, 0.948)
        snap("\(label)-04-return")
        sleep(2)
        snap("\(label)-05-return-plus2")
        sleep(4)
        snap("\(label)-06-return-plus6")
        app.terminate()
    }

    private func snap(_ name: String) {
        print("TAB FOREGROUND: \(name)")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
