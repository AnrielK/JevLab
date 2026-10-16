import Foundation
import Observation

public struct HorizonConfig: Sendable, Equatable {
    public var coin: String = "BTC"
    public var horizon: Horizon = .h1
    /// Kolik dní historie projde backtest.
    public var days: Double = 7
    /// Kolik Jev volání běží souběžně při backtestu.
    public var concurrency: Int = 6
    public var notional: Double = 1000
    /// Jev vidí i kontext z nižšího a vyšších rámců (např. 4h, týden, měsíc u denního).
    public var multiTF: Bool = true
    /// Claude nastavuje směr (long/short/flat), Jev obchoduje jen tím směrem.
    public var claude: Bool = false
    /// Jak často Claude čte trh (počet svíček); 0 = podle horizontu.
    public var claudeEveryBars: Int = 0

    public init() {}

    /// Kolik dní historie jde (u kontextu omezuje nižší rámec).
    public var maxDays: Double { multiTF ? horizon.maxDaysWithContext : horizon.maxDays }

    /// Kolik svíček (a tedy Jev volání) backtest projde.
    public var backtestBars: Int {
        max(1, min(Int(min(days, maxDays) * 1440) / horizon.minutes, 5000 - Features.warmup - Features.history - 5))
    }

    public var contextTimeframes: [Timeframe] { multiTF ? horizon.context : [] }

    /// Claude čte trh každých N svíček (výchozí zhruba jednou za 1–4 hodiny, u denního každý den).
    public var claudeEvery: Int {
        claudeEveryBars > 0 ? claudeEveryBars : HorizonConfig.defaultEvery(horizon)
    }

    public static func defaultEvery(_ horizon: Horizon) -> Int {
        switch horizon {
        case .m5: return 12
        case .m15: return 8
        case .h1: return 4
        case .h4: return 1
        case .d1: return 1
        }
    }

    /// Kolik Claude volání backtest udělá.
    public var claudeCalls: Int { claude ? (backtestBars + claudeEvery - 1) / claudeEvery : 0 }
}

public enum HorizonStatus: Equatable, Sendable {
    case idle, loading, running, done
    case failed(String)
}

/// Svíčkový režim: Jev odhaduje směr na příští svíčku (5 min … 1 den).
/// Backtest přehraje historii (Jev ani Claude nevidí datum ani absolutní cenu), živý režim rozhoduje
/// na každém zavření svíčky. Pozice se počítá z uložených rozhodnutí (`Analysis.simulate`).
/// JEN PAPÍR.
@MainActor
@Observable
public final class HorizonEngine {
    public private(set) var status: HorizonStatus = .idle
    public private(set) var mode: RunKind = .backtest
    public private(set) var config = HorizonConfig()
    public private(set) var records: [CallRecord] = []
    public private(set) var progress = 0
    public private(set) var total = 0
    public private(set) var errors = 0
    public private(set) var lastError: String?
    public private(set) var claudeErrors = 0
    public private(set) var lastClaude: BrainState?
    public private(set) var startedAt = Date()
    public private(set) var nextBarAt: Date?
    public private(set) var lastPrice: Double?
    public private(set) var model = ""
    /// Práh jistoty: dá se měnit i po doběhnutí, výsledek se přepočítá z uložených rozhodnutí.
    public var minConf: Double = 0.6
    /// Kdo rozhoduje o pozici ve výsledku (Jev sám / Jev + Claude / Claude sám).
    public var simMode: SimMode = .jev

