import Foundation
import Observation
import JevLabCore

/// Řádek výsledku kontroly nastavení.
struct CheckLine: Identifiable {
    enum State { case running, ok, warn, fail, info }
    let id = UUID()
    var title: String
    var detail: String
    var state: State
}

@MainActor
@Observable
final class AppModel {
    enum KeyKind: String, CaseIterable, Identifiable {
        case gateway, direct
        var id: String { rawValue }
        var label: String { self == .gateway ? "Vercel AI Gateway" : "TypeSafe (přímý)" }
        var account: String { self == .gateway ? "AI_GATEWAY_API_KEY" : "TYPESAFE_API_KEY" }
    }

    let loop = LoopEngine()
    let newsroom = NewsroomEngine()
    let horizon = HorizonEngine()
    let store = RunStore.standard()

    var horizonConfig = HorizonConfig()
    /// Akciové perpy z API Hyperliquid (dokud se nenačtou, výchozí seznam).
    private(set) var stocks: [Instrument] = Instrument.stocks
    private(set) var stocksNote: String?
    /// Databáze proběhlých běhů (nejnovější první).
    private(set) var runs: [RunSummary] = []
    var saveError: String?

    var loopConfig = LoopConfig()
    var newsHours: Double = 36
    var newsGap: Double = 6

    var strategy: StrategySettings

    private(set) var hasGatewayKey = false
    private(set) var hasDirectKey = false

