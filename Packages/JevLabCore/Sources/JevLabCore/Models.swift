import Foundation

/// Strana obchodu / Jev volání.
public enum Side: String, Codable, Sendable, CaseIterable {
    case buy, sell
}

/// Nejlepší bid/ask s velikostmi (top of book).
public struct Quote: Equatable, Sendable {
    public var bid: Double
    public var ask: Double
    public var bidSize: Double
    public var askSize: Double
    public var t: Double

    public init(bid: Double, ask: Double, bidSize: Double, askSize: Double, t: Double) {
        self.bid = bid
        self.ask = ask
        self.bidSize = bidSize
        self.askSize = askSize
        self.t = t
    }

    public var mid: Double { (bid + ask) / 2 }

    /// Microprice: cena vážená velikostí na druhé straně knihy.
    public var micro: Double {
        let total = bidSize + askSize
        guard total > 0 else { return mid }
        return (bid * askSize + ask * bidSize) / total
    }

    public var spreadBps: Double { 1e4 * (ask - bid) / mid }
}

/// Jeden obchod z veřejného streamu burzy.
public struct MarketTrade: Equatable, Sendable {
    public var t: Double
    public var isBuy: Bool
    public var px: Double
    public var sz: Double

    public init(t: Double, isBuy: Bool, px: Double, sz: Double) {
        self.t = t
        self.isBuy = isBuy
        self.px = px
        self.sz = sz
    }
}

/// Bod cenového grafu (ztenčený na max. 20 za sekundu).
public struct PriceTick: Identifiable, Equatable, Sendable {
    public var t: Double
    public var micro: Double
    public var bid: Double
    public var ask: Double

    public var id: Double { t }
    public var date: Date { Date(timeIntervalSince1970: t) }

    public init(t: Double, micro: Double, bid: Double, ask: Double) {
        self.t = t
        self.micro = micro
        self.bid = bid
        self.ask = ask
    }
}

/// Stav trhu tak, jak ho vidí Jev: malá, číselná a čerstvá data. Bez data a bez názvu coinu.
public struct MarketSnapshot: Sendable {
    public var mid: Double
    public var micro: Double
    public var bid: Double
    public var ask: Double
    public var spreadBps: Double
    public var state: [String: Double]
}

/// Popisky polí stavu pro UI, v pořadí zobrazení.
public struct StateField: Hashable, Sendable {
    public let key: String
    public let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    public static let labels: [StateField] = [
        StateField("spread_bps", "spread"),
        StateField("microprice_vs_mid_bps", "micro"),
        StateField("top_of_book_imbalance", "imb"),
        StateField("depth5_imbalance", "depth5"),
        StateField("aggressor_buy_share_5s", "agg buy 5s"),
        StateField("aggressor_buy_share_30s", "agg buy 30s"),
        StateField("trades_last_5s", "obchody/5s"),
        StateField("return_5s_bps", "ret 5s"),
        StateField("return_30s_bps", "ret 30s"),
        StateField("tick_volatility_60s_bps", "vol 60s"),
    ]
}

/// Zaokrouhlení na `places` desetinných míst.
@inline(__always)
func rounded(_ x: Double, _ places: Int) -> Double {
    let f = pow(10.0, Double(places))
    return (x * f).rounded() / f
}

/// Čas v sekundách od epochy.
@inline(__always)
func nowSeconds() -> Double { Date().timeIntervalSince1970 }

/// Číselná hodnota z JSON (NSNumber, Double, Int nebo text).
func jsonNumber(_ v: Any?) -> Double? {
    if v is NSNull { return nil }
    if let n = v as? NSNumber { return n.doubleValue }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}
