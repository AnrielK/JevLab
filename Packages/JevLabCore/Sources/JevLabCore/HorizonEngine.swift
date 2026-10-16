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

    public init() {}

    /// Kolik svíček (a tedy Jev volání) backtest projde.
    public var backtestBars: Int {
        min(Int(days * 1440) / horizon.minutes, 5000 - Features.warmup - 5)
    }
}

public enum HorizonStatus: Equatable, Sendable {
    case idle, loading, running, done
    case failed(String)
}

/// Svíčkový režim: Jev odhaduje směr na příští svíčku (5 min / 15 min / 1 h).
/// Backtest přehraje historii (Jev nevidí datum), živý režim rozhoduje na každém zavření svíčky.
/// Pozice: Jev směr, když jistota ≥ práh, jinak flat. Obchoduje se na zavření svíčky (taker poplatek).
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
    public private(set) var startedAt = Date()
    public private(set) var nextBarAt: Date?
    public private(set) var lastPrice: Double?
    public private(set) var model = ""
    /// Práh jistoty: dá se měnit i po doběhnutí, výsledek se přepočítá z uložených rozhodnutí.
    public var minConf: Double = 0.6

    /// Zavolá se s hotovým během (pro uložení do databáze).
    @ObservationIgnored public var onFinish: (@MainActor (RunDetail) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saved = false

    public init() {}

    public var isActive: Bool { status == .loading || status == .running }
    public var instrument: Instrument { Instrument.find(config.coin) }
    public var feeRate: Double { instrument.takerFee }
    public var result: SimResult { Analysis.simulate(records, minConf: minConf, feeRate: feeRate, notional: config.notional) }
    public var buyHoldBps: Double { Analysis.buyHoldBps(records) }

    /// Aktuální papírová pozice v živém režimu (podle posledního rozhodnutí).
    public var livePosition: Int {
        guard let r = records.last, r.side != nil, (r.conf ?? 0) >= minConf else { return 0 }
        return Int(r.sign)
    }

    // MARK: - Ovládání

    public func startBacktest(config: HorizonConfig, jev: JevClient) {
        reset(config: config, mode: .backtest, jev: jev)
        task = Task { [weak self] in await self?.runBacktest(jev) }
    }

    public func startLive(config: HorizonConfig, jev: JevClient) {
        reset(config: config, mode: .live, jev: jev)
        task = Task { [weak self] in await self?.runLive(jev) }
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

    private func reset(config: HorizonConfig, mode: RunKind, jev: JevClient) {
        stop()
        self.config = config
        self.mode = mode
        model = jev.model
        records = []
        progress = 0
        total = 0
        errors = 0
        lastError = nil
        lastPrice = nil
        startedAt = Date()
        saved = false
        status = .loading
    }

    // MARK: - Backtest

    private func runBacktest(_ jev: JevClient) async {
        let h = config.horizon
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let bars = config.backtestBars
        let startMs = nowMs - Int64(bars + Features.warmup + 3) * h.intervalMs
        let candles: [Hyperliquid.Candle]
        do {
            candles = Features.closed(try await Hyperliquid.candles(coin: config.coin, interval: h.interval, startMs: startMs),
                                      horizon: h, nowMs: nowMs)
        } catch {
            status = .failed("Nepodařilo se stáhnout svíčky: \(error.localizedDescription)")
            return
        }
        guard candles.count > Features.warmup + 2 else {
            status = .failed("Málo historických svíček pro \(instrument.label) (\(candles.count)).")
            return
        }
        if Task.isCancelled { return }
        let indices = Array(Features.warmup..<(candles.count - 1))
        total = indices.count
        lastPrice = candles.last?.close
        status = .running

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
                    guard let state = Features.state(candles: candles, at: i, horizon: h) else { continue }
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
                                     state: Features.state(candles: candles, at: i, horizon: h))
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
            progress = min(total, start)
        }
        status = .done
        finishAndSave()
    }

    // MARK: - Živý režim

    private func runLive(_ jev: JevClient) async {
        let h = config.horizon
        var lastProcessed: Int64 = -1
        status = .running
        while !Task.isCancelled {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            do {
                let startMs = nowMs - Int64(Features.warmup + 8) * h.intervalMs
                let candles = Features.closed(try await Hyperliquid.candles(coin: config.coin, interval: h.interval, startMs: startMs),
                                              horizon: h, nowMs: nowMs)
                if let lastBar = candles.last, lastBar.openMs != lastProcessed, let state = Features.state(candles: candles, at: candles.count - 1, horizon: h) {
                    lastProcessed = lastBar.openMs
                    lastPrice = lastBar.close
                    // výsledek předchozího rozhodnutí = pohyb do zavření této svíčky
                    if let k = records.indices.last, records[k].retNextBps == nil, records[k].price > 0 {
                        records[k].retNextBps = rounded(1e4 * (lastBar.close / records[k].price - 1), 3)
                    }
                    var rec = CallRecord(id: records.count, t: Double(lastBar.openMs + h.intervalMs) / 1000, side: nil, conf: nil,
                                         price: lastBar.close, state: state)
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
        let summary = RunSummary(
            kind: mode, started: startedAt, ended: Date(), coin: config.coin, horizon: config.horizon,
            strategy: "svíčky \(config.horizon.label) · práh \(Int((minConf * 100).rounded())) %",
            minConf: minConf, feeRate: feeRate, notional: config.notional,
            calls: records.filter { $0.side != nil }.count, trades: r.trades,
            grossUsd: r.usd(r.grossBps, notional: config.notional), feesUsd: r.usd(r.feesBps, notional: config.notional),
            netUsd: r.usd(r.netBps, notional: config.notional), hitRate: r.hitRate, buyHoldBps: buyHoldBps,
            note: mode == .backtest ? "\(Int(config.days)) dní historie" : nil)
        onFinish?(RunDetail(summary: summary, records: records))
    }
}
