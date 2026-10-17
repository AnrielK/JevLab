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
    /// Zavolá se s hotovým během (pro uložení).
    @ObservationIgnored public var onFinish: (@MainActor (RuleLabRun) -> Void)?
    @ObservationIgnored private var multiTF = true

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
        self.multiTF = multiTF
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
            self?.finish()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if status == .running {
            status = .done
            finish()
        }
        progressText = ""
    }

    private func finish() {
        guard !results.isEmpty else { return }
        onFinish?(RuleLabRun(date: Date(), horizon: horizon, multiTF: multiTF, results: results, errors: errors))
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

// MARK: - Uložené výsledky

/// Jeden řádek výsledku: pravidlo × trh (ploché, aby šlo uložit a exportovat).
public struct RuleRow: Codable, Sendable, Equatable {
    public var coin: String
    public var rule: String
    public var ruleName: String
    public var netFullBps: Double
    public var netTestBps: Double?
    public var trades: Int
    public var signals: Int
    public var hitRate: Double?
}

public struct RuleMarketMeta: Codable, Sendable, Equatable {
    public var coin: String
    public var bars: Int
    public var from: Date
    public var to: Date
    public var feeRate: Double
    public var buyHoldFull: Double
    public var buyHoldTest: Double
}

/// Uložený běh „Pravidla bez AI“.
public struct RuleLabRun: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var horizon: Horizon
    public var multiTF: Bool
    public var markets: [RuleMarketMeta]
    public var rows: [RuleRow]
    public var errors: [String]

    public init(date: Date, horizon: Horizon, multiTF: Bool, results: [RuleMarketResult], errors: [String]) {
        self.date = date
        self.horizon = horizon
        self.multiTF = multiTF
        self.errors = errors
        markets = results.map {
            RuleMarketMeta(coin: $0.coin, bars: $0.bars, from: $0.from, to: $0.to, feeRate: $0.feeRate,
                           buyHoldFull: $0.buyHoldFull, buyHoldTest: $0.buyHoldTest)
        }
        rows = results.flatMap { m in
            m.results.map { r in
                RuleRow(coin: m.coin, rule: r.rule.id, ruleName: r.rule.name, netFullBps: r.full.netBps,
                        netTestBps: r.test?.netBps, trades: r.full.trades, signals: r.signals, hitRate: r.full.hitRate)
            }
        }
    }

    public var title: String {
        let coins = markets.map { Instrument.find($0.coin).label }
        let list = coins.count > 4 ? coins.prefix(4).joined(separator: ", ") + " +\(coins.count - 4)" : coins.joined(separator: ", ")
        return "\(horizon.shortLabel)\(multiTF ? " + kontext" : "") · \(list)"
    }

    /// Souhrn pravidla přes trhy (průměry, kolikrát v plusu / nad „kupit a držet“ na 2. polovině).
    public func summary(rule: String) -> (avgFull: Double, avgTest: Double, positive: Int, beatHold: Int, n: Int) {
        var full = 0.0, test = 0.0, pos = 0, beat = 0, n = 0
        for r in rows where r.rule == rule {
            n += 1
            full += r.netFullBps
            let t = r.netTestBps ?? 0
            test += t
            if t > 0 { pos += 1 }
            if let m = markets.first(where: { $0.coin == r.coin }), t > m.buyHoldTest { beat += 1 }
        }
        return (n > 0 ? full / Double(n) : 0, n > 0 ? test / Double(n) : 0, pos, beat, n)
    }

    /// CSV: jeden řádek pravidlo × trh + řádky „kupit a držet“ a souhrn přes trhy.
    public var csv: String {
        let iso = ISO8601DateFormatter()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        func f(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "" }
        var lines = ["run_time,timeframe,context,market,from,to,bars,fee_bps,rule,net_full_bps,net_2nd_half_bps,trades,signals,hit_rate,buyhold_full_bps,buyhold_2nd_half_bps"]
        let head = "\(iso.string(from: date)),\(horizon.shortLabel),\(multiTF ? 1 : 0)"
        for m in markets {
            let base = "\(head),\(Instrument.find(m.coin).label),\(day.string(from: m.from)),\(day.string(from: m.to)),\(m.bars),\(String(format: "%.2f", m.feeRate * 1e4))"
            for r in rows where r.coin == m.coin {
                lines.append("\(base),\(r.ruleName),\(f(r.netFullBps)),\(f(r.netTestBps)),\(r.trades),\(r.signals),\(r.hitRate.map { String(format: "%.3f", $0) } ?? ""),\(f(m.buyHoldFull)),\(f(m.buyHoldTest))")
            }
            lines.append("\(base),Kupit a držet,\(f(m.buyHoldFull)),\(f(m.buyHoldTest)),1,,,\(f(m.buyHoldFull)),\(f(m.buyHoldTest))")
        }
        for rule in RuleStrategy.all {
            let s = summary(rule: rule.id)
            guard s.n > 0 else { continue }
            lines.append("\(head),PRŮMĚR \(s.n) trhů,,,,,\(rule.name),\(f(s.avgFull)),\(f(s.avgTest)),,,v plusu \(s.positive)/\(s.n) · nad držením \(s.beatHold)/\(s.n),,")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Uložené běhy „Pravidla bez AI“ (JSON soubory v Application Support/JevLab/rulelab).
public final class RuleLabStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func standard() -> RuleLabStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RuleLabStore(directory: base.appendingPathComponent("JevLab/rulelab", isDirectory: true))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func save(_ run: RuleLabRun) throws {
        lock.lock()
        defer { lock.unlock() }
        try RuleLabStore.encoder.encode(run).write(to: directory.appendingPathComponent("\(run.id.uuidString).json"), options: .atomic)
    }

    public func all() -> [RuleLabRun] {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? RuleLabStore.decoder.decode(RuleLabRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    public func delete(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }
}
