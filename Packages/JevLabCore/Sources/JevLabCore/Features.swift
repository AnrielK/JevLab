import Foundation

/// Časový rámec svíček na Hyperliquid (i pro kontext).
public enum Timeframe: String, Codable, CaseIterable, Sendable {
    case m15 = "15m", h1 = "1h", h2 = "2h", h4 = "4h", d1 = "1d", w1 = "1w", mo1 = "1M"

    /// Přibližná délka v minutách (měsíc = 30 dní; pro uzavření svíčky se u měsíce používá kalendář).
    public var minutes: Int {
        switch self {
        case .m15: return 15
        case .h1: return 60
        case .h2: return 120
        case .h4: return 240
        case .d1: return 1440
        case .w1: return 10_080
        case .mo1: return 43_200
        }
    }

    /// Prefix featur, aby Jev věděl, ze kterého rámce číslo je.
    public var prefix: String {
        switch self {
        case .m15: return "15m_"
        case .h1: return "1h_"
        case .h2: return "2h_"
        case .h4: return "4h_"
        case .d1: return "daily_"
        case .w1: return "weekly_"
        case .mo1: return "monthly_"
        }
    }

    public var label: String {
        switch self {
        case .m15: return "15m"
        case .h1: return "1h"
        case .h2: return "2h"
        case .h4: return "4h"
        case .d1: return "1D"
        case .w1: return "1W"
        case .mo1: return "1M"
        }
    }

    /// Čas uzavření svíčky (ms). U měsíce podle kalendáře v UTC.
    public func closeMs(openMs: Int64) -> Int64 {
        guard self == .mo1 else { return openMs + Int64(minutes) * 60_000 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let open = Date(timeIntervalSince1970: Double(openMs) / 1000)
        let close = cal.date(byAdding: .month, value: 1, to: open) ?? open.addingTimeInterval(30 * 86_400)
        return Int64(close.timeIntervalSince1970 * 1000)
    }
}

/// Horizont rozhodování pro svíčkový režim (backtest i živý běh).
public enum Horizon: String, Codable, CaseIterable, Sendable, Identifiable {
    case m5 = "5m"
    case m15 = "15m"
    case h1 = "1h"
    case h4 = "4h"
    case d1 = "1d"

    public var id: String { rawValue }
    /// Interval pro Hyperliquid candleSnapshot.
    public var interval: String { rawValue }

    public var minutes: Int {
        switch self {
        case .m5: return 5
        case .m15: return 15
        case .h1: return 60
        case .h4: return 240
        case .d1: return 1440
        }
    }

    public var intervalMs: Int64 { Int64(minutes) * 60_000 }

    public var label: String {
        switch self {
        case .m5: return "5 min"
        case .m15: return "15 min"
        case .h1: return "1 hodina"
        case .h4: return "4 hodiny"
        case .d1: return "1 den"
        }
    }

    public var shortLabel: String {
        switch self {
        case .m5: return "5m"
        case .m15: return "15m"
        case .h1: return "1h"
        case .h4: return "4h"
        case .d1: return "1D"
        }
    }

    /// Kontextové rámce: jeden nižší a vyšší (pro denní obchodování 4h, týden a měsíc).
    public var context: [Timeframe] {
        switch self {
        case .m5: return [.h1]
        case .m15: return [.h1, .h4]
        case .h1: return [.m15, .h4, .d1]
        case .h4: return [.h1, .d1, .w1]
        case .d1: return [.h4, .w1, .mo1]
        }
    }

    /// Hyperliquid vrací zhruba posledních 5000 svíček na interval, víc historie nejde.
    public var maxDays: Double {
        Double(5000 - Features.warmup - Features.history - 5) * Double(minutes) / 1440
    }

    /// Kolik dní historie jde s kontextem (nižší rámec má taky jen ~5000 svíček).
    public var maxDaysWithContext: Double {
        var m = maxDays
        for tf in context where tf.minutes < minutes {
            m = min(m, Double(5000 - 60) * Double(tf.minutes) / 1440)
        }
        return m
    }

    /// Otázka pro Jev: kam bude cena na konci další svíčky.
    public var question: [String: JevQuestion] {
        let h: String
        if minutes >= 1440 {
            h = "\(minutes / 1440)-day"
        } else if minutes >= 60 {
            h = "\(minutes / 60)-hour"
        } else {
            h = "\(minutes)-minute"
        }
        return ["side": .choice(
            "Will the price close higher or lower at the end of the next \(h) bar? buy = higher (be long), sell = lower (be short). Fields prefixed with a timeframe (e.g. weekly_, monthly_, 4h_) describe that timeframe; unprefixed fields describe the trading timeframe.",
            ["buy", "sell"])]
    }
}

/// Featury ze svíček, které Jev vidí ve svíčkovém režimu. Jen čísla, bez data a bez názvu trhu.
public enum Features {
    /// Kolik předchozích svíček je potřeba, než jde featury spočítat.
    public static let warmup = 21
    /// Kolik svíček historie se stáhne navíc před backtestem, aby existovaly MA200 a S/R.
    public static let history = 200

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

