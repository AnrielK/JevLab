import Foundation

/// Živý stav trhu jednoho coinu: nejlepší bid/ask, hloubka top-5 a všechny obchody.
/// Čistá hodnotová struktura bez sítě, aby šla testovat.
public struct MarketBook {
    public struct MidPoint: Equatable {
        public var t: Double
        public var mid: Double
    }

    public private(set) var quote: Quote?
    /// Objem v USD na prvních pěti úrovních (bid, ask).
    public private(set) var depth5: (bid: Double, ask: Double)?
    public private(set) var mids: [MidPoint] = []
    public private(set) var trades: [MarketTrade] = []
    public private(set) var ticks: [PriceTick] = []

    public var midKeep: Double = 120
    public var tradeKeep: Double = 120
    public var tickKeep: Double = 300

    public init() {}

    public mutating func apply(quote q: Quote) {
        quote = q
        mids.append(MidPoint(t: q.t, mid: q.mid))
        if let last = ticks.last, q.t - last.t < 0.05 {
            // ztenčení na max. 20 bodů za sekundu
        } else {
            ticks.append(PriceTick(t: q.t, micro: q.micro, bid: q.bid, ask: q.ask))
        }
        prune(now: q.t)
    }

    public mutating func apply(depthBidUSD: Double, depthAskUSD: Double) {
        depth5 = (depthBidUSD, depthAskUSD)
    }

    public mutating func apply(trades new: [MarketTrade], now: Double) {
        trades.append(contentsOf: new)
        prune(now: now)
    }

    mutating func prune(now: Double) {
        if let i = mids.firstIndex(where: { now - $0.t <= midKeep }), i > 0 { mids.removeFirst(i) }
        else if let last = mids.last, now - last.t > midKeep { mids.removeAll() }
        if let i = trades.firstIndex(where: { now - $0.t <= tradeKeep }), i > 0 { trades.removeFirst(i) }
        else if let last = trades.last, now - last.t > tradeKeep { trades.removeAll() }
        if let i = ticks.firstIndex(where: { now - $0.t <= tickKeep }), i > 0 { ticks.removeFirst(i) }
        else if let last = ticks.last, now - last.t > tickKeep { ticks.removeAll() }
    }

    /// Stav, který vidí Jev. `nil`, dokud nepřišla první cena.
    public func snapshot(now: Double) -> MarketSnapshot? {
        guard let q = quote else { return nil }
        let mid = q.mid
        let micro = q.micro

        func ret(_ sec: Double) -> Double {
            let past = mids.first(where: { $0.t >= now - sec })?.mid ?? mid
            return rounded(1e4 * (mid / past - 1), 2)
        }

        func flow(_ sec: Double) -> (share: Double, count: Int) {
            var vol = 0.0, buyVol = 0.0, n = 0
            for tr in trades where tr.t >= now - sec {
                let v = tr.px * tr.sz
                vol += v
                if tr.isBuy { buyVol += v }
                n += 1
            }
            return (vol > 0 ? rounded(buyVol / vol, 3) : 0.5, n)
        }

        let f5 = flow(5)
        let f30 = flow(30)
        let m60 = mids.filter { $0.t >= now - 60 }.map(\.mid)
        var steps: [Double] = []
        if m60.count > 1 {
            for k in 1..<m60.count where m60[k - 1] != m60[k] {
                steps.append(1e4 * (m60[k] / m60[k - 1] - 1))
            }
        }

        var state: [String: Double] = [
            "spread_bps": rounded(1e4 * (q.ask - q.bid) / mid, 3),
            "microprice_vs_mid_bps": rounded(1e4 * (micro / mid - 1), 3),
            "top_of_book_imbalance": rounded((q.bidSize - q.askSize) / (q.bidSize + q.askSize), 3),
            "aggressor_buy_share_5s": f5.share,
            "aggressor_buy_share_30s": f30.share,
            "trades_last_5s": Double(f5.count),
            "return_5s_bps": ret(5),
            "return_30s_bps": ret(30),
            "tick_volatility_60s_bps": steps.count > 2 ? rounded(populationStdDev(steps), 3) : 0,
        ]
        if let d = depth5, d.bid + d.ask > 0 {
            state["depth5_imbalance"] = rounded((d.bid - d.ask) / (d.bid + d.ask), 3)
        }
        return MarketSnapshot(mid: mid, micro: micro, bid: q.bid, ask: q.ask, spreadBps: q.spreadBps, state: state)
    }

    public func trades(since t0: Double) -> [MarketTrade] {
        trades.filter { $0.t >= t0 }
    }

    public func recentTicks(seconds: Double, now: Double) -> [PriceTick] {
        ticks.filter { $0.t >= now - seconds }
    }
}

func populationStdDev(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let mean = xs.reduce(0, +) / Double(xs.count)
    let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
    return v.squareRoot()
}
