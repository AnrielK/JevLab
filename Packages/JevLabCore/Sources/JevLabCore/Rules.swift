import Foundation

/// Kombinovaná pravidla nad featurami (support/rezistence + RSI + trend). Stejná logika slouží
/// jako signály setupů pro Jev i jako samostatné strategie pro srovnání (bez dalších volání).
public enum Setups {
    /// +1 = signál long, -1 = short, 0 = nic. nil pole = pravidlo neplatí.
    public static func supportBounce(_ s: [String: Double]) -> Double {
        if let d = s["support_dist_atr"], let r = s["rsi14"], d <= 1.0, r <= 40 { return 1 }
        if let d = s["resistance_dist_atr"], let r = s["rsi14"], d <= 1.0, r >= 60 { return -1 }
        return 0
    }

    /// Cena do ½ ATR od 50svíčkového maxima při rostoucí MA20 (long), nebo u minima při klesající (short).
    public static func breakout(_ s: [String: Double]) -> Double {
        guard let slope = s["ma20_slope_5bars_bps"], let atr = s["atr14_bps"] else { return 0 }
        if let h = s["dist_from_50bar_high_bps"], h >= -0.5 * atr, slope > 0 { return 1 }
        if let l = s["dist_from_50bar_low_bps"], l <= 0.5 * atr, slope < 0 { return -1 }
        return 0
    }

    public static func maTrend(_ s: [String: Double]) -> Double {
        guard let m20 = s["ma20_dist_bps"], let m50 = s["ma50_dist_bps"], let slope = s["ma20_slope_5bars_bps"] else { return 0 }
        if m20 > 0, m50 > 0, slope > 0 { return 1 }
        if m20 < 0, m50 < 0, slope < 0 { return -1 }
        return 0
    }

    public static func rsiReversion(_ s: [String: Double]) -> Double {
        guard let r = s["rsi14"] else { return 0 }
        if r <= 30 { return 1 }
        if r >= 70 { return -1 }
        return 0
    }

    /// Obchod ve směru týdenního trendu, vstup na denním pullbacku.
    public static func weeklyPullback(_ s: [String: Double]) -> Double {
        guard let w = s["weekly_ma10_dist_bps"], let r = s["rsi14"] else { return 0 }
        if w > 0, r < 45 { return 1 }
        if w < 0, r > 55 { return -1 }
        return 0
    }

    /// Příznaky setupů, které dostane Jev (a Claude) jako hotová čísla.
    public static func flags(_ s: [String: Double]) -> [String: Double] {
        let sb = supportBounce(s), bo = breakout(s), tr = maTrend(s)
        var f: [String: Double] = [
            "setup_support_bounce": sb > 0 ? 1 : 0,
            "setup_resistance_rejection": sb < 0 ? 1 : 0,
            "setup_breakout_up": bo > 0 ? 1 : 0,
            "setup_breakdown": bo < 0 ? 1 : 0,
            "setup_ma_trend": tr,
        ]
        if s["weekly_ma10_dist_bps"] != nil { f["setup_weekly_pullback"] = weeklyPullback(s) }
        return f
    }
}

/// Pravidlová strategie pro srovnání.
public struct RuleStrategy: Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var signal: ([String: Double]) -> Double

    public static let all: [RuleStrategy] = [
        RuleStrategy(id: "bounce", name: "Odraz S/R + RSI", detail: "long ≤1 ATR nad supportem a RSI ≤ 40; short ≤1 ATR pod rezistencí a RSI ≥ 60",
                     signal: Setups.supportBounce),
        RuleStrategy(id: "breakout", name: "Průraz", detail: "long do ½ ATR od 50svíčkového maxima při rostoucí MA20; short u minima při klesající",
                     signal: Setups.breakout),
        RuleStrategy(id: "trend", name: "Trend MA", detail: "long nad MA20 i MA50 s rostoucí MA20; short naopak",
                     signal: Setups.maTrend),
        RuleStrategy(id: "rsi", name: "RSI návrat", detail: "long při RSI ≤ 30, short při RSI ≥ 70",
                     signal: Setups.rsiReversion),
        RuleStrategy(id: "weekly", name: "Týdenní trend + pullback", detail: "nad týdenní MA10 kupovat při denním RSI < 45; pod ní prodávat při RSI > 55",
                     signal: Setups.weeklyPullback),
    ]
}

public struct RuleResult: Identifiable {
    public var rule: RuleStrategy
    public var full: SimResult
    public var test: SimResult?
    public var signals: Int
    public var id: String { rule.id }
}

extension Analysis {
    /// Simulace z cílových pozic (−1/0/+1) na každé rozhodnutí; poplatek za každou změnu pozice.
    public static func simulate(_ records: [CallRecord], targets: [Double], feeRate: Double, notional: Double = 1000) -> SimResult {
        var r = SimResult()
        var pos = 0.0
        for (rec, target) in zip(records, targets) {
            guard let ret = rec.retNextBps else { continue }
            if target != pos {
                r.feesBps += abs(target - pos) * feeRate * 1e4
                r.trades += 1
                pos = target
            }
            r.grossBps += pos * ret
            if pos != 0 {
                r.exposed += 1
                if pos * ret > 0 { r.hits += 1 }
            }
            r.steps += 1
            r.equity.append(SimPoint(t: rec.t, netUsd: r.usd(r.grossBps - r.feesBps, notional: notional)))
        }
        return r
    }

    /// Pozice z pravidla: signál otevře/otočí pozici, bez signálu se drží max. `hold` svíček, pak flat.
    public static func ruleTargets(_ records: [CallRecord], rule: RuleStrategy, hold: Int) -> [Double] {
        var out: [Double] = []
        var pos = 0.0
        var age = 0
        for rec in records {
            let sig = rec.state.map(rule.signal) ?? 0
            if sig != 0 {
                pos = sig
                age = 0
            } else if pos != 0 {
                age += 1
                if age >= hold { pos = 0 }
            }
            out.append(pos)
        }
        return out
    }

    public static func rules(_ records: [CallRecord], feeRate: Double, hold: Int = 5) -> [RuleResult] {
        let done = records.filter { $0.retNextBps != nil && $0.state != nil }
        guard !done.isEmpty else { return [] }
        let half = done.count / 2
        return RuleStrategy.all.map { rule in
            let t = ruleTargets(done, rule: rule, hold: hold)
            let full = simulate(done, targets: t, feeRate: feeRate)
            var test: SimResult?
            if done.count >= 20 {
                // stejná pravidla, jen druhá polovina (pozice se počítá souvisle, vyhodnocení od poloviny)
                test = simulate(Array(done[half...]), targets: Array(t[half...]), feeRate: feeRate)
            }
            let signals = done.filter { rule.signal($0.state ?? [:]) != 0 }.count
            return RuleResult(rule: rule, full: full, test: test, signals: signals)
        }
    }
}
