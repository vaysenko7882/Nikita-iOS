import Foundation
import UIKit

private final class HistoryHarnessController: UIViewController, UITableViewDataSource {
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var events: [[String: Any]] = []
    private var failures: [String] = []
    private var checks = 0
    private var refreshes = 0
    private var started = false
    private var detailFeed: CodeGramProfileHistoryFeed?
    private var showingDetail = false
    private var deferHistoryRendering = false
    private var renderedHistory = CodeGramProfileHistorySnapshot()
    private var anchorSequence: Int64?
    private var anchorY: CGFloat = 0
    private let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let session = URLSession(configuration: .ephemeral)
    private lazy var base: URL = {
        let file = Bundle.main.url(forResource: "fixture", withExtension: "json")!
        let object = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        return URL(string: object["url"] as! String)!
    }()
    private lazy var feed = CodeGramProfileHistoryFeed(interval: 0.25, fetch: { [weak self] before, done in
        guard let self else { return nil }
        return self.http("history?before=\(before)") { done($0) }
    })

    override func viewDidLoad() {
        super.viewDidLoad()
        self.overrideUserInterfaceStyle = .dark
        self.view.backgroundColor = .black
        CodeGramSettingsTheme.configure(self.table)
        self.table.contentInsetAdjustmentBehavior = .never
        self.table.contentInset = UIEdgeInsets(top: 120,left: 0,bottom: 24,right: 0)
        self.table.dataSource = self
        self.view.addSubview(self.table)
        self.feed.updated = { [weak self] _, _ in
            guard let self else { return }
            if !self.deferHistoryRendering { self.showEvents(self.feed.events) }
            self.refreshes += 1
        }
        self.feed.failed = { [weak self] error, _ in self?.check(false,"HTTP: \(error)") }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.table.frame = self.view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !self.started else { return }
        self.started = true
        self.table.contentOffset = .zero
        self.feed.setVisible(true)
        self.wait("initial HTTP page", condition: { self.latest == 60 }) { self.initial() }
    }

