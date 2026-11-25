import XCTest

final class TabBarForegroundTests: XCTestCase {
    func testAstraMusicHome() {
        captureFlow(
            label: "Astra",
            arguments: ["-contentMode", "music"],
            homeLabel: "未在播放",
            profileLabel: "规则管理"
        )
    }

    func testStockSwiftUITabView() {
        captureFlow(
            label: "Stock",
            arguments: ["-uiTestScenario", "tabBarForegroundControl"],
            homeLabel: "原生深色首页",
            profileLabel: "原生浅色列表 1"
        )
    }

    private func captureFlow(label: String, arguments: [String], homeLabel: String, profileLabel: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-uiTestDumpBars", "YES", "-uiTestLog", "uitest.log", "-uiTestLabel", label]
        app.launch()

        let home = app.staticTexts[homeLabel].firstMatch
        let profile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", profileLabel))
            .firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 15), "Expected Home on fresh launch")
        sleep(2)
        snap("\(label)-01-cold-home")

        // Don't visit the Profile tab before foregrounding. The report
        // reproduces on direct Home → Profile with no visit to Favorites.
        XCUIDevice.shared.press(.home)
        sleep(2)
        XCTAssertNotEqual(app.state, .runningForeground, "Home did not send Astra to the background")
        app.activate()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "Expected to resume on Home")
        sleep(2)
        snap("\(label)-02-resumed-home")

        tapTab("我的", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 8), "The Profile content did not appear")
        let originalTop = profile.frame.minY
        snap("\(label)-03-profile-before-scroll")
        sleep(2)
        snap("\(label)-04-profile-after-wait")

        // Scroll in the page, not on the tab bar. Return to the top and
        // capture the expanded bar with the original page position.
        app.swipeUp()
        sleep(1)
        snap("\(label)-05-profile-after-up")
        app.swipeDown()
        XCTAssertTrue(profile.waitForExistence(timeout: 8), "The top Profile row did not return")
        sleep(1)
        print("TAB FOREGROUND: \(label) Profile row delta after scroll: \(profile.frame.minY - originalTop)pt")
        snap("\(label)-06-profile-after-down")

        tapTab("首页", in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 8), "Expected to switch back to Home")
        sleep(2)
        snap("\(label)-07-home-after-profile")
        tapTab("搜索", in: app)
        sleep(1)
        snap("\(label)-08-search")
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
