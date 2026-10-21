import XCTest

/// 在模拟器里复现问题用的 UI 测试：截图存进测试结果，CI 再导出来看。
/// 结论都打印成 `UITEST` 开头的行，方便在日志里找。
final class AstraUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(_ arguments: [String], label: String = "-") -> XCUIApplication {
        let app = XCUIApplication()
        // 应用的标准输出（SwiftUI 的 _printChanges）写进模拟器里的文件，CI 取出来
        app.launchArguments = arguments + ["-uiTestLog", "uitest.log", "-uiTestLabel", label]
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        print("UITEST [snap] \(name) \(String(format: "%.1f", Date().timeIntervalSince1970))")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func log(_ text: String) {
        print("UITEST \(text)")
    }

    // MARK: 阅读设置的分段控件能不能切换

    private let segmentTitles = ["仿真", "平移", "滚动", "窄", "中", "宽", "紧凑", "适中", "宽松", "苹方", "宋体", "楷体"]

    private func selectedSegments(_ app: XCUIApplication) -> String {
        segmentTitles.filter { title in
            let button = app.buttons[title].firstMatch
            return button.exists && button.isSelected
        }
        .joined(separator: ",")
    }

    /// 测试场景里的计数：coverContent 是阅读器被外层重新创建的次数，正常只有个位数
    private func counters(_ app: XCUIApplication) -> String {
        let element = app.staticTexts["probe-all"].firstMatch
        return element.exists ? element.label : "-"
    }

    /// 打开设置后先看两秒内阅读器有没有在不停重建，再依次点三个和默认值不同的分段
    private func exercise(_ app: XCUIApplication, label: String) {
        log("[\(label)] 打开时：\(selectedSegments(app))  \(counters(app))")
        sleep(2)
        log("[\(label)] 两秒后：\(counters(app))")
        for title in ["平移", "宽", "紧凑"] {
            let button = app.buttons[title].firstMatch
            guard button.waitForExistence(timeout: 3) else {
                log("[\(label)] 找不到「\(title)」")
                continue
            }
            button.tap()
            sleep(1)
            log("[\(label)] 点「\(title)」后：\(selectedSegments(app))  \(counters(app))")
        }
        snap("\(label)-after")
    }

    private func openFromMenu(_ app: XCUIApplication) -> Bool {
        sleep(4)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        let settings = app.buttons["设置"].firstMatch
        guard settings.waitForExistence(timeout: 5) else { return false }
        settings.tap()
        sleep(2)
        return true
    }

    func testReaderSettings() {
        let cases: [(label: String, arguments: [String], viaMenu: Bool)] = [
            ("base", ["-uiTestScenario", "reader"], true),
            ("inline", ["-uiTestScenario", "readerInline"], true),
        ]
        for item in cases {
            let app = launch(item.arguments, label: item.label)
            if item.viaMenu {
                guard openFromMenu(app) else {
                    log("[\(item.label)] 打不开设置")
                    snap("\(item.label)-failed")
                    app.terminate()
                    continue
                }
            } else {
                sleep(5)
            }
            exercise(app, label: item.label)
            app.terminate()
        }
        // 真实路径：小说详情页点「开始阅读」打开阅读器
        let detail = launch(["-uiTestScenario", "novelDetailMid"], label: "fromDetail")
        sleep(4)
        let start = detail.buttons["开始阅读"].firstMatch
        if start.waitForExistence(timeout: 5) {
            start.tap()
            if openFromMenu(detail) {
                exercise(detail, label: "fromDetail")
            } else {
                log("[fromDetail] 打不开设置")
                snap("fromDetail-failed")
            }
        } else {
            log("[fromDetail] 找不到「开始阅读」")
            snap("fromDetail-failed")
        }
        detail.terminate()

        let app = launch(["-uiTestScenario", "settingsSheet"], label: "plainSheet")
        sleep(2)
        app.buttons["打开设置"].firstMatch.tap()
        sleep(2)
        exercise(app, label: "plainSheet")
        app.terminate()
    }

    // MARK: 底栏玻璃：小说详情（中等深度的封面色）推入、返回、切标签；音乐页切标签

    private func tapTab(_ app: XCUIApplication, _ title: String) {
        let button = app.tabBars.buttons[title].firstMatch
        if button.exists { button.tap() } else { app.buttons[title].firstMatch.tap() }
    }

    func testBarSchemeFlow() {
        let app = launch(["-uiTestScenario", "novelDetailMid", "-uiTestDumpBars", "YES"], label: "bars-novel")
        sleep(4)
        snap("novel-1-detail")
        app.swipeUp()
        sleep(2)
        snap("novel-1b-scrolled")
        app.swipeDown()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)
        snap("novel-2-root")
        app.buttons["打开详情"].firstMatch.tap()
        sleep(2)
        snap("novel-3-detail-again")
        tapTab(app, "收藏")
        sleep(2)
        snap("novel-4-favorites")
        tapTab(app, "首页")
        sleep(2)
        snap("novel-5-home-again")
        app.terminate()

        let music = launch(["-contentMode", "music", "-uiTestDumpBars", "YES"], label: "bars-music")
        sleep(5)
        snap("music-1-home")
        tapTab(music, "收藏")
        sleep(2)
        snap("music-2-favorites")
        tapTab(music, "首页")
        sleep(2)
        snap("music-3-home-again")
        music.terminate()
    }

    // MARK: 从别的模式切到音乐（和真机上的用法一样），底栏玻璃有没有跟着变

    private func switchMode(_ app: XCUIApplication, to title: String) {
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "切换内容")).firstMatch
        guard menu.waitForExistence(timeout: 8) else {
            log("[mode] 找不到切换内容按钮")
            return
        }
        menu.tap()
        sleep(1)
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        if item.waitForExistence(timeout: 3) {
            item.tap()
        } else {
            log("[mode] 菜单里找不到「\(title)」：\(app.buttons.allElementsBoundByIndex.prefix(30).map(\.label))")
        }
    }

    func testMusicModeSwitch() {
        // 不用 -contentMode 启动参数：参数域的值优先，菜单切换写进去的值会读不到
        let app = launch(["-uiTestDumpBars", "YES"], label: "mode")
        sleep(6)
        snap("mode-1-start")
        switchMode(app, to: "音乐")
        sleep(4)
        snap("mode-2-music")
        tapTab(app, "收藏")
        sleep(2)
        snap("mode-3-favorites")
        tapTab(app, "首页")
        sleep(2)
        snap("mode-4-music-again")
        switchMode(app, to: "番剧")
        sleep(4)
        snap("mode-5-back")
        app.terminate()
    }
}
