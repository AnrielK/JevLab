import Foundation

/// Úroveň supportu/rezistence ze shluku swing bodů.
public struct SRLevel: Equatable, Sendable {
    public var price: Double
    /// Kolikrát se cena od úrovně otočila (počet swing bodů ve shluku).
    public var touches: Int
}

/// Klasické indikátory a support/rezistence. Vše se počítá jen ze svíček 0...end (bez budoucnosti).
public enum Indicators {
    /// Prostý klouzavý průměr zavíracích cen posledních `n` svíček končících na `end`.
    public static func sma(_ c: [Hyperliquid.Candle], end: Int, n: Int) -> Double? {
        guard n > 0, end >= n - 1, end < c.count else { return nil }
        var s = 0.0
        for k in (end - n + 1)...end { s += c[k].close }
        return s / Double(n)
    }

    /// RSI (Wilder). Počítá se z okna max. 4·n svíček, aby výsledek nezávisel na délce historie.
    public static func rsi(_ c: [Hyperliquid.Candle], end: Int, n: Int = 14) -> Double? {
        guard end >= n, end < c.count else { return nil }
        let start = max(1, end - 4 * n + 1)
        guard end - start + 1 >= n else { return nil }
        var gain = 0.0, loss = 0.0
        for k in start..<(start + n) {
            let d = c[k].close - c[k - 1].close
            if d > 0 { gain += d } else { loss -= d }
        }
        gain /= Double(n)
        loss /= Double(n)
        var k = start + n
        while k <= end {
            let d = c[k].close - c[k - 1].close
            gain = (gain * Double(n - 1) + max(d, 0)) / Double(n)
            loss = (loss * Double(n - 1) + max(-d, 0)) / Double(n)
            k += 1
        }
        if loss == 0 { return gain == 0 ? 50 : 100 }
        return 100 - 100 / (1 + gain / loss)
    }

    /// ATR (Wilder), v cenových jednotkách. Okno max. 4·n svíček.
    public static func atr(_ c: [Hyperliquid.Candle], end: Int, n: Int = 14) -> Double? {
        guard end >= n, end < c.count else { return nil }
        let start = max(1, end - 4 * n + 1)
        guard end - start + 1 >= n else { return nil }
        func tr(_ k: Int) -> Double {
            let pc = c[k - 1].close
            return max(c[k].high - c[k].low, abs(c[k].high - pc), abs(c[k].low - pc))
        }
        var a = 0.0
        for k in start..<(start + n) { a += tr(k) }
        a /= Double(n)
        var k = start + n
        while k <= end {
            a = (a * Double(n - 1) + tr(k)) / Double(n)
            k += 1
        }
        return a
    }

    /// Swing body: high/low svíčky `j` je extrém mezi `k` svíčkami na obou stranách.
    /// Bod je potvrzený, až když `j + k <= end` (pravé svíčky jsou uzavřené).
    public static func pivots(_ c: [Hyperliquid.Candle], end: Int, k: Int, lookback: Int) -> [Double] {
        guard k > 0, end < c.count else { return [] }
        let first = max(k, end - lookback + 1)
        let last = end - k
        guard first <= last else { return [] }
        var out: [Double] = []
        for j in first...last {
            var isHigh = true, isLow = true
            for m in (j - k)...(j + k) where m != j {
                // nalevo ostře, napravo neostře: rovná maxima se nepočítají dvakrát
                if m < j {
                    if c[m].high >= c[j].high { isHigh = false }
                    if c[m].low <= c[j].low { isLow = false }
                } else {
                    if c[m].high > c[j].high { isHigh = false }
                    if c[m].low < c[j].low { isLow = false }
                }
            }
            if isHigh { out.append(c[j].high) }
            if isLow { out.append(c[j].low) }
        }
        return out
    }

    /// Shluky swing bodů do úrovní: body bližší než `tolerance` se slučují (průměr ceny, počet dotyků).
    public static func levels(from points: [Double], tolerance: Double) -> [SRLevel] {
        var out: [SRLevel] = []
        for p in points.sorted() {
            if let last = out.last, p - last.price <= tolerance {
                let n = Double(last.touches)
                out[out.count - 1] = SRLevel(price: (last.price * n + p) / (n + 1), touches: last.touches + 1)
            } else {
                out.append(SRLevel(price: p, touches: 1))
            }
        }
        return out
    }

    /// Nejbližší support pod cenou a rezistence nad cenou.
    public static func nearest(_ levels: [SRLevel], price: Double) -> (support: SRLevel?, resistance: SRLevel?) {
        let support = levels.filter { $0.price < price }.max { $0.price < $1.price }
        let resistance = levels.filter { $0.price > price }.min { $0.price < $1.price }
        return (support, resistance)
    }

    /// Featury indikátorů a S/R pro svíčky 0...end při ceně `price`.
    /// - pivotK: šířka swingu (svíček na každou stranu), lookback: kolik svíček zpět hledat úrovně.
    public static func features(_ c: [Hyperliquid.Candle], end: Int, price: Double, prefix p: String,
                                pivotK: Int, lookback: Int, maPeriods: [Int], includeSR: Bool = true) -> [String: Double] {
        guard end >= 1, end < c.count, price > 0 else { return [:] }
        func bps(_ a: Double, _ b: Double) -> Double { a > 0 ? 1e4 * (b / a - 1) : 0 }
        var f: [String: Double] = [:]
        for n in maPeriods {
            if let m = sma(c, end: end, n: n) { f[p + "ma\(n)_dist_bps"] = rounded(bps(m, price), 1) }
        }
        if let first = maPeriods.first, let now = sma(c, end: end, n: first), let before = sma(c, end: end - 5, n: first) {
            f[p + "ma\(first)_slope_5bars_bps"] = rounded(bps(before, now), 1)
        }
        if let r = rsi(c, end: end) { f[p + "rsi14"] = rounded(r, 1) }
        let atrValue = atr(c, end: end)
        if let a = atrValue { f[p + "atr14_bps"] = rounded(1e4 * a / price, 1) }
        let win = min(50, end + 1)
        if win >= 10 {
            var hi = -Double.infinity, lo = Double.infinity
            for k in (end - win + 1)...end {
                hi = max(hi, c[k].high)
                lo = min(lo, c[k].low)
            }
            f[p + "dist_from_\(win)bar_high_bps"] = rounded(bps(hi, price), 1)
            f[p + "dist_from_\(win)bar_low_bps"] = rounded(bps(lo, price), 1)
        }
        guard includeSR else { return f }
        let tol = (atrValue ?? price * 0.005) * 0.5
        let lv = levels(from: pivots(c, end: end, k: pivotK, lookback: lookback), tolerance: tol)
        let near = nearest(lv, price: price)
        if let s = near.support {
            f[p + "support_dist_bps"] = rounded(bps(s.price, price), 1)
            if let a = atrValue, a > 0 { f[p + "support_dist_atr"] = rounded((price - s.price) / a, 2) }
            f[p + "support_touches"] = Double(s.touches)
        }
        if let r = near.resistance {
            f[p + "resistance_dist_bps"] = rounded(bps(price, r.price), 1)
            if let a = atrValue, a > 0 { f[p + "resistance_dist_atr"] = rounded((r.price - price) / a, 2) }
            f[p + "resistance_touches"] = Double(r.touches)
        }
        return f
    }
}
