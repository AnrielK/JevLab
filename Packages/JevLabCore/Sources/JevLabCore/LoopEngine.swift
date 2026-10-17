import Foundation
import Observation

public struct LoopConfig: Sendable, Equatable {
    public var coin: String = "HYPE"
    /// Nejkratší rozestup mezi Jev voláními (s).
    public var pace: Double = 0.3
    /// Délka běhu v minutách, 0 = do zastavení.
    public var minutes: Double = 10
    /// Odpovědi pomalejší než tohle se ignorují.
    public var lateMs: Int = 1500
    /// Limitní objednávky (maker) místo tržních.
    public var maker: Bool = true
    /// Jak dlouho limitní objednávka čeká, než se zruší (s).
    public var makerWait: Double = 10
    public var notional: Double = 1000
    /// Claude jako mozek: nastavuje bias long/short/flat.
    public var brain: Bool = false
    /// Jak často Claude čte trh (min).
    public var brainEvery: Double = 10

    public init() {}
}

public enum CallStatus: String, Sendable {
    case ok, late, throttled, error
}

/// Jedno Jev volání a co s ním strategie udělala.
public struct LoopDecision: Identifiable, Sendable {
    public var block: Int
    public var tAsk: Double
    public var t: Double = 0
    public var side: Side?
    public var conf: Double?
    public var ms: Int?
    public var status: CallStatus = .error
    public var error: String?
    public var action: String = ""
    public var mid: Double = 0
    public var micro: Double = 0
    public var state: [String: Double]

    public var id: Int { block }
    public var date: Date { Date(timeIntervalSince1970: t) }
    public var isTrade: Bool { action.hasPrefix("limit") || action.hasPrefix("market") }
}

public struct LoopFill: Identifiable, Sendable {
    public var id = UUID()
    public var t: Double
    public var side: Side
    public var px: Double
    public var kind: String
    public var call: Int
    public var waited: Double
    public var date: Date { Date(timeIntervalSince1970: t) }
}

public struct RestingOrder: Sendable, Equatable {
    public var target: Int
    public var buying: Bool
    public var px: Double
    public var t: Double
    public var expires: Double
    public var call: Int
}

public enum LoopStatus: Equatable, Sendable {
    case idle, connecting, running, done
    case failed(String)
}

/// Jev smyčka: Jev volání dopadající na živý cenový feed Hyperliquid,
/// strategie rozhoduje, která se stanou (papírovými) obchody.
///
/// Limitní objednávka leží na nejlepším bid/ask a vyplní se, jen když trh
/// obchoduje SKRZ její cenu; po `makerWait` sekundách se zruší.
/// JEN PAPÍR: čte veřejná data a fills simuluje. Nikdy neposílá skutečnou objednávku.
@MainActor
@Observable
public final class LoopEngine {
    public static let questions: [String: JevQuestion] = [
        "side": .choice("Which side should this bot hold for the next few seconds: buy (be long) or sell (be short)?", ["buy", "sell"]),
    ]

    public private(set) var status: LoopStatus = .idle
    public private(set) var config = LoopConfig()
    public private(set) var strategySummary = ""
    public private(set) var model = ""
    public private(set) var startedAt: Double = 0
    public private(set) var updatedAt: Double = 0

    public private(set) var price: Double?
    public private(set) var spreadBps: Double?
    public private(set) var ticks: [PriceTick] = []
    public private(set) var decisions: [LoopDecision] = []
    public private(set) var fills: [LoopFill] = []
    public private(set) var book = PaperBook()
    public private(set) var order: RestingOrder?

    public private(set) var counts: [CallStatus: Int] = [:]
    public private(set) var totalCalls = 0
    public private(set) var lastMs: Int?
    public private(set) var avgMs: Int?
    public private(set) var interval: Double = 0.3
    public private(set) var ratePerSecond: Double = 0
    public private(set) var hits = 0
    public private(set) var scored = 0
    /// Poslední chyba Jev volání (HTTP kód a text), aby se dala ukázat v UI.
    public private(set) var lastError: String?
    /// Claudův mozek, když je zapnutý.
    public private(set) var brain: ClaudeBrain?

