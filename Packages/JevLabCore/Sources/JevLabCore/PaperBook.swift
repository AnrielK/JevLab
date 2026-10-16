import Foundation

public struct EquityPoint: Identifiable, Equatable, Sendable {
    public var t: Double
    public var gross: Double
    public var net: Double
    public var id: Double { t }
    public var date: Date { Date(timeIntervalSince1970: t) }
}

/// Papírová pozice long-or-short o pevné velikosti. Sleduje coiny a hotovost,
/// takže nákup na bidu i prodej na asku se započítá přesně. Poplatky zvlášť.
public struct PaperBook: Sendable {
    public let notional: Double
    public private(set) var pos = 0
    public private(set) var qty = 0.0
    public private(set) var cash = 0.0
    public private(set) var fees = 0.0
    public private(set) var trades = 0
    public private(set) var equity: [EquityPoint] = []

    public init(notional: Double = 1000) {
        self.notional = notional
    }

    public mutating func fill(target: Int, px: Double, feeRate: Double) {
        let dq = Double(target) * notional / px - qty
        cash -= dq * px
        fees += abs(dq) * px * feeRate
        qty += dq
        pos = target
        trades += 1
    }

    public func gross(mid: Double) -> Double { cash + qty * mid }
    public func net(mid: Double) -> Double { gross(mid: mid) - fees }

    public mutating func recordEquity(t: Double, mid: Double) {
        let g = gross(mid: mid)
        equity.append(EquityPoint(t: t, gross: g, net: g - fees))
        if equity.count > 2400 { equity.removeFirst(equity.count - 2400) }
    }
}