    private var latest: Int64 { (self.feed.events.first?["seq"] as? NSNumber)?.int64Value ?? 0 }
    private func showEvents(_ events: [[String: Any]], resetToTop: Bool = false) {
        let anchor = CodeGramProfileHistoryScrollAnchor(table: self.table,events: self.events)
        self.events = events
        self.renderedHistory = CodeGramProfileHistorySnapshot(events: events,serverId: self.showingDetail ? self.detailFeed?.serverId : self.feed.serverId)
        UIView.performWithoutAnimation {
            self.table.reloadData()
            self.table.layoutIfNeeded()
            anchor.restore(table: self.table,events: self.events,resetToTop: resetToTop)
        }
    }
    private func check(_ value: Bool, _ message: String) { self.checks += 1; if !value { self.failures.append(message) } }
    private func wait(_ title: String, timeout: TimeInterval = 8, condition: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            if condition() { then(); return }
            if Date() > deadline { self.check(false,"Timed out: " + title); self.finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now()+0.05,execute: tick)
        }
        tick()
    }
    private func phase(_ title: String, then: @escaping () -> Void) {
        try! title.write(to: self.output.appendingPathComponent("phase.txt"),atomically: true,encoding: .utf8)
        // simctl screenshot can take longer than an HTTP request on a busy
        // hosted Mac. Capturing evidence must not race the transport checks.
        self.wait("frame " + title, timeout: 120, condition: { FileManager.default.fileExists(atPath: self.output.appendingPathComponent("captured-"+title).path) },then: then)
    }

    @discardableResult private func http(_ path: String, method: String = "GET", completion: @escaping (Result<[String: Any], Error>) -> Void) -> (() -> Void) {
        var request = URLRequest(url: URL(string: path,relativeTo: self.base)!.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 4
        let task = self.session.dataTask(with: request) { data, response, error in
            let result: Result<[String: Any], Error>
            if let error { result = .failure(error) }
            else if (response as? HTTPURLResponse)?.statusCode == 200, let data,
                    let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { result = .success(value) }
            else { result = .failure(NSError(domain: "HistoryFixture",code: 1)) }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return { task.cancel() }
    }
    private func post(_ path: String, then: @escaping () -> Void) {
        self.http(path,method: "POST") { result in
            if case .failure = result { self.check(false,"POST " + path); self.finish() }
            else { then() }
        }
    }

    private func initial() {
        self.check(self.table.contentOffset.y == 0,"Fixture must start at production offset zero")
        self.check(!(self.table.contentOffset.y <= -self.table.contentInset.top + 40),"Fixture must cover the old navigation-inset polling bug")
        self.check(self.feed.events.count == 4,"Initial page length")
        self.phase("01-initial-offset-zero") {
            self.post("publish") {
                self.wait("automatic story at offset zero", condition: { self.latest == 61 }) {
                    self.check(self.table.contentOffset.y == 0,"Latest history must stay in place")
                    self.check(self.events.contains { ($0["seq"] as? Int) == 61 },"New story must reach table without Refresh")
                    self.check(self.table.visibleCells.contains { $0.accessibilityLabel?.contains("Сторис 61") == true },"Newest row must become visible, not be hidden by anchor compensation")
                    self.phase("02-story-without-refresh") { self.older() }
                }
            }
        }
    }

    private func rememberAnchor() {
        self.table.layoutIfNeeded()
        let path = self.table.indexPathsForVisibleRows!.sorted().first { $0.section == 1 && $0.row < self.events.count }!
        self.check(path.row > 0,"Older-history fixture must be scrolled")
        self.anchorSequence = (self.events[path.row]["seq"] as? NSNumber)?.int64Value
        self.anchorY = self.table.rectForRow(at: path).minY - self.table.contentOffset.y
    }
    private func checkAnchor() {
        guard let seq = self.anchorSequence, let row = self.events.firstIndex(where: { ($0["seq"] as? NSNumber)?.int64Value == seq }) else {
            self.check(false,"An older visible record was lost"); return
        }
        let y = self.table.rectForRow(at: IndexPath(row: row,section: 1)).minY - self.table.contentOffset.y
        self.check(abs(y-self.anchorY)<1,"Reading anchor moved by \(y-self.anchorY) points")
    }
    private func older() {
        self.feed.loadOlder()
        self.wait("older HTTP page", condition: { self.feed.events.count == 9 }) {
            self.feed.loadOlder()
            self.wait("second older HTTP page", condition: { self.feed.events.count == 13 }) {
                self.feed.loadOlder()
                self.wait("third older HTTP page", condition: { self.feed.events.count == 17 }) { self.scrolledHistory() }
            }
        }
    }
    private func scrolledHistory() {
        self.table.scrollToRow(at: IndexPath(row: 8,section: 1),at: .top,animated: false)
        self.rememberAnchor()
        self.phase("03-older-history") {
            self.post("publish") {
                self.wait("automatic story while scrolled", condition: { self.latest == 62 }) {
                    self.checkAnchor()
                    self.check(self.feed.before == 45,"Live page must not reset the older cursor")
                    self.check(self.events.contains { ($0["seq"] as? Int) == 45 },"Older page must be retained")
                    self.phase("04-story-while-scrolled") { self.burst() }
                }
            }
        }
    }
    private func burst() {
        self.post("publish?count=80") {
            self.wait("burst head", condition: { self.latest == 142 && self.feed.events.count < 98 }) {
                self.post("publish") {
                    self.wait("fresh head during old backfill", timeout: 3.5, condition: { self.latest == 143 && self.feed.events.count < 99 }) {
                        self.check(true,"Fresh stories must not wait behind the old gap")
                        self.waitForBurst()
                    }
                }
            }
        }
    }
    private func waitForBurst() {
            self.wait("all burst pages without gaps", timeout: 16, condition: { self.feed.events.count == 99 }) {
                self.checkAnchor()
                self.check(Set(self.feed.events.compactMap { ($0["seq"] as? NSNumber)?.intValue }) == Set(45...143),"A fast burst must not leave an invisible pagination gap")
                self.check(self.feed.before == 45,"Gap catchup must preserve older cursor")
                self.phase("05-gap-caught-up") { self.detailMedia() }
            }
    }
    private func detailMedia() {
        let original = self.feed.events.first!
        let seq = (original["seq"] as! NSNumber).int64Value
        let epoch = self.feed.serverId
        self.feed.setVisible(false)
        self.showingDetail = true
        var first = true
        let detail = CodeGramProfileHistoryFeed(interval: 0.25,fetch: { [weak self] _, done in
            self?.http("history?before=\(seq+1)&limit=1") { done($0) }
        })
        self.detailFeed = detail
        detail.updated = { [weak self] page, _ in
            guard let self, let event = (page["events"] as? [[String: Any]])?.first else { return }
            self.check(page["server_id"] as? String == epoch,"Detail must stay on the selected archive")
            self.check((event["seq"] as? NSNumber)?.int64Value == seq,"Detail must stay on the selected event")
            self.check((event["payload"] as? NSDictionary)?.isEqual(original["payload"] as? NSDictionary) == true,"Media readiness must not rewrite original before/after")
            self.showEvents([event],resetToTop: first)
            first = false
        }
        detail.failed = { [weak self] error, _ in self?.check(false,"Detail HTTP: \(error)"); self?.finish() }
        detail.setVisible(true)
        self.wait("detail pending media", condition: { (detail.events.first?["media"] as? [[String: Any]])?.first?["state"] as? String == "pending" }) {
            self.post("ready") {
                self.wait("open detail automatically becomes ready", condition: { (detail.events.first?["media"] as? [[String: Any]])?.first?["state"] as? String == "ready" }) {
                    self.check((self.feed.events.first?["media"] as? [[String: Any]])?.first?["state"] as? String == "pending","A hidden parent history must not be doing the detail refresh")
                    self.phase("06-file-ready-in-open-detail") {
                        detail.setVisible(false)
                        self.detailFeed = nil
                        self.showingDetail = false
                        self.showEvents(self.feed.events,resetToTop: true)
                        self.feed.setVisible(true)
                        self.wait("parent live media catches up", condition: { (self.feed.events.first?["media"] as? [[String: Any]])?.first?["state"] as? String == "ready" }) {
                            self.check(self.feed.events.count == 99,"Updating media must not duplicate a story")
                            self.table.scrollToRow(at: IndexPath(row: 0,section: 1),at: .top,animated: false)
                            self.cancellation()
                        }
                    }
                }
            }
        }
    }
    private func cancellation() {
        self.post("delay-next?seconds=1") {
            self.waitForDelayedRequest {
                let previous = self.latest
                self.feed.setVisible(false)
                self.post("publish") {
                    DispatchQueue.main.asyncAfter(deadline: .now()+1.3) {
                        self.check(self.latest == previous,"Cancelled/hidden request must not update the screen")
                        self.feed.setVisible(true)
                        self.wait("visible restart without refresh", condition: { self.latest == previous+1 }) {
                            self.phase("07-visible-resumed") { self.background() }
                        }
                    }
                }
            }
        }
    }
    private func waitForDelayedRequest(then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(8)
        func poll() {
            self.http("stats") { result in
                if case let .success(value) = result, (value["inflight_delays"] as? Int ?? 0) > 0 { then(); return }
                if Date() > deadline { self.check(false,"No slow HTTP request started"); self.finish(); return }
                DispatchQueue.main.asyncAfter(deadline: .now()+0.05,execute: poll)
            }
        }
        poll()
    }
    private func background() {
        self.phase("08-background-request") {
            let result = self.output.appendingPathComponent("foreground-result.json")
            self.wait("host background/foreground", timeout: 120, condition: { FileManager.default.fileExists(atPath: result.path) }) {
                let data = try! JSONSerialization.jsonObject(with: Data(contentsOf: result)) as! [String: Any]
                self.check(data["background_requests"] as? Int == 0,"Background screen must not keep polling")
                let expected = (data["latest"] as! NSNumber).int64Value
                self.wait("foreground event without refresh", condition: { self.latest == expected }) {
                    self.phase("09-foreground-live") {
                        self.check(self.refreshes >= 6,"Expected real automatic HTTP updates")
                        let oldRows = self.renderedHistory
                        self.deferHistoryRendering = true
                        self.post("reset-epoch") {
                            self.wait("new archive epoch", condition: { self.latest == 4 && self.feed.events.count == 4 }) {
                                self.check(!self.feed.hasMore,"Complete new archive must not offer an empty older page")
                                self.check(self.events.first?["seq"] as? Int == oldRows.events.first?["seq"] as? Int,"Deferred rendering must retain the old rows")
                                self.check(oldRows.serverId != self.feed.serverId,"Fixture must change archive identity before rendering")
                                self.check(oldRows.event(at: 0,currentServerId: self.feed.serverId) == nil,"Tapping a stale rendered row must refuse the new archive identity")
                                self.phase("10-stale-row-rejected") {
                                    self.deferHistoryRendering = false
                                    self.showEvents(self.feed.events,resetToTop: true)
                                    self.check(self.renderedHistory.event(at: 0,currentServerId: self.feed.serverId)?["seq"] as? Int == 4,"A newly rendered row must carry its own matching archive identity")
                                    self.phase("11-archive-replaced") { self.finish() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func finish() {
        self.feed.setVisible(false)
        self.detailFeed?.setVisible(false)
        let result: [String: Any] = ["checks": self.checks,"failures": self.failures,"http_refreshes": self.refreshes,"manual_refreshes": 0]
        let bytes = try! JSONSerialization.data(withJSONObject: result,options: [.prettyPrinted,.sortedKeys])
        try! bytes.write(to: self.output.appendingPathComponent("result.json"))
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : self.events.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Профиль" : "История изменений" }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            return CodeGramTextCell(title: self.showingDetail ? "Открытая запись сторис" : "Отслеживание включено",detail: "Живой HTTP · без кнопки «Обновить»",symbol: "person.crop.circle.badge.clock")
        } else {
            let value = self.events[indexPath.row]
            let seq = (value["seq"] as? NSNumber)?.intValue ?? 0
            let title = (value["kind"] as? String == "stories.added" ? "Сторис " : "Запись ") + String(seq)
            let ready = (value["media"] as? [[String: Any]])?.first?["state"] as? String == "ready"
            let detail = (ready ? "Файл сохранён" : "Получено с VPS") + String(repeating: "\nПодробности события сохранены.",count: seq % 3)
            return CodeGramTextCell(title: title,detail: detail,symbol: "clock.arrow.circlepath")
        }
    }
}

private final class HistoryHarnessScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = HistoryHarnessController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

@main private final class HistoryHarnessApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let value = UISceneConfiguration(name: "HistoryHTTPRegression",sessionRole: connectingSceneSession.role)
        value.delegateClass = HistoryHarnessScene.self
        return value
    }
}