    /// Featury z jiného časového rámce v okamžiku `tMs` (ms). Používá jen svíčky uzavřené do `tMs`;
    /// u právě se tvořící svíčky jen její otevírací cenu (ta je v tu chvíli známá). Nikdy budoucnost.
    public static func context(_ tf: Timeframe, candles: [Hyperliquid.Candle], tMs: Int64, price: Double,
                               includeSR: Bool = true) -> [String: Double] {
        func bps(_ a: Double, _ b: Double) -> Double { a > 0 ? 1e4 * (b / a - 1) : 0 }
        var closed: [Hyperliquid.Candle] = []
        var forming: Hyperliquid.Candle?
        for c in candles {
            if tf.closeMs(openMs: c.openMs) <= tMs {
                closed.append(c)
            } else if c.openMs <= tMs {
                forming = c
            }
        }
        guard closed.count >= 2, let last = closed.last else { return [:] }
        let p = tf.prefix
        var out: [String: Double] = [:]
        out[p + "return_last_bar_bps"] = rounded(bps(closed[closed.count - 2].close, last.close), 2)
        if closed.count >= 4 {
            out[p + "return_3_bars_bps"] = rounded(bps(closed[closed.count - 4].close, last.close), 2)
        }
        let n = min(10, closed.count)
        let recent = closed.suffix(n)
        let mean = recent.reduce(0) { $0 + $1.close } / Double(n)
        if n == 10 { out[p + "price_vs_10_bar_mean_bps"] = rounded(bps(mean, price), 2) }
        let r = closed.suffix(min(12, closed.count))
        let hi = max(r.map(\.high).max() ?? price, price)
        let lo = min(r.map(\.low).min() ?? price, price)
        out[p + "position_in_range"] = rounded(hi > lo ? (price - lo) / (hi - lo) : 0.5, 3)
        if closed.count >= 3 {
            var steps: [Double] = []
            let k = Array(closed.suffix(min(11, closed.count)))
            for j in 1..<k.count { steps.append(bps(k[j - 1].close, k[j].close)) }
            out[p + "volatility_bps"] = rounded(populationStdDev(steps), 2)
        }
        if let f = forming {
            out[p + "current_bar_so_far_bps"] = rounded(bps(f.open, price), 2)
        }
        // indikátory a support/rezistence z uzavřených svíček tohoto rámce
        let ind = Indicators.features(closed, end: closed.count - 1, price: price, prefix: p,
                                      pivotK: tf == .mo1 ? 1 : 2, lookback: tf == .mo1 ? 36 : 60,
                                      maPeriods: [10, 20], includeSR: includeSR)
        for (k, v) in ind { out[k] = v }
        return out
    }

    /// Posledních `count` svíček otevřených nejpozději v `tMs` (seřazený seznam, binární hledání).
    /// Kontext potřebuje jen pár desítek svíček zpět; u dlouhé historie to výpočet výrazně zrychlí.
    public static func window(_ list: [Hyperliquid.Candle], upTo tMs: Int64, count: Int) -> [Hyperliquid.Candle] {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].openMs <= tMs { lo = mid + 1 } else { hi = mid }
        }
        return Array(list[max(0, lo - count)..<lo])
    }

    /// Stav pro svíčku `i` primárního rámce + kontext z dalších rámců (klíč = Timeframe).
    public static func state(candles: [Hyperliquid.Candle], at i: Int, horizon: Horizon,
                             context: [Timeframe: [Hyperliquid.Candle]]) -> [String: Double]? {
        guard var s = state(candles: candles, at: i, horizon: horizon) else { return nil }
        // indikátory a support/rezistence obchodního rámce
        for (k, v) in Indicators.features(candles, end: i, price: candles[i].close, prefix: "",
                                          pivotK: 3, lookback: 120, maPeriods: [20, 50, 200]) { s[k] = v }
        let tMs = candles[i].openMs + horizon.intervalMs
        for (tf, list) in context {
            // S/R hlavně z obchodního a vyšších rámců; nižší rámec dává jen texturu
            let higher = tf.minutes > horizon.minutes
            let win = window(list, upTo: tMs, count: 90)
            for (k, v) in Features.context(tf, candles: win, tMs: tMs, price: candles[i].close, includeSR: higher) { s[k] = v }
        }
        // hotové kombinace (S/R + RSI + trend), aby je Jev nemusel odvozovat
        for (k, v) in Setups.flags(s) { s[k] = v }
        return s
    }

    /// Jen uzavřené svíčky (poslední svíčka z API se ještě tvoří).
    public static func closed(_ candles: [Hyperliquid.Candle], horizon: Horizon, nowMs: Int64) -> [Hyperliquid.Candle] {
        candles.filter { $0.openMs + horizon.intervalMs <= nowMs }
    }
}