    /// Zavolá se s hotovým během (pro uložení do databáze).
    @ObservationIgnored public var onFinish: (@MainActor (RunDetail) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saved = false

    public init() {}

    public var isActive: Bool { status == .loading || status == .running }
    public var instrument: Instrument { Instrument.find(config.coin) }
    public var feeRate: Double { instrument.takerFee }
    public var result: SimResult {
        Analysis.simulate(records, minConf: minConf, feeRate: feeRate, notional: config.notional, mode: simMode)
    }
    public var buyHoldBps: Double { Analysis.buyHoldBps(records) }

    /// Aktuální papírová pozice v živém režimu (podle posledního rozhodnutí a zvoleného režimu).
    public var livePosition: Int {
        guard let r = records.last else { return 0 }
        let jev = (r.side != nil && (r.conf ?? 0) >= minConf) ? Int(r.sign) : 0
        let claude = r.bias == .long ? 1 : r.bias == .short ? -1 : 0
        switch simMode {
        case .jev: return jev
        case .jevClaude: return claude != 0 && jev == claude ? jev : 0
        case .claude: return claude
        }
    }

    // MARK: - Ovládání

    public func startBacktest(config: HorizonConfig, jev: JevClient, claude: ClaudeClient? = nil) {
        reset(config: config, mode: .backtest, jev: jev, claude: claude)
        let c = self.config.claude ? claude : nil
        task = Task { [weak self] in await self?.runBacktest(jev, claude: c) }
    }

    public func startLive(config: HorizonConfig, jev: JevClient, claude: ClaudeClient? = nil) {
        reset(config: config, mode: .live, jev: jev, claude: claude)
        let c = self.config.claude ? claude : nil
        task = Task { [weak self] in await self?.runLive(jev, claude: c) }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if isActive {
            status = .done
            finishAndSave()
        }
        nextBarAt = nil
    }

    private func reset(config: HorizonConfig, mode: RunKind, jev: JevClient, claude: ClaudeClient?) {
        stop()
        var cfg = config
        if claude == nil { cfg.claude = false }
        self.config = cfg
        self.mode = mode
        simMode = cfg.claude ? .jevClaude : .jev
        model = jev.model
        records = []
        progress = 0
        total = 0
        errors = 0
        lastError = nil
        claudeErrors = 0
        lastClaude = nil
        lastPrice = nil
        startedAt = Date()
        saved = false
        status = .loading
    }

    // MARK: - Kontext a Claude

    /// Stáhne svíčky kontextových rámců pro rozhodování od `fromMs`. Nižší rámec jen s malou rezervou
    /// (má taky jen ~5000 svíček), vyšší rámce s delší historií kvůli MA a support/rezistenci.
    private func loadContext(fromMs: Int64) async -> [Timeframe: [Hyperliquid.Candle]] {
        var out: [Timeframe: [Hyperliquid.Candle]] = [:]
        for tf in config.contextTimeframes {
            let back: Int64 = 60
            let start = fromMs - back * Int64(tf.minutes) * 60_000
            if let list = try? await Hyperliquid.candles(coin: config.coin, interval: tf.rawValue, startMs: start) {
                out[tf] = list
            }
        }
        return out
    }

    /// Jedno Claudovo čtení trhu ze stejných relativních čísel, jaká vidí Jev.
    nonisolated static func askClaude(_ client: ClaudeClient, state: [String: Double], horizon: Horizon,
                                      every: Int) async -> (BrainState?, String?) {
        do {
            let reply = try await client.complete(BrainLogic.horizonPrompt(state: state, horizon: horizon, everyBars: every))
            guard let p = BrainLogic.parseReply(reply.text) else {
                return (nil, "Claude neodpověděl platným JSON: \(reply.text.prefix(100))")
            }
            var st = BrainState()
            st.bias = p.bias
            st.confidence = p.confidence
            st.reason = p.reason
            st.t = Date().timeIntervalSince1970
            st.ms = reply.ms
            st.model = client.model
            return (st, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - Backtest

    private func runBacktest(_ jev: JevClient, claude: ClaudeClient?) async {
        let h = config.horizon
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let bars = config.backtestBars
        let startMs = nowMs - Int64(bars + Features.warmup + Features.history + 3) * h.intervalMs
        let candles: [Hyperliquid.Candle]
        do {
            candles = Features.closed(try await Hyperliquid.candles(coin: config.coin, interval: h.interval, startMs: startMs),
                                      horizon: h, nowMs: nowMs)
        } catch {
            status = .failed("Nepodařilo se stáhnout svíčky pro \(instrument.label): \(error.localizedDescription)")
            return
        }
        guard candles.count > Features.warmup + 2 else {
            status = .failed("Málo historických svíček pro \(instrument.label) (\(candles.count)). U akciových perpů bývá historie krátká, zkus kratší období nebo menší horizont.")
            return
        }
        if Task.isCancelled { return }
        // rozhoduje se jen v požadovaném období; svíčky před ním slouží jako historie pro indikátory
        let firstIdx = max(Features.warmup, candles.count - 1 - bars)
        let context = await loadContext(fromMs: candles[firstIdx].openMs)
        if Task.isCancelled { return }
        let indices = Array(firstIdx..<(candles.count - 1))
        var states: [Int: [String: Double]] = [:]
        for i in indices { states[i] = Features.state(candles: candles, at: i, horizon: h, context: context) }

        let every = config.claudeEvery
        let claudeIdx = claude == nil ? [] : indices.filter { ($0 - firstIdx) % every == 0 }
        total = indices.count + claudeIdx.count
        lastPrice = candles.last?.close
        status = .running

        // 1) Claudova čtení (méně volání, nižší souběh)
        var biasAt: [Int: Bias] = [:]
        if let claude {
            var start = 0
            while start < claudeIdx.count {
                if Task.isCancelled { return }
                let chunk = Array(claudeIdx[start..<min(start + 3, claudeIdx.count)])
                start += 3
                let results = await withTaskGroup(of: (Int, BrainState?, String?).self,
                                                  returning: [(Int, BrainState?, String?)].self) { group in
                    for i in chunk {
                        guard let st = states[i] else { continue }
                        group.addTask {
                            let (b, err) = await HorizonEngine.askClaude(claude, state: st, horizon: h, every: every)
                            return (i, b, err)
                        }
                    }
                    var out: [(Int, BrainState?, String?)] = []
                    for await item in group { out.append(item) }
                    return out
                }
                if Task.isCancelled { return }
                for (i, b, err) in results {
                    if let b, let bias = b.bias {
                        biasAt[i] = bias
                        if lastClaude == nil || (lastClaude?.t ?? 0) <= (b.t ?? 0) { lastClaude = b }
                    } else {
                        claudeErrors += 1
                        lastError = "Claude: \(err ?? "?")"
                    }
                }
                progress += chunk.count
            }
        }

        // 2) Jev rozhodnutí na každé svíčce
        var done: [CallRecord] = []
        let question = h.question
        let width = max(1, config.concurrency)
        var start = 0
        while start < indices.count {
            if Task.isCancelled { return }
            let chunk = Array(indices[start..<min(start + width, indices.count)])
            start += width
            let results = await withTaskGroup(of: (Int, JevResult?, String?).self,
                                              returning: [(Int, JevResult?, String?)].self) { group in
                for i in chunk {
                    guard let state = states[i] else { continue }
                    group.addTask {
                        do {
                            let r = try await jev.ask(state: state.mapValues { $0 as Any }, questions: question,
                                                      timeout: 10, retries: 2)
                            return (i, r, nil)
                        } catch {
                            return (i, nil, error.localizedDescription)
                        }
                    }
                }
                var out: [(Int, JevResult?, String?)] = []
                for await item in group { out.append(item) }
                return out
            }
            if Task.isCancelled { return }
            for (i, res, err) in results {
                let c = candles[i]
                var rec = CallRecord(id: i, t: Double(c.openMs + h.intervalMs) / 1000, side: nil, conf: nil, price: c.close,
                                     retNextBps: rounded(1e4 * (candles[i + 1].close / c.close - 1), 3),
                                     state: states[i])
                // platí poslední úspěšné Claudovo čtení, které už v tu chvíli proběhlo (stejná nebo dřívější svíčka)
                if claude != nil, let k = claudeIdx.last(where: { $0 <= i && biasAt[$0] != nil }) {
                    rec.bias = biasAt[k]
                }
                if let ans = res?.answers["side"], let s = ans.choice, let side = Side(rawValue: s) {
                    rec.side = side
                    rec.conf = rounded(ans.choiceProbs[s] ?? 0, 3)
                } else {
                    errors += 1
                    lastError = err
                    rec.action = "chyba"
                }
                done.append(rec)
            }
            done.sort { $0.t < $1.t }
            records = done
            progress = min(total, claudeIdx.count + start)
        }
        status = .done
        finishAndSave()
    }

    // MARK: - Živý režim

    private func runLive(_ jev: JevClient, claude: ClaudeClient?) async {
        let h = config.horizon
        var lastProcessed: Int64 = -1
        var currentBias: Bias?
        var barsSinceClaude = Int.max
        status = .running
        while !Task.isCancelled {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            do {
                let startMs = nowMs - Int64(Features.warmup + Features.history + 8) * h.intervalMs
                let candles = Features.closed(try await Hyperliquid.candles(coin: config.coin, interval: h.interval, startMs: startMs),
                                              horizon: h, nowMs: nowMs)
                let context = await loadContext(fromMs: candles.last?.openMs ?? nowMs)
                if let lastBar = candles.last, lastBar.openMs != lastProcessed,
                   let state = Features.state(candles: candles, at: candles.count - 1, horizon: h, context: context) {
                    lastProcessed = lastBar.openMs
                    lastPrice = lastBar.close
                    // výsledek předchozího rozhodnutí = pohyb do zavření této svíčky
                    if let k = records.indices.last, records[k].retNextBps == nil, records[k].price > 0 {
                        records[k].retNextBps = rounded(1e4 * (lastBar.close / records[k].price - 1), 3)
                    }
                    if let claude, barsSinceClaude >= config.claudeEvery {
                        let (b, err) = await HorizonEngine.askClaude(claude, state: state, horizon: h, every: config.claudeEvery)
                        if let b, let bias = b.bias {
                            currentBias = bias
                            lastClaude = b
                            barsSinceClaude = 0
                        } else {
                            claudeErrors += 1
                            lastError = "Claude: \(err ?? "?")"
                        }
                    }
                    barsSinceClaude = barsSinceClaude == Int.max ? Int.max : barsSinceClaude + 1
                    var rec = CallRecord(id: records.count, t: Double(lastBar.openMs + h.intervalMs) / 1000, side: nil, conf: nil,
                                         price: lastBar.close, state: state, bias: currentBias)
                    do {
                        let r = try await jev.ask(state: state.mapValues { $0 as Any }, questions: h.question, timeout: 15, retries: 3)
                        if let ans = r.answers["side"], let s = ans.choice, let side = Side(rawValue: s) {
                            rec.side = side
                            rec.conf = rounded(ans.choiceProbs[s] ?? 0, 3)
                        }
                    } catch {
                        errors += 1
                        lastError = error.localizedDescription
                        rec.action = "chyba"
                    }
                    if Task.isCancelled { return }
                    records.append(rec)
                    progress = records.count
                }
                let next = (lastProcessed > 0 ? lastProcessed : nowMs) + 2 * h.intervalMs
                nextBarAt = Date(timeIntervalSince1970: Double(next) / 1000 + 3)
            } catch {
                errors += 1
                lastError = "Svíčky: \(error.localizedDescription)"
                nextBarAt = Date().addingTimeInterval(30)
            }
            let wait = max(5, (nextBarAt ?? Date().addingTimeInterval(30)).timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        }
    }

    // MARK: - Uložení

    private func finishAndSave() {
        guard !saved, !records.isEmpty else { return }
        saved = true
        let r = result
        let tfs: [String] = config.contextTimeframes.map { $0.label }
        let ctx: String = tfs.isEmpty ? "" : " + kontext " + tfs.joined(separator: "/")
        let pct: Int = Int((minConf * 100).rounded())
        let who: String = config.claude ? " · " + simMode.label : ""
        let strategyText: String = "svíčky " + config.horizon.label + ctx + " · práh \(pct) %" + who
        let note: String? = mode == .backtest ? "\(Int(config.days)) dní historie" : nil
        let summary = RunSummary(
            kind: mode, started: startedAt, ended: Date(), coin: config.coin, horizon: config.horizon,
            strategy: strategyText, brain: config.claude,
            minConf: minConf, feeRate: feeRate, notional: config.notional,
            calls: records.filter { $0.side != nil }.count, trades: r.trades,
            grossUsd: r.usd(r.grossBps, notional: config.notional), feesUsd: r.usd(r.feesBps, notional: config.notional),
            netUsd: r.usd(r.netBps, notional: config.notional), hitRate: r.hitRate, buyHoldBps: buyHoldBps,
            note: note)
        onFinish?(RunDetail(summary: summary, records: records))
    }
}
