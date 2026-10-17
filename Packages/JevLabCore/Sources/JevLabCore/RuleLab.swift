import Foundation
import Observation

/// Výsledek pravidel na jednom trhu.
public struct RuleMarketResult: Identifiable, Sendable {
    public var coin: String
    public var horizon: Horizon
    public var bars: Int
    public var from: Date
    public var to: Date
    public var buyHoldFull: Double
    public var buyHoldTest: Double
    public var results: [RuleResult]
    public var feeRate: Double
    public var id: String { coin }
    public var label: String { Instrument.find(coin).label }
}

/// Souhrn jednoho pravidla přes všechny trhy.
public struct RuleSummary: Identifiable, Sendable {
    public var rule: RuleStrategy
    public var avgFull: Double
    public var avgTest: Double
    /// Na kolika trzích bylo pravidlo na 2. polovině po poplatcích v plusu.
    public var positiveTest: Int
    /// Na kolika trzích porazilo na 2. polovině „kupit a držet“.
    public var beatHoldTest: Int
    public var markets: Int
    public var id: String { rule.id }
}

public enum RuleLabStatus: Equatable {
    case idle, running, done
    case failed(String)
}

/// Backtest pravidel bez AI: stáhne maximální historii svíček (Hyperliquid ~5000 na rámec),
/// spočítá indikátory a S/R a vyhodnotí všechna pravidla. Žádná Jev ani Claude volání, nic nestojí.
@MainActor
@Observable
public final class RuleLab {
    public private(set) var status: RuleLabStatus = .idle
    public private(set) var results: [RuleMarketResult] = []
    public private(set) var progressText = ""
    public private(set) var errors: [String] = []
    public private(set) var horizon: Horizon = .d1

    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { status == .running }

    public var summaries: [RuleSummary] {
        guard !results.isEmpty else { return [] }
        return RuleStrategy.all.map { rule in
            var full = 0.0, test = 0.0, pos = 0, beat = 0, n = 0
            for m in results {
                guard let r = m.results.first(where: { $0.rule.id == rule.id }) else { continue }
                n += 1
                full += r.full.netBps
                let t = r.test?.netBps ?? 0
                test += t
                if t > 0 { pos += 1 }
                if t > m.buyHoldTest { beat += 1 }
            }
            return RuleSummary(rule: rule, avgFull: n > 0 ? full / Double(n) : 0, avgTest: n > 0 ? test / Double(n) : 0,
                               positiveTest: pos, beatHoldTest: beat, markets: n)
        }
    }

    public func run(coins: [String], horizon: Horizon, multiTF: Bool) {
        task?.cancel()
        self.horizon = horizon
        results = []
        errors = []
        status = .running
        task = Task { [weak self] in
            for (k, coin) in coins.enumerated() {
                if Task.isCancelled { return }
                self?.progressText = "\(Instrument.find(coin).label): stahuji svíčky (\(k + 1)/\(coins.count))…"
                do {
                    let data = try await RuleLab.download(coin: coin, horizon: horizon, multiTF: multiTF)
                    if Task.isCancelled { return }
                    self?.progressText = "\(Instrument.find(coin).label): počítám indikátory…"
                    let fee = Instrument.find(coin).takerFee
                    let res = await Task.detached(priority: .userInitiated) {
                        RuleLab.evaluate(coin: coin, horizon: horizon, candles: data.0, context: data.1, feeRate: fee)
                    }.value
                    if let res { self?.results.append(res) } else { self?.errors.append("\(Instrument.find(coin).label): málo historie") }
                } catch {
                    self?.errors.append("\(Instrument.find(coin).label): \(error.localizedDescription)")
                }
            }
            self?.progressText = ""
            self?.status = .done
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if status == .running { status = .done }
        progressText = ""
    }

    nonisolated static func download(coin: String, horizon: Horizon, multiTF: Bool) async throws
        -> ([Hyperliquid.Candle], [Timeframe: [Hyperliquid.Candle]]) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = nowMs - Int64(5100) * horizon.intervalMs
        let candles = Features.closed(try await Hyperliquid.candles(coin: coin, interval: horizon.interval, startMs: startMs),
                                      horizon: horizon, nowMs: nowMs)
        var ctx: [Timeframe: [Hyperliquid.Candle]] = [:]
        if multiTF, let first = candles.first {
            for tf in horizon.context {
                let s = max(first.openMs - 60 * Int64(tf.minutes) * 60_000, nowMs - 5100 * Int64(tf.minutes) * 60_000)
                if let list = try? await Hyperliquid.candles(coin: coin, interval: tf.rawValue, startMs: s) {
                    ctx[tf] = list
                }
            }
        }
        return (candles, ctx)
    }

    /// Čistý výpočet: featury pro každou svíčku a vyhodnocení pravidel (testovatelné bez sítě).
    public nonisolated static func evaluate(coin: String, horizon: Horizon, candles: [Hyperliquid.Candle],
                                            context: [Timeframe: [Hyperliquid.Candle]], feeRate: Double) -> RuleMarketResult? {
        guard candles.count > Features.warmup + 40 else { return nil }
        var records: [CallRecord] = []
        records.reserveCapacity(candles.count)
        for i in Features.warmup..<(candles.count - 1) {
            let c = candles[i]
            guard c.close > 0 else { continue }
            records.append(CallRecord(id: i, t: Double(c.openMs + horizon.intervalMs) / 1000, side: nil, conf: nil,
                                      price: c.close, retNextBps: 1e4 * (candles[i + 1].close / c.close - 1),
                                      state: Features.state(candles: candles, at: i, horizon: horizon, context: context)))
        }
        guard records.count >= 40 else { return nil }
        let half = records.count / 2
        return RuleMarketResult(coin: coin, horizon: horizon, bars: records.count,
                                from: records.first?.date ?? Date(), to: records.last?.date ?? Date(),
                                buyHoldFull: Analysis.buyHoldBps(records),
                                buyHoldTest: Analysis.buyHoldBps(Array(records[half...])),
                                results: Analysis.rules(records, feeRate: feeRate), feeRate: feeRate)
    }
}