    @ObservationIgnored private var market = MarketBook()
    @ObservationIgnored private var feed: HyperliquidFeed?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var tickerTask: Task<Void, Never>?
    @ObservationIgnored private var jev: JevClient?
    @ObservationIgnored private var strategy: TradingStrategy = ConvictionStrategy()
    @ObservationIgnored private var latencies: [Int] = []
    @ObservationIgnored private var streak = 0
    @ObservationIgnored private var prev: LoopDecision?
    @ObservationIgnored private var lastTradeT: Double = 0
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var generation = 0
    /// Zavolá se s hotovým během (pro uložení do databáze).
    @ObservationIgnored public var onFinish: (@MainActor (RunDetail) -> Void)?
    /// Všechna zodpovězená volání běhu (UI drží jen posledních 300).
    @ObservationIgnored private var archive: [CallRecord] = []

    public init() {}

    public var isActive: Bool { status == .connecting || status == .running }
    public var position: Int { book.pos }

    public var answered: [LoopDecision] {
        decisions.filter { $0.status == .ok || $0.status == .late }
    }

    // MARK: - Ovládání

    public func start(config: LoopConfig, jev: JevClient, strategy: TradingStrategy, claude: ClaudeClient? = nil) {
        stop()
        generation += 1
        self.config = config
        self.jev = jev
        self.strategy = strategy
        strategySummary = strategy.summary
        model = jev.model
        market = MarketBook()
        book = PaperBook(notional: config.notional)
        decisions = []
        archive = []
        fills = []
        ticks = []
        order = nil
        price = nil
        spreadBps = nil
        counts = [:]
        totalCalls = 0
        latencies = []
        lastMs = nil
        lastError = nil
        avgMs = nil
        interval = config.pace
        streak = 0
        prev = nil
        lastTradeT = 0
        inFlight = 0
        hits = 0
        scored = 0
        status = .connecting
        if config.brain, let claude {
            let b = ClaudeBrain(coin: config.coin, everyMinutes: config.brainEvery, client: claude)
            brain = b
            b.start()
        } else {
            brain = nil
        }

        let f = HyperliquidFeed(coin: config.coin)
        f.onEvent = { [weak self] ev in self?.handle(ev) }
        feed = f
        f.start()
        let gen = generation
        runTask = Task { [weak self] in await self?.run(gen) }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        finish()
    }

    /// Nový strategie za běhu (např. po úpravě nastavení).
    public func update(strategy: TradingStrategy) {
        self.strategy = strategy
        strategySummary = strategy.summary
    }

    private func finish() {
        brain?.stop()
        tickerTask?.cancel()
        tickerTask = nil
        feed?.stop()
        feed = nil
        if isActive {
            let wasRunning = status == .running
            refresh()
            status = .done
            if wasRunning, totalCalls > 0 { onFinish?(makeDetail()) }
        }
    }

    /// Celý běh pro databázi: každé zodpovězené volání s výsledkem (pohyb do dalšího volání) a všechny obchody.
    private func makeDetail() -> RunDetail {
        let records = Analysis.fillTickOutcomes(archive)
        let mid = market.quote?.mid ?? records.last?.price ?? 0
        let gross = book.gross(mid: mid)
        let summary = RunSummary(
            kind: .tick, started: Date(timeIntervalSince1970: startedAt), ended: Date(), coin: config.coin, horizon: nil,
            strategy: strategySummary, brain: brain != nil, minConf: nil,
            feeRate: config.maker ? Instrument.find(config.coin).makerFee : Instrument.find(config.coin).takerFee,
            notional: config.notional, calls: totalCalls, trades: book.trades,
            grossUsd: gross, feesUsd: book.fees, netUsd: gross - book.fees,
            hitRate: scored > 0 ? Double(hits) / Double(scored) : nil, buyHoldBps: Analysis.buyHoldBps(records),
            note: brain.map { "Claude: \($0.state.bias?.rawValue ?? "–")" })
        let fills = self.fills.map { FillRecord(t: $0.t, side: $0.side, px: $0.px, kind: $0.kind) }
        return RunDetail(summary: summary, records: records, fills: fills)
    }

