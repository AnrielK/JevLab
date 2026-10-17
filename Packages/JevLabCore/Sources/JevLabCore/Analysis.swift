import Foundation

/// Jedno Jev rozhodnutí uložené do databáze, včetně toho, co trh udělal potom.
public struct CallRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    /// Čas rozhodnutí (s od epochy).
    public var t: Double
    public var side: Side?
    public var conf: Double?
    /// Cena v okamžiku rozhodnutí.
    public var price: Double
    /// Pohyb ceny po rozhodnutí v bps (do další svíčky / dalšího volání). nil = ještě neznámý.
    public var retNextBps: Double?
    /// Co Jev viděl (featury), aby se z toho dalo později učit.
    public var state: [String: Double]?
    public var action: String?
    /// Claudův směr platný v okamžiku rozhodnutí (nil = Claude nebyl zapnutý / ještě neodpověděl).
    public var bias: Bias?

    public init(id: Int, t: Double, side: Side?, conf: Double?, price: Double, retNextBps: Double? = nil,
                state: [String: Double]? = nil, action: String? = nil, bias: Bias? = nil) {
        self.bias = bias
        self.id = id
        self.t = t
        self.side = side
        self.conf = conf
        self.price = price
        self.retNextBps = retNextBps
        self.state = state
        self.action = action
    }

    public var date: Date { Date(timeIntervalSince1970: t) }
    /// +1 buy, -1 sell, 0 bez volání.
    public var sign: Double { side == .buy ? 1 : side == .sell ? -1 : 0 }
}

public struct SimPoint: Identifiable, Sendable, Equatable {
    public var t: Double
    public var netUsd: Double
    public var id: Double { t }
    public var date: Date { Date(timeIntervalSince1970: t) }
}

public struct SimResult: Sendable, Equatable {
    public var steps = 0
    public var trades = 0
    public var grossBps = 0.0
    public var feesBps = 0.0
    public var hits = 0
    public var exposed = 0
    public var equity: [SimPoint] = []

    public var netBps: Double { grossBps - feesBps }
    public var hitRate: Double? { exposed > 0 ? Double(hits) / Double(exposed) : nil }
    public func usd(_ bps: Double, notional: Double) -> Double { bps / 1e4 * notional }
}

public struct CalibrationBucket: Identifiable, Sendable, Equatable {
    public var lower: Double
    public var upper: Double
    public var count: Int
    public var hits: Int
    public var avgSignedBps: Double
    public var id: Double { lower }
    public var hitRate: Double? { count > 0 ? Double(hits) / Double(count) : nil }
}

public struct ThresholdPoint: Identifiable, Sendable, Equatable {
    public var threshold: Double
    public var result: SimResult
    public var id: Double { threshold }
}

public struct WalkForward: Sendable, Equatable {
    /// Práh vybraný na první polovině dat.
    public var chosen: Double
    public var trainNetBps: Double
    /// Výsledek vybraného prahu na druhé polovině (data, která výběr „neviděl“).
    public var testNetBps: Double
    public var testDefaultNetBps: Double
    public var testBuyHoldBps: Double
    public var trainCount: Int
    public var testCount: Int
}

/// Kdo rozhoduje o pozici při simulaci.
public enum SimMode: String, CaseIterable, Sendable {
    /// Jen Jev: směr Jev při jistotě ≥ práh, jinak flat.
    case jev
    /// Jev jen ve směru Claudova biasu (flat bias = mimo trh, bez biasu = mimo trh).
    case jevClaude
    /// Jen Claude: pozice = bias (long/short/flat), Jev se ignoruje.
    case claude

    public var label: String {
        switch self {
        case .jev: return "Jev sám"
        case .jevClaude: return "Jev + Claude"
        case .claude: return "Claude sám"
        }
    }
}

/// „Učení“ z databáze: všechno se počítá z uložených rozhodnutí, bez dalších Jev volání.
public enum Analysis {
    public static let thresholds: [Double] = stride(from: 0.5, through: 0.951, by: 0.05).map { rounded($0, 2) }

