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

        let home = app.staticTexts["未在播放"].firstMatch
        let profile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "规则管理"))
            .firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 15), "Expected Music Home on launch")
        sleep(3)
        snap("\(label)-01-cold-home")

        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let app = object as? XCUIApplication else { return false }
            return app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 18), .completed)
        app.activate()
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        sleep(3)
        snap("\(label)-02-resumed-home")

        for pass in 1...2 {
            tapTab("我的", in: app)
            XCTAssertTrue(profile.waitForExistence(timeout: 8))
            sleep(2)
            snap("\(label)-pass\(pass)-profile")
            tapTab("首页", in: app)
            XCTAssertTrue(home.waitForExistence(timeout: 8))
            snap("\(label)-pass\(pass)-home-now")
            sleep(2)
            snap("\(label)-pass\(pass)-home-2sec")
            sleep(4)
            snap("\(label)-pass\(pass)-home-6sec")
        }
        app.terminate()
    }

    private func tapTab(_ title: String, in app: XCUIApplication) {
        let tabBarButton = app.tabBars.buttons[title].firstMatch
        let button = tabBarButton.exists ? tabBarButton : app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing tab: \(title)")
        button.tap()
    }

    private func snap(_ name: String) {
        print("TAB FOREGROUND: \(name)")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
