import Foundation

/// Jev volání předané strategii.
public struct JevCall: Equatable, Sendable {
    public var side: Side
    public var conf: Double

    public init(side: Side, conf: Double) {
        self.side = side
        self.conf = conf
    }
}

/// Co strategie chce udělat.
public enum StrategyAction: Equatable, Sendable {
    case buy, sell, flat
    case hold(String)

    public var label: String {
        switch self {
        case .buy: return "buy"
        case .sell: return "sell"
        case .flat: return "flat"
        case .hold(let why): return "hold · \(why)"
        }
    }

    /// Cílová pozice, nebo nil pro hold.
    public var target: Int? {
        switch self {
        case .buy: return 1
        case .sell: return -1
        case .flat: return 0
        case .hold: return nil
        }
    }
}

/// Strategie rozhoduje, která Jev volání se stanou obchody. Většina má skončit "hold":
/// každý obchod něco stojí, takže bot, který obchoduje každé volání, krvácí.
///
/// `market` jsou živá čísla, která viděl Jev (return_5s_bps, aggressor_buy_share_30s, …),
/// `position` 1 = long, -1 = short, 0 = flat.
public protocol TradingStrategy: Sendable {
    var summary: String { get }
    func decide(call: JevCall, market: [String: Double], position: Int, secondsSinceTrade: Double) -> StrategyAction
}

/// Výchozí: obchodovat jen při jistotě ≥ minConf a čekat minHold sekund mezi otočkami.
public struct ConvictionStrategy: TradingStrategy {
    public var minConf: Double
    public var minHold: Double

    public init(minConf: Double = 0.85, minHold: Double = 15) {
        self.minConf = minConf
        self.minHold = minHold
    }

    public var summary: String {
        "jen při jistotě ≥\(Int((minConf * 100).rounded())) % · ≥\(Int(minHold)) s mezi otočkami"
    }

    public func decide(call: JevCall, market: [String: Double], position: Int, secondsSinceTrade: Double) -> StrategyAction {
        let want = call.side == .buy ? 1 : -1
        if call.conf < minConf { return .hold("low conviction") }
        if want == position { return .hold(want > 0 ? "already long" : "already short") }
        if secondsSinceTrade < minHold { return .hold("too soon to flip") }
        return call.side == .buy ? .buy : .sell
    }
}

/// Příklad: obchodovat jen po směru trendu (30 s návrat + podíl agresivních nákupů).
public struct TrendStrategy: TradingStrategy {
    public var minConf: Double
    public var buyShare: Double

    public init(minConf: Double = 0.8, buyShare: Double = 0.55) {
        self.minConf = minConf
        self.buyShare = buyShare
    }

    public var summary: String {
        "po trendu · jistota ≥\(Int((minConf * 100).rounded())) % · agresivní nákupy >\(Int((buyShare * 100).rounded())) %"
    }

    public func decide(call: JevCall, market: [String: Double], position: Int, secondsSinceTrade: Double) -> StrategyAction {
        let r30 = market["return_30s_bps"] ?? 0
        let share = market["aggressor_buy_share_30s"] ?? 0.5
        let up = r30 > 0 && share > buyShare
        let down = r30 < 0 && share < 1 - buyShare
        if call.conf < minConf { return .hold("low conviction") }
        if call.side == .buy && up && position != 1 { return .buy }
        if call.side == .sell && down && position != -1 { return .sell }
        return .hold("against the trend")
    }
}

/// Uložitelné nastavení strategie (UI → strategie).
public struct StrategySettings: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case conviction, trend
    }

    public var kind: Kind = .conviction
    public var minConf: Double = 0.85
    public var minHold: Double = 15
    public var trendMinConf: Double = 0.8
    public var trendBuyShare: Double = 0.55

    public init() {}

    public func make() -> TradingStrategy {
        switch kind {
        case .conviction: return ConvictionStrategy(minConf: minConf, minHold: minHold)
        case .trend: return TrendStrategy(minConf: trendMinConf, buyShare: trendBuyShare)
        }
    }
}
