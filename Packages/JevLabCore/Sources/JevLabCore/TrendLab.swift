import Foundation
import Observation

/// Varianta trendové strategie.
public struct TrendVariant: Hashable, Sendable, Identifiable {
    public enum Direction: String, Sendable, CaseIterable { case longShort, longOnly }
    public enum Sizing: String, Sendable, CaseIterable { case fixed, atr }

    public var ruleID: String
    public var direction: Direction
    public var sizing: Sizing

    public var id: String { "\(ruleID)-\(direction.rawValue)-\(sizing.rawValue)" }
    public var rule: RuleStrategy { RuleStrategy.all.first { $0.id == ruleID } ?? RuleStrategy.all[0] }

    public var label: String {
        rule.name + (direction == .longOnly ? " · jen long" : " · long/short") + (sizing == .atr ? " · ATR" : "")
    }

    public static let all: [TrendVariant] = ["trend", "breakout"].flatMap { r in
        Direction.allCases.flatMap { d in Sizing.allCases.map { TrendVariant(ruleID: r, direction: d, sizing: $0) } }
    }
}

/// Výsledek jedné varianty.
public struct TrendVariantResult: Identifiable, Sendable {
    public var variant: TrendVariant
    public var full: SimResult
    public var test: SimResult
    /// Největší propad kapitálu (v $ při pozici $1000), od maxima k minimu.
    public var maxDrawdownUsd: Double
    /// Podíl svíček, kdy byla otevřená pozice.
    public var exposure: Double
    public var id: String { variant.id }
}

/// Aktuální signál strategie na poslední uzavřené svíčce.
public struct TrendSignal: Sendable {
    public var position: Double
    public var since: Date?
    public var asOf: Date
    public var price: Double
    public var ma20DistBps: Double?
    public var ma50DistBps: Double?
}

public struct TrendReport: Sendable {
    public var coin: String
    public var horizon: Horizon
    public var bars: Int
    public var from: Date
    public var to: Date
    public var years: Double
    public var feeRate: Double
    public var holdFull: SimResult
    public var holdTest: SimResult
    public var holdDrawdownUsd: Double
    public var variants: [TrendVariantResult]
    public var records: [CallRecord]
    public var current: [String: TrendSignal]
    /// Svíčky pro graf (všechny uzavřené).
    public var candles: [Hyperliquid.Candle] = []
    /// Nejbližší support / rezistence na poslední svíčce (cena).
    public var support: Double?
    public var resistance: Double?
}

/// Data pro graf: svíčky, MA20/MA50, značky vstupů a výstupů vybrané varianty, úrovně S/R.
public struct TrendChartData: Sendable {
    public struct Marker: Sendable, Equatable {
        public var time: Int64
        public var kind: String   // "long", "short", "exit"
    }

    public var candles: [Hyperliquid.Candle]
    public var ma20: [(time: Int64, value: Double)]
    public var ma50: [(time: Int64, value: Double)]
    public var markers: [Marker]
    public var support: Double?
    public var resistance: Double?

    public static func make(_ r: TrendReport, variant: TrendVariant) -> TrendChartData {
        let c = r.candles
        var m20: [(Int64, Double)] = []
        var m50: [(Int64, Double)] = []
        for i in c.indices {
            if let v = Indicators.sma(c, end: i, n: 20) { m20.append((c[i].openMs / 1000, v)) }
            if let v = Indicators.sma(c, end: i, n: 50) { m50.append((c[i].openMs / 1000, v)) }
        }
        // značky jen při změně směru (u ATR se mění i velikost, to se neznačí)
        let t = TrendMath.targets(r.records, variant: variant)
        var marks: [Marker] = []
        var prev = 0.0
        for (rec, x) in zip(r.records, t) {
            let a = prev > 0 ? 1 : prev < 0 ? -1 : 0
            let b = x > 0 ? 1 : x < 0 ? -1 : 0
            if a != b, rec.id < c.count {
                marks.append(Marker(time: c[rec.id].openMs / 1000, kind: b > 0 ? "long" : b < 0 ? "short" : "exit"))
            }
            prev = x
        }
        return TrendChartData(candles: c, ma20: m20.map { (time: $0.0, value: $0.1) }, ma50: m50.map { (time: $0.0, value: $0.1) },
                              markers: marks, support: r.support, resistance: r.resistance)
    }

