import Foundation

/// Horizont rozhodování pro svíčkový režim (backtest i živý běh).
public enum Horizon: String, Codable, CaseIterable, Sendable, Identifiable {
    case m5 = "5m"
    case m15 = "15m"
    case h1 = "1h"

    public var id: String { rawValue }
    /// Interval pro Hyperliquid candleSnapshot.
    public var interval: String { rawValue }

    public var minutes: Int {
        switch self {
        case .m5: return 5
        case .m15: return 15
        case .h1: return 60
        }
    }

    public var intervalMs: Int64 { Int64(minutes) * 60_000 }

    public var label: String {
        switch self {
        case .m5: return "5 min"
        case .m15: return "15 min"
        case .h1: return "1 hodina"
        }
    }

    /// Hyperliquid vrací zhruba posledních 5000 svíček na interval, víc historie nejde.
    public var maxDays: Double {
        Double(5000 - Features.warmup - 5) * Double(minutes) / 1440
    }

    /// Otázka pro Jev: kam bude cena na konci další svíčky.
    public var question: [String: JevQuestion] {
        let h = minutes >= 60 ? "\(minutes / 60)-hour" : "\(minutes)-minute"
        return ["side": .choice(
            "Will the price close higher or lower at the end of the next \(h) bar? buy = higher (be long), sell = lower (be short).",
            ["buy", "sell"])]
    }
}

/// Featury ze svíček, které Jev vidí ve svíčkovém režimu. Jen čísla, bez data a bez názvu trhu.
public enum Features {
    /// Kolik předchozích svíček je potřeba, než jde featury spočítat.
    public static let warmup = 21

    /// Stav na zavření svíčky `i` (počítá jen se svíčkami 0...i, nikdy s budoucností).
    public static func state(candles: [Hyperliquid.Candle], at i: Int, horizon: Horizon) -> [String: Double]? {
        guard i >= warmup, i < candles.count else { return nil }
        func bps(_ a: Double, _ b: Double) -> Double { a > 0 ? 1e4 * (b / a - 1) : 0 }
        let c = candles[i]

        var steps: [Double] = []
        var hi = -Double.infinity, lo = Double.infinity, sum = 0.0
        for k in (i - 19)...i {
            steps.append(bps(candles[k - 1].close, candles[k].close))
            hi = max(hi, candles[k].high)
            lo = min(lo, candles[k].low)
            sum += candles[k].close
        }
        var vsum = 0.0
        for k in (i - 20)...(i - 1) { vsum += candles[k].volume }
        let vavg = vsum / 20
        let range = c.high - c.low

        return [
            "bar_minutes": Double(horizon.minutes),
            "return_last_bar_bps": rounded(bps(candles[i - 1].close, c.close), 2),
            "return_3_bars_bps": rounded(bps(candles[i - 3].close, c.close), 2),
            "return_12_bars_bps": rounded(bps(candles[i - 12].close, c.close), 2),
            "volatility_20_bars_bps": rounded(populationStdDev(steps), 2),
            "position_in_20_bar_range": rounded(hi > lo ? (c.close - lo) / (hi - lo) : 0.5, 3),
            "volume_vs_20_bar_avg": rounded(vavg > 0 ? c.volume / vavg : 1, 2),
            "close_vs_20_bar_mean_bps": rounded(bps(sum / 20, c.close), 2),
            "last_bar_body_ratio": rounded(range > 0 ? (c.close - c.open) / range : 0, 3),
        ]
    }

    /// Jen uzavřené svíčky (poslední svíčka z API se ještě tvoří).
    public static func closed(_ candles: [Hyperliquid.Candle], horizon: Horizon, nowMs: Int64) -> [Hyperliquid.Candle] {
        candles.filter { $0.openMs + horizon.intervalMs <= nowMs }
    }
}