    /// Pozice na každý krok: Jev side, když jistota ≥ minConf, jinak flat. Poplatek za každou změnu pozice.
    /// `feeRate` je poplatek na stranu (např. 0.00045 = 4.5 bps), přechod long→short platí dvě strany.
    public static func simulate(_ records: [CallRecord], minConf: Double, feeRate: Double, notional: Double = 1000,
                                mode: SimMode = .jev) -> SimResult {
        var r = SimResult()
        var pos = 0.0
        for rec in records {
            guard let ret = rec.retNextBps else { continue }
            let jev: Double = (rec.side != nil && (rec.conf ?? 0) >= minConf) ? rec.sign : 0
            let claude: Double = rec.bias == .long ? 1 : rec.bias == .short ? -1 : 0
            let target: Double
            switch mode {
            case .jev: target = jev
            case .jevClaude: target = (claude != 0 && jev == claude) ? jev : 0
            case .claude: target = claude
            }
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

    /// Je jistota Jev k něčemu? Pro každé pásmo jistoty: kolikrát měl pravdu a průměrný pohyb v jeho směru.
    public static func calibration(_ records: [CallRecord]) -> [CalibrationBucket] {
        let edges: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0001]
        var out: [CalibrationBucket] = []
        for k in 0..<(edges.count - 1) {
            let sel = records.filter {
                guard $0.side != nil, let c = $0.conf, $0.retNextBps != nil else { return false }
                return c >= edges[k] && c < edges[k + 1]
            }
            let signed = sel.map { $0.sign * ($0.retNextBps ?? 0) }
            out.append(CalibrationBucket(lower: edges[k], upper: min(1, edges[k + 1]), count: sel.count,
                                         hits: signed.filter { $0 > 0 }.count,
                                         avgSignedBps: signed.isEmpty ? 0 : signed.reduce(0, +) / Double(signed.count)))
        }
        return out
    }

    public static func sweep(_ records: [CallRecord], feeRate: Double, mode: SimMode = .jev) -> [ThresholdPoint] {
        thresholds.map { ThresholdPoint(threshold: $0, result: simulate(records, minConf: $0, feeRate: feeRate, mode: mode)) }
    }

    /// Držet long se stálou pozicí (stejně jako simulace strategií: každou svíčku $1000, bez úročení),
    /// minus jeden vstupní poplatek. Férový základ pro strategie s pevnou velikostí pozice.
    public static func holdFixedBps(_ records: [CallRecord], feeRate: Double) -> Double {
        records.reduce(0) { $0 + ($1.retNextBps ?? 0) } - feeRate * 1e4
    }

    /// Kupit a držet za stejné období (srovnávací základ).
    public static func buyHoldBps(_ records: [CallRecord]) -> Double {
        var g = 1.0
        for r in records { if let ret = r.retNextBps { g *= 1 + ret / 1e4 } }
        return (g - 1) * 1e4
    }

    /// Poctivý test: práh se vybere na první polovině, vyhodnotí na druhé.
    public static func walkForward(_ records: [CallRecord], feeRate: Double, defaultThreshold: Double,
                                   mode: SimMode = .jev) -> WalkForward? {
        let done = records.filter { $0.retNextBps != nil }
        guard done.count >= 20 else { return nil }
        let mid = done.count / 2
        let train = Array(done[..<mid])
        let test = Array(done[mid...])
        var best = thresholds[0]
        var bestNet = -Double.infinity
        for th in thresholds {
            let net = simulate(train, minConf: th, feeRate: feeRate, mode: mode).netBps
            if net >= bestNet {
                bestNet = net
                best = th
            }
        }
        return WalkForward(chosen: best, trainNetBps: bestNet,
                           testNetBps: simulate(test, minConf: best, feeRate: feeRate, mode: mode).netBps,
                           testDefaultNetBps: simulate(test, minConf: defaultThreshold, feeRate: feeRate, mode: mode).netBps,
                           testBuyHoldBps: buyHoldBps(test), trainCount: train.count, testCount: test.count)
    }

    /// Má záznam Claudovy biasy (běh s Claudem)?
    public static func hasBias(_ records: [CallRecord]) -> Bool {
        records.contains { $0.bias != nil }
    }

    /// Výsledek na druhé polovině dat (stejná část jako walk-forward test) pro daný režim a práh.
    public static func testHalf(_ records: [CallRecord], minConf: Double, feeRate: Double, mode: SimMode) -> SimResult? {
        let done = records.filter { $0.retNextBps != nil }
        guard done.count >= 20 else { return nil }
        return simulate(Array(done[(done.count / 2)...]), minConf: minConf, feeRate: feeRate, mode: mode)
    }

    /// Pro tick režim: výsledek každého volání = pohyb ceny do dalšího volání s jinou cenou.
    public static func fillTickOutcomes(_ records: [CallRecord]) -> [CallRecord] {
        var out = records
        for i in out.indices {
            if let j = out[(i + 1)...].firstIndex(where: { $0.price != out[i].price }), out[i].price > 0 {
                out[i].retNextBps = rounded(1e4 * (out[j].price / out[i].price - 1), 3)
            }
        }
        return out
    }
}