    /// JSON pro JS funkci render() v grafu.
    public func json(fit: Bool) -> String {
        func r(_ x: Double) -> Double { (x * 1e6).rounded() / 1e6 }
        let obj: [String: Any] = [
            "fit": fit,
            "candles": candles.map { ["time": $0.openMs / 1000, "open": r($0.open), "high": r($0.high), "low": r($0.low), "close": r($0.close)] },
            "ma20": ma20.map { ["time": $0.time, "value": r($0.value)] },
            "ma50": ma50.map { ["time": $0.time, "value": r($0.value)] },
            "markers": markers.map { m -> [String: Any] in
                switch m.kind {
                case "long": return ["time": m.time, "position": "belowBar", "shape": "arrowUp", "color": "#3fd68a", "text": "Long"]
                case "short": return ["time": m.time, "position": "aboveBar", "shape": "arrowDown", "color": "#ff5d6c", "text": "Short"]
                default: return ["time": m.time, "position": "aboveBar", "shape": "circle", "color": "#9aa4b2", "text": "Ven"]
                }
            },
            "levels": [
                support.map { ["price": r($0), "color": "#3fd68a", "title": "support"] },
                resistance.map { ["price": r($0), "color": "#ff5d6c", "title": "rezistence"] },
            ].compactMap { $0 },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

public enum TrendMath {
    /// Cílová pozice pro variantu. Signál pravidla drží pozici max. `hold` svíček bez nového signálu
    /// (stejně jako v Pravidlech bez AI). ATR: velikost = medián ATR / aktuální ATR (0,25–3×), aby
    /// klidné i divoké období neslo podobné riziko; přepočet jen při změně o víc než 25 %.
    public static func targets(_ records: [CallRecord], variant: TrendVariant, hold: Int = 5) -> [Double] {
        var base = Analysis.ruleTargets(records, rule: variant.rule, hold: hold)
        if variant.direction == .longOnly { base = base.map { max(0, $0) } }
        guard variant.sizing == .atr else { return base }
        let atrs = records.compactMap { $0.state?["atr14_bps"] }.filter { $0 > 0 }.sorted()
        guard !atrs.isEmpty else { return base }
        let median = atrs[atrs.count / 2]
        var out: [Double] = []
        var current = 0.0
        for (rec, b) in zip(records, base) {
            if b == 0 {
                current = 0
            } else {
                let atr = rec.state?["atr14_bps"] ?? median
                let size = min(3, max(0.25, median / max(atr, 1)))
                let want = b * size
                if current == 0 || (current > 0) != (want > 0) || abs(want - current) / abs(current) > 0.25 {
                    current = want
                }
            }
            out.append(current)
        }
        return out
    }

    public static func maxDrawdown(_ r: SimResult) -> Double {
        var peak = 0.0, dd = 0.0
        for p in r.equity {
            peak = max(peak, p.netUsd)
            dd = max(dd, peak - p.netUsd)
        }
        return dd
    }

    public static func report(coin: String, horizon: Horizon, candles: [Hyperliquid.Candle], feeRate: Double) -> TrendReport? {
        guard candles.count > Features.warmup + 60 else { return nil }
        var records: [CallRecord] = []
        for i in Features.warmup..<(candles.count - 1) {
            let c = candles[i]
            guard c.close > 0 else { continue }
            records.append(CallRecord(id: i, t: Double(c.openMs + horizon.intervalMs) / 1000, side: nil, conf: nil,
                                      price: c.close, retNextBps: 1e4 * (candles[i + 1].close / c.close - 1),
                                      state: Features.state(candles: candles, at: i, horizon: horizon, context: [:])))
        }
        guard records.count >= 60 else { return nil }
        let half = records.count / 2
        let test = Array(records[half...])
        let holdTargets = [Double](repeating: 1, count: records.count)
        let holdFull = Analysis.simulate(records, targets: holdTargets, feeRate: feeRate)
        let holdTest = Analysis.simulate(test, targets: Array(holdTargets[half...]), feeRate: feeRate)

        // poslední uzavřená svíčka: aktuální signál (bez známého výsledku)
        let last = candles.count - 1
        var withLast = records
        withLast.append(CallRecord(id: last, t: Double(candles[last].openMs + horizon.intervalMs) / 1000, side: nil, conf: nil,
                                   price: candles[last].close,
                                   state: Features.state(candles: candles, at: last, horizon: horizon, context: [:])))

        var variants: [TrendVariantResult] = []
        var current: [String: TrendSignal] = [:]
        for v in TrendVariant.all {
            let t = targets(records, variant: v)
            let full = Analysis.simulate(records, targets: t, feeRate: feeRate)
            let tst = Analysis.simulate(test, targets: Array(t[half...]), feeRate: feeRate)
            variants.append(TrendVariantResult(variant: v, full: full, test: tst, maxDrawdownUsd: maxDrawdown(full),
                                               exposure: Double(t.filter { $0 != 0 }.count) / Double(max(1, t.count))))
            let tl = targets(withLast, variant: v)
            let pos = tl.last ?? 0
            var since: Date?
            if pos != 0, var k = tl.indices.last {
                while k > 0, (tl[k - 1] > 0) == (pos > 0), tl[k - 1] != 0 { k -= 1 }
                since = withLast[k].date
            }
            let st = withLast.last?.state
            current[v.id] = TrendSignal(position: pos, since: since, asOf: withLast.last?.date ?? Date(),
                                        price: withLast.last?.price ?? 0, ma20DistBps: st?["ma20_dist_bps"],
                                        ma50DistBps: st?["ma50_dist_bps"])
        }
        var support: Double?
        var resistance: Double?
        if let st = withLast.last?.state, let p = withLast.last?.price {
            if let d = st["support_dist_bps"] { support = p / (1 + d / 1e4) }
            if let d = st["resistance_dist_bps"] { resistance = p * (1 + d / 1e4) }
        }
        let from = records.first?.date ?? Date()
        let to = records.last?.date ?? Date()
        return TrendReport(coin: coin, horizon: horizon, bars: records.count, from: from, to: to,
                           years: max(0.01, to.timeIntervalSince(from) / (365.25 * 86_400)), feeRate: feeRate,
                           holdFull: holdFull, holdTest: holdTest, holdDrawdownUsd: maxDrawdown(holdFull),
                           variants: variants, records: records, current: current,
                           candles: candles, support: support, resistance: resistance)
    }

    /// CSV srovnání variant.
    public static func csv(_ r: TrendReport) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        var lines = ["market,timeframe,from,to,years,variant,net_full_bps,net_per_year_bps,net_2nd_half_bps,max_drawdown_usd,trades,exposure,hit_rate"]
        let base = "\(Instrument.find(r.coin).label),\(r.horizon.shortLabel),\(day.string(from: r.from)),\(day.string(from: r.to)),\(String(format: "%.2f", r.years))"
        for v in r.variants {
            lines.append("\(base),\(v.variant.label),\(f(v.full.netBps)),\(f(v.full.netBps / r.years)),\(f(v.test.netBps)),\(f(v.maxDrawdownUsd)),\(v.full.trades),\(String(format: "%.2f", v.exposure)),\(v.full.hitRate.map { String(format: "%.3f", $0) } ?? "")")
        }
        lines.append("\(base),Držet long (stálá pozice),\(f(r.holdFull.netBps)),\(f(r.holdFull.netBps / r.years)),\(f(r.holdTest.netBps)),\(f(r.holdDrawdownUsd)),1,1.00,")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Trendová strategie bez AI: backtest celé historie a aktuální signál (papírově, bez nákladů).
@MainActor
@Observable
public final class TrendLab {
    public private(set) var report: TrendReport?
    public private(set) var running = false
    public private(set) var error: String?
    public var selected: TrendVariant = TrendVariant(ruleID: "trend", direction: .longShort, sizing: .fixed)

    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public func run(coin: String, horizon: Horizon) {
        task?.cancel()
        running = true
        error = nil
        task = Task { [weak self] in
            do {
                let data = try await RuleLab.download(coin: coin, horizon: horizon, multiTF: false)
                let fee = Instrument.find(coin).takerFee
                let rep = await Task.detached(priority: .userInitiated) {
                    TrendMath.report(coin: coin, horizon: horizon, candles: data.0, feeRate: fee)
                }.value
                if Task.isCancelled { return }
                if let rep { self?.report = rep } else { self?.error = "Málo historie pro \(Instrument.find(coin).label)." }
            } catch {
                self?.error = error.localizedDescription
            }
            self?.running = false
        }
    }

    public var selectedResult: TrendVariantResult? {
        report?.variants.first { $0.variant == selected }
    }
}