    // MARK: - Smyčka

    private func handle(_ ev: FeedEvent) {
        switch ev {
        case .quote(let q): market.apply(quote: q)
        case .depth(let b, let a): market.apply(depthBidUSD: b, depthAskUSD: a)
        case .trades(let tr, let now): market.apply(trades: tr, now: now)
        }
    }

    private func run(_ gen: Int) async {
        let deadline = nowSeconds() + 15
        while market.quote == nil {
            if Task.isCancelled { return }
            if nowSeconds() > deadline {
                feed?.stop()
                feed = nil
                status = .failed("Žádná cena z Hyperliquid po 15 s. Zkontroluj připojení.")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard gen == generation, !Task.isCancelled else { return }
        status = .running
        startedAt = nowSeconds()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        var seq = 0
        while !Task.isCancelled && (config.minutes <= 0 || nowSeconds() - startedAt < config.minutes * 60) {
            seq += 1
            if inFlight < 8 {
                inFlight += 1
                let s = seq
                Task { [weak self] in await self?.ask(s, gen) }
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
        }
        if gen == generation, !Task.isCancelled { finish() }
    }

    /// Vyplní ležící objednávky a obnoví data pro UI (4× za sekundu).
    private func refresh() {
        checkOrder()
        let now = nowSeconds()
        guard let snap = market.snapshot(now: now) else { return }
        price = snap.micro
        spreadBps = snap.spreadBps
        book.recordEquity(t: now, mid: snap.mid)
        ticks = market.recentTicks(seconds: 90, now: now)
        ratePerSecond = Double(decisions.filter { $0.t >= now - 10 }.count) / 10
        updatedAt = now
    }

    private func checkOrder() {
        guard let o = order else { return }
        let now = nowSeconds()
        var through = market.trades(since: o.t).contains { o.buying ? $0.px < o.px : $0.px > o.px }
        if let q = market.quote {
            through = through || (o.buying ? q.ask < o.px : q.bid > o.px)
        }
        if through {
            book.fill(target: o.target, px: o.px, feeRate: Instrument.find(config.coin).makerFee)
            appendFill(LoopFill(t: now, side: o.buying ? .buy : .sell, px: o.px, kind: "limit", call: o.call, waited: now - o.t))
            order = nil
            lastTradeT = now
        } else if now > o.expires {
            order = nil
        }
    }

    private func appendFill(_ f: LoopFill) {
        fills.append(f)
        if fills.count > 100 { fills.removeFirst(fills.count - 100) }
    }

    private func ask(_ seq: Int, _ gen: Int) async {
        guard let jev, let snap = market.snapshot(now: nowSeconds()) else {
            inFlight -= 1
            return
        }
        var rec = LoopDecision(block: seq, tAsk: nowSeconds(), state: snap.state)
        do {
            let res = try await jev.ask(state: snap.state.mapValues { $0 as Any }, questions: LoopEngine.questions,
                                        timeout: 5, retries: 0)
            if let ans = res.answers["side"], let c = ans.choice, let side = Side(rawValue: c) {
                rec.side = side
                rec.conf = rounded(ans.choiceProbs[c] ?? 0, 3)
            }
            rec.ms = res.latencyMs
            rec.status = res.latencyMs <= config.lateMs ? .ok : .late
        } catch let e as JevError {
            rec.status = e.isThrottled ? .throttled : .error
            if e.isFatal, gen == generation, status == .running {
                lastError = String(e.localizedDescription.prefix(160))
                status = .failed("Smyčka zastavena: \(e.localizedDescription.prefix(200))")
                runTask?.cancel()
                runTask = nil
                tickerTask?.cancel()
                tickerTask = nil
                feed?.stop()
                feed = nil
                brain?.stop()
            }
            rec.error = String(e.localizedDescription.prefix(160))
        } catch {
            rec.status = .error
            rec.error = String(error.localizedDescription.prefix(160))
        }
        inFlight -= 1
        guard gen == generation, status == .running else { return }

        let now = market.snapshot(now: nowSeconds()) ?? snap // trh ve chvíli, kdy odpověď DORAZÍ
        rec.t = nowSeconds()
        rec.mid = now.mid
        rec.micro = now.micro

        counts[rec.status, default: 0] += 1
        if let err = rec.error { lastError = err }
        totalCalls += 1
        if let ms = rec.ms {
            latencies.append(ms)
            if latencies.count > 200 { latencies.removeFirst(latencies.count - 200) }
            lastMs = ms
            avgMs = latencies.reduce(0, +) / latencies.count
        }
        if rec.status == .throttled { // na 429 tvrdě zpomalit, na dobrých odpovědích pomalu zrychlovat
            interval = min(4, interval * 1.6)
            streak = 0
        } else if rec.status == .ok {
            streak += 1
            if streak >= 3 { interval = max(config.pace, interval * 0.9) }
        }
        if let p = prev, now.mid != p.mid { // měl předchozí směr pravdu?
            if (now.mid > p.mid) == (p.side == .buy) { hits += 1 }
            scored += 1
        }
        if rec.status == .ok, rec.side != nil {
            prev = rec
            rec.action = decide(rec, now)
        } else {
            rec.action = rec.status == .late ? "hold · late" : rec.status.rawValue
        }
        decisions.append(rec)
        if decisions.count > 300 { decisions.removeFirst(decisions.count - 300) }
        if rec.status == .ok || rec.status == .late {
            archive.append(CallRecord(id: rec.block, t: rec.t, side: rec.side, conf: rec.conf, price: rec.mid,
                                      state: rec.state, action: rec.action))
        }
    }

    private func decide(_ rec: LoopDecision, _ now: MarketSnapshot) -> String {
        guard let side = rec.side, let conf = rec.conf else { return "hold" }
        var gated: StrategyAction?
        if let brain {
            gated = BrainLogic.gate(bias: brain.state.bias, want: side == .buy ? 1 : -1, position: book.pos)
        }
        let choice = gated ?? strategy.decide(call: JevCall(side: side, conf: conf), market: rec.state,
                                     position: book.pos, secondsSinceTrade: nowSeconds() - lastTradeT)
        guard let want = choice.target else { return choice.label }
        if want == book.pos {
            if let o = order, o.target != want { order = nil }
            return "hold · " + (want == 1 ? "already long" : want == -1 ? "already short" : "already flat")
        }
        if let o = order, o.target == want { return "hold · limit order working" }
        let buying = want > book.pos
        if config.maker {
            let px = buying ? now.bid : now.ask
            let t = nowSeconds()
            order = RestingOrder(target: want, buying: buying, px: px, t: t, expires: t + config.makerWait, call: rec.block)
            return "limit \(buying ? "buy" : "sell") @ \(Fmt.px(px))"
        }
        let px = buying ? now.ask : now.bid
        book.fill(target: want, px: px, feeRate: Instrument.find(config.coin).takerFee)
        appendFill(LoopFill(t: nowSeconds(), side: buying ? .buy : .sell, px: px, kind: "market", call: rec.block, waited: 0))
        lastTradeT = nowSeconds()
        return "market \(choice.label) @ \(Fmt.px(px))"
    }
}

/// Formátování cen sdílené jádrem a UI.
public enum Fmt {
    public static func px(_ p: Double) -> String {
        let d = p >= 1000 ? 1 : p >= 10 ? 3 : 5
        return String(format: "%.\(d)f", p)
    }
}
