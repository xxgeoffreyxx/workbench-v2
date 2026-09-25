
import XCTest

final class macaiUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}

/// Drives the real app: new chat, model picker, project picker, a round trip to the local router.
/// Drives the real app through every Workbench feature. Needs the router on :8110 and the fixture folder that
/// Scripts/uitest.sh creates at build/uitest-project.
final class WorkbenchUITests: XCTestCase {
    var app: XCUIApplication!
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/uitest-project").path

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-WorkbenchTestProjectFolder", Self.fixture]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "main window never appeared")
    }

    func dump(_ name: String) {
        print("=== UI TREE \(name) ===\n\(app.debugDescription)\n=== END UI TREE ===")
    }

    func newChat() {
        app.buttons["New Thread"].firstMatch.click()
        XCTAssertTrue(app.popUpButtons["Ornith (Helga)"].waitForExistence(timeout: 10), "new chat should default to Helga")
    }

    func send(_ text: String) {
        let input = app.textViews.matching(NSPredicate(format: "value == '' OR value == nil")).firstMatch.exists
            ? app.textViews.allElementsBoundByIndex.last! : app.textViews.firstMatch
        input.click()
        input.typeText(text)
        // Return, as a person would; it also exercises the "/" popup handing Return back when a skill is complete.
        input.typeKey(.return, modifierFlags: [])
    }

    /// Waits for any text on screen containing `needle` (replies render as static text or text views).
    @discardableResult
    func waitForText(_ needle: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", needle, needle)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts.containing(predicate).firstMatch.exists || app.textViews.containing(predicate).firstMatch.exists {
                return true
            }
            sleep(1)
        }
        return false
    }

    func useTestProject() {
        app.popUpButtons["No project"].click()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'UITest Project'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "test project missing from the project dropdown")
        item.click()
        XCTAssertTrue(app.popUpButtons["UITest Project"].waitForExistence(timeout: 5), "project didn't stick")
    }

    func testExploreNewChat() throws {
        app.buttons["New Thread"].firstMatch.click()
        sleep(2)
        dump("newchat")
    }

    func testModelDropdown() throws {
        newChat()
        app.popUpButtons["Ornith (Helga)"].click()
        XCTAssertTrue(app.menuItems["Ornith (Helga)"].waitForExistence(timeout: 5), "router model missing from dropdown")
        let qwen = app.menuItems["qwen-plus"]
        XCTAssertTrue(qwen.exists, "DashScope models missing from dropdown")
        qwen.click()
        XCTAssertTrue(app.popUpButtons["qwen-plus"].waitForExistence(timeout: 5), "picking a DashScope model didn't stick")
    }

    func testProjectDropdown() throws {
        newChat()
        useTestProject()
    }

    func testHelgaReplies() throws {
        newChat()
        send("What is six times seven? Answer with only the number, in digits.")
        XCTAssertTrue(waitForText("42", timeout: 180), "no reply from Helga")
    }

    /// Switching provider and back must rebuild the chat's sender each time (this was broken).
    func testSwitchProviderThenReply() throws {
        newChat()
        app.popUpButtons["Ornith (Helga)"].click()
        app.menuItems["qwen-plus"].click()
        app.popUpButtons["qwen-plus"].click()
        app.menuItems["Ornith (Helga)"].click()
        send("What is six times seven? Answer with only the number, in digits.")
        XCTAssertTrue(waitForText("42", timeout: 180), "no reply from Helga after switching providers")
    }

    func testDashScopeReplies() throws {
        newChat()
        app.popUpButtons["Ornith (Helga)"].click()
        app.menuItems["qwen-plus"].click()
        send("What is six times seven? Answer with only the number, in digits.")
        // A good key answers 42; the key on this Mac is currently rejected, and then the error must be visible.
        let deadline = Date().addingTimeInterval(90)
        var answered = false, rejected = false
        while Date() < deadline && !answered && !rejected {
            answered = waitForText("42", timeout: 1)
            rejected = waitForText("Authentication Error", timeout: 1) || waitForText("Invalid API key", timeout: 1)
        }
        XCTAssertTrue(answered || rejected, "DashScope neither answered nor showed an error")
        if rejected { print("NOTE: DashScope rejected the API key; the app showed the error.") }
    }

    /// Helga reads a file in the project folder through wb_read_file (reads need no approval).
    func testProjectFileTool() throws {
        newChat()
        useTestProject()
        send("Use the wb_read_file tool to read README.md, then tell me the secret word in capitals.")
        let ok = waitForText("MARMALADE", timeout: 240)
        if !ok { dump("filetool") }
        XCTAssertTrue(ok, "Helga didn't read README.md through the project tools")
    }

    /// A project skill runs a command: the approval sheet appears, approving it runs the command.
    func testSkillWithApproval() throws {
        newChat()
        useTestProject()
        send("/wb-echo")
        let approve = app.buttons["Approve"]
        let asked = approve.waitForExistence(timeout: 240)
        if !asked { dump("skill") }
        XCTAssertTrue(asked, "the skill's command never asked for approval")
        XCTAssertTrue(waitForText("echo SKILL_OK", timeout: 5), "approval sheet doesn't show the command")
        approve.click()
        let ok = waitForText("SKILL_OK_42", timeout: 240)
        if !ok { dump("skill-after") }
        XCTAssertTrue(ok, "command output never came back")
    }

    /// Denying a command leaves nothing running and the chat usable.
    func testSkillDenied() throws {
        newChat()
        useTestProject()
        send("/wb-echo")
        let deny = app.buttons["Deny"]
        let asked = deny.waitForExistence(timeout: 240)
        if !asked { dump("deny") }
        XCTAssertTrue(asked, "no approval sheet")
        deny.click()
        XCTAssertFalse(waitForText("SKILL_OK_42", timeout: 60), "a denied command still ran")
    }

    /// Typing "/" lists the project's skills in the popup; picking one fills in the command.
    func testSkillInSlashPopup() throws {
        newChat()
        useTestProject()
        let input = app.textViews.allElementsBoundByIndex.last!
        input.click()
        input.typeText("/wb")
        let row = app.staticTexts["/wb-echo"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "skill missing from the / popup")
        row.click()
        XCTAssertTrue(waitForText("/wb-echo ", timeout: 3), "picking the skill didn't fill in the command")
    }

    func testReadAloud() throws {
        newChat()
        send("What is six times seven? Answer with only the number, in digits.")
        XCTAssertTrue(waitForText("42", timeout: 180))
        // Reply actions appear on hover.
        // Hover the reply: the lowest PONG text in the chat area that isn't the prompt itself.
        let replies = (app.staticTexts.matching(NSPredicate(format: "value CONTAINS '42'")).allElementsBoundByIndex
            + app.textViews.matching(NSPredicate(format: "value CONTAINS '42'")).allElementsBoundByIndex)
            .filter { $0.frame.minX > 900 && !((($0.value as? String) ?? "").contains("six times")) }
        print("REPLY CANDIDATES: \(replies.map { "\($0.elementType.rawValue)@\($0.frame)" })")
        replies.max { $0.frame.minY < $1.frame.minY }?.hover()
        let speak = app.buttons["Read aloud"].firstMatch
        if !speak.waitForExistence(timeout: 5) {
            print("HOVER BUTTONS: " + app.buttons.allElementsBoundByIndex.filter { $0.frame.minX > 1300 }.map { "\($0.label)|\($0.identifier)" }.joined(separator: ", "))
        }
        XCTAssertTrue(speak.exists, "no Read aloud button on the reply")
        speak.click()
        XCTAssertTrue(app.buttons["Stop reading"].firstMatch.waitForExistence(timeout: 5), "reading didn't start")
        app.buttons["Stop reading"].firstMatch.click()
    }

    func testComposerButtons() throws {
        newChat()
        XCTAssertTrue(app.buttons["Dictation"].exists)
        XCTAssertTrue(app.buttons["Screenshot"].exists)
    }

    func testInspector() throws {
        newChat()
        useTestProject()
        let settingsTab = app.radioButtons["Chat settings"]
        if !settingsTab.exists { app.buttons["Show or hide the inspector"].firstMatch.click() }
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "inspector didn't open")
        settingsTab.click()
        XCTAssertTrue(app.staticTexts["System prompt"].waitForExistence(timeout: 5), "inspector settings tab empty")
        app.radioButtons["Project folder and skills"].click()
        XCTAssertTrue(app.staticTexts["Project folder"].waitForExistence(timeout: 5), "inspector project tab empty")
        XCTAssertTrue(waitForText("/wb-echo", timeout: 5), "project skill not listed in the inspector")
        app.radioButtons["Model and router status"].click()
        XCTAssertTrue(waitForText("Online", timeout: 20), "router not shown online")
    }

    func testJobsSidebar() throws {
        app.radioButtons["Jobs"].click()
        XCTAssertTrue(app.textFields["Search jobs"].waitForExistence(timeout: 5))
        let firstJob = app.outlines["Sidebar"].cells.element(boundBy: 1)
        XCTAssertTrue(firstJob.waitForExistence(timeout: 20), "no jobs listed")
        firstJob.click()
        XCTAssertTrue(app.staticTexts["Project"].waitForExistence(timeout: 5), "clicking a job didn't show its details")
        let hasBody = waitForText("Output", timeout: 3) || waitForText("No output recorded", timeout: 3) || waitForText("Summary", timeout: 3)
        if !hasBody { dump("jobs") }
        XCTAssertTrue(hasBody, "job detail has no summary, output or folder contents")
        app.radioButtons["Chats"].click()
    }

    func openSettings(_ tab: String) {
        app.typeKey(",", modifierFlags: .command)
        let row = app.staticTexts[tab].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "settings tab \(tab) missing")
        row.click()
    }

    func testSettingsModels() throws {
        openSettings("Models")
        XCTAssertTrue(app.buttons["Check Now"].waitForExistence(timeout: 5), "Models settings didn't open")
        let listed = waitForText("Ornith", timeout: 30)
        if !listed { dump("settingsmodels") }
        XCTAssertTrue(listed, "router models not listed in Settings")
    }

    func testSettingsNotifications() throws {
        openSettings("Notifications")
        for title in ["Reply finished", "Needs approval or input", "Hosaka job changes", "Model and router errors"] {
            XCTAssertTrue(app.checkBoxes[title].exists || app.switches[title].exists || waitForText(title, timeout: 3), "\(title) toggle missing")
        }
    }

    func testSettingsImport() throws {
        openSettings("Import")
        let button = app.buttons["Import Threads"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "import button missing (old threads not found?)")
        button.click()
        XCTAssertTrue(waitForText("Imported", timeout: 10), "import didn't report a result")
    }

    func testMenuBarStatusItem() throws {
        let item = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no menu bar icon")
        item.click()
        XCTAssertTrue(app.menuItems["Open Workbench"].waitForExistence(timeout: 5), "menu bar menu missing Open Workbench")
        XCTAssertTrue(app.menuItems["New Chat"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }
}