    var checkLines: [CheckLine] = []
    var checking = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "strategy"),
           let s = try? JSONDecoder().decode(StrategySettings.self, from: data) {
            strategy = s
        } else {
            strategy = StrategySettings()
        }
        refreshKeys()
        runs = store.summaries()
        loop.onFinish = { [weak self] detail in self?.saveRun(detail) }
        Task { await self.loadStocks() }
        horizon.onFinish = { [weak self] detail in self?.saveRun(detail) }
    }

    // MARK: - Databáze běhů

    func saveRun(_ detail: RunDetail) {
        do {
            try store.save(detail)
            saveError = nil
        } catch {
            saveError = "Běh se nepodařilo uložit: \(error.localizedDescription)"
        }
        runs = store.summaries()
    }

    func deleteRun(_ id: UUID) {
        store.delete(id)
        runs = store.summaries()
    }

    // MARK: - Horizont

    func loadStocks() async {
        do {
            let list = try await Instrument.loadStocks()
            if !list.isEmpty {
                stocks = list
                stocksNote = nil
            } else {
                stocksNote = "Hyperliquid nevrátil žádné akciové trhy (dex xyz)."
            }
        } catch {
            stocksNote = "Seznam akcií se nepodařilo načíst: \(error.localizedDescription)"
        }
    }

    func startBacktest() {
        guard let jev = makeJev() else { return }
        loop.stop()
        newsroom.stop()
        horizon.startBacktest(config: horizonConfig, jev: jev, claude: horizonConfig.claude ? makeClaude() : nil)
    }

    func startHorizonLive() {
        guard let jev = makeJev() else { return }
        horizon.startLive(config: horizonConfig, jev: jev, claude: horizonConfig.claude ? makeClaude() : nil)
    }

    // MARK: - Klíče

    var hasKey: Bool { hasGatewayKey || hasDirectKey }

    func refreshKeys() {
        hasGatewayKey = !(Keychain.read(KeyKind.gateway.account) ?? "").isEmpty
        hasDirectKey = !(Keychain.read(KeyKind.direct.account) ?? "").isEmpty
    }

    func saveKey(_ value: String, kind: KeyKind) {
        Keychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: kind.account)
        refreshKeys()
    }

    func deleteKey(_ kind: KeyKind) {
        Keychain.delete(kind.account)
        refreshKeys()
    }

    /// Jev klient: přímý TypeSafe klíč má přednost (stejně jako v jev-starteru).
    func makeJev() -> JevClient? {
        if let d = Keychain.read(KeyKind.direct.account), !d.isEmpty { return JevClient(directKey: d) }
        if let g = Keychain.read(KeyKind.gateway.account), !g.isEmpty { return JevClient(gatewayKey: g) }
        return nil
    }

    /// Volá se po každé změně strategie v UI: uložit a za běhu předat smyčce.
    func strategyChanged() {
        if let data = try? JSONEncoder().encode(strategy) {
            UserDefaults.standard.set(data, forKey: "strategy")
        }
        if loop.isActive { loop.update(strategy: strategy.make()) }
    }

    // MARK: - Spouštění

    /// Claude model pro mozek (Vercel AI Gateway slug).
    var claudeModel: String = UserDefaults.standard.string(forKey: "claudeModel") ?? ClaudeClient.defaultModel

    func saveClaudeModel() {
        UserDefaults.standard.set(claudeModel, forKey: "claudeModel")
    }

    /// Claude jde jen přes Vercel AI Gateway klíč.
    func makeClaude() -> ClaudeClient? {
        guard let g = Keychain.read(KeyKind.gateway.account), !g.isEmpty else { return nil }
        return ClaudeClient(gatewayKey: g, model: claudeModel.trimmingCharacters(in: .whitespaces))
    }

    func startLoop() {
        guard let jev = makeJev() else { return }
        newsroom.stop()
        loop.start(config: loopConfig, jev: jev, strategy: strategy.make(), claude: loopConfig.brain ? makeClaude() : nil)
    }

    func startNewsroom() {
        guard let jev = makeJev() else { return }
        loop.stop()
        newsroom.start(hours: newsHours, gap: newsGap, jev: jev)
    }

    // MARK: - Kontrola (obdoba `python -m jevlab check`)

    func runCheck() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        checkLines = []

        func add(_ title: String) -> Int {
            checkLines.append(CheckLine(title: title, detail: "…", state: .running))
            return checkLines.count - 1
        }
        func set(_ i: Int, _ detail: String, _ state: CheckLine.State) {
            checkLines[i].detail = detail
            checkLines[i].state = state
        }

        let p = add("1. Ceny Hyperliquid")
        do {
            let m = try await Hyperliquid.mids(["BTC", "HYPE"])
            set(p, "BTC \(Fmt.px(m["BTC"] ?? 0)) · HYPE \(Fmt.px(m["HYPE"] ?? 0))", .ok)
        } catch {
            set(p, "nedostupné: \(error.localizedDescription)", .fail)
        }

        let n = add("2. Zpravodajské feedy")
        let (items, _) = await News.fetchHeadlines(hours: 24)
        set(n, items.isEmpty ? "žádné titulky, zkontroluj internet" : "\(items.count) titulků za posledních 24 h",
            items.isEmpty ? .warn : .ok)

        let j = add("3. Jev")
        guard let jev = makeJev() else {
            set(j, "zatím bez klíče: vlož ho výše a spusť kontrolu znovu", .warn)
            return
        }
        let q = ["side": JevQuestion.choice("Which side should a bot hold for the next few seconds?", ["buy", "sell"])]
        do {
            let r = try await jev.ask(state: ["return_5s_bps": 1.2, "top_of_book_imbalance": 0.4], questions: q, timeout: 15, retries: 2)
            let side = r.answers["side"]?.choice ?? "?"
            let pct = Int(((r.answers["side"]?.choiceProbs[side] ?? 0) * 100).rounded())
            set(j, "Jev říká \(side.uppercased()) \(pct) % za \(r.latencyMs) ms (model \(r.model))", .ok)
        } catch let e as JevError {
            if e.isAuth {
                set(j, "klíč odmítnut: zkontroluj ho a že má Vercel tým kartu nebo kredity", .fail)
            } else if e.isThrottled {
                set(j, "omezeno (free tier je vytížený): počkej minutu nebo přidej $5 kreditů", .warn)
            } else {
                set(j, "chyba: \(e.localizedDescription.prefix(160))", .fail)
            }
            return
        } catch {
            set(j, "chyba: \(error.localizedDescription)", .fail)
            return
        }

        let s = add("4. Rychlost")
        var ok = 0
        let t0 = Date()
        for _ in 0..<6 {
            if (try? await jev.ask(state: ["return_5s_bps": 0.5], questions: q, timeout: 10, retries: 0)) != nil { ok += 1 }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        set(s, "\(ok)/6 rychlých volání prošlo za \(secs) s · " +
            (ok == 6 ? "plná rychlost" : "free tier, smyčka poběží pomaleji ($5 kreditů = plná rychlost)"),
            ok == 6 ? .ok : .warn)
    }
}
