import XCTest

final class DemoRoomTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testEveryGameAndTournamentFromHomeWithoutServer() {
        app.launchArguments = ["-server", "http://localhost:1"]
        app.launch()
        let enter = app.buttons["demo.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 15))
        enter.tap()
        let lobby = app.buttons["demo.close"]
        XCTAssertTrue(lobby.waitForExistence(timeout: 5))

        app.buttons["demo.tournament"].tap()
        let progress = app.descendants(matching: .any)["arena.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertTrue(progress.label.contains("Бокс, игра 1 из 10"))
        app.buttons["arena.back"].tap()

        let games = [
            ("box", "Бокс"), ("race", "Гонка"), ("mines", "Минёр"),
            ("duel", "Дуэль"), ("slice", "Самурай"), ("goal", "Пенальти"),
            ("range", "Тир"), ("arm", "Армрестлинг"), ("hoop", "Баскет"), ("beat", "Ритм")
        ]
        for (id, title) in games {
            XCTAssertTrue(lobby.waitForExistence(timeout: 5))
            let tile = app.buttons["demo.game." + id]
            for _ in 0..<8 {
                if tile.exists && tile.isHittable { break }
                app.scrollViews["demo.games"].swipeUp(velocity: .slow)
            }
            XCTAssertTrue(tile.isHittable, title)
            tile.tap()
            XCTAssertTrue(progress.waitForExistence(timeout: 8), title)
            XCTAssertTrue(progress.label.contains("\(title), игра 1 из 1"), progress.label)
            XCTAssertTrue(app.staticTexts["Бот Слоу"].exists)
            app.buttons["arena.back"].tap()
        }
        lobby.tap()
        XCTAssertTrue(enter.waitForExistence(timeout: 5))
    }

    func testBotScoresAndReturnsToRoomAfterThreeRounds() {
        app.launchArguments = ["-server", ""]
        app.launch()
        app.buttons["demo.enter"].tap()
        app.buttons["demo.game.box"].tap()
        let score = app.staticTexts["arena.opponent.score"]
        let positive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES '[1-9][0-9]*'"), object: score)
        XCTAssertEqual(XCTWaiter.wait(for: [positive], timeout: 30), .completed)
        let inGame = XCTAttachment(screenshot: app.screenshot())
        inGame.name = "Slou demo match"
        inGame.lifetime = .keepAlways
        add(inGame)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        let finish = app.buttons["В демо-комнату"]
        XCTAssertTrue(finish.waitForExistence(timeout: 85))
        finish.tap()
        XCTAssertTrue(app.buttons["demo.tournament"].waitForExistence(timeout: 5))
    }
}
