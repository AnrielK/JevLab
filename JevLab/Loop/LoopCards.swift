import SwiftUI
import Charts
import JevLabCore

/// Živý cenový graf (posledních 60 s): microprice, pásmo bid/ask, Jev volání a obchody.
struct PriceChart: View {
    @Environment(AppModel.self) private var model
    private let window: Double = 60

    var body: some View {
        let loop = model.loop
        let tMax = max(loop.updatedAt, loop.ticks.last?.t ?? 0)
        let tMin = tMax - window
        let ticks = loop.ticks.filter { $0.t >= tMin - 1 }
        let calls = loop.answered.filter { $0.t >= tMin && $0.micro > 0 }
        let fills = loop.fills.filter { $0.t >= tMin }

        if ticks.count < 2 {
            Text(loop.isActive ? "připojuji Hyperliquid…" : "spusť smyčku a uvidíš živou cenu")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let domain = yDomain(ticks: ticks, calls: calls, fills: fills, order: loop.order)
            Chart {
                ForEach(ticks) { t in
                    AreaMark(x: .value("Čas", t.date), yStart: .value("Bid", t.bid), yEnd: .value("Ask", t.ask))
                        .foregroundStyle(Theme.jev.opacity(0.12))
                        .interpolationMethod(.stepEnd)
                }
                ForEach(ticks) { t in
                    LineMark(x: .value("Čas", t.date), y: .value("Cena", t.micro))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
                ForEach(calls) { d in
                    PointMark(x: .value("Čas", d.date), y: .value("Cena", d.micro))
                        .foregroundStyle(d.status == .ok ? Theme.color(for: d.side) : Theme.late)
                        .symbolSize(30)
                }
                ForEach(fills) { f in
                    PointMark(x: .value("Čas", f.date), y: .value("Cena", f.px))
                        .symbol(.diamond)
                        .symbolSize(160)
                        .foregroundStyle(Theme.color(for: f.side))
                        .annotation(position: f.side == .buy ? .bottom : .top) {
                            Text(f.side == .buy ? "KOUPENO" : "PRODÁNO")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.color(for: f.side))
                        }
                }
                if let o = loop.order {
                    RuleMark(y: .value("Limit", o.px))
                        .foregroundStyle(o.buying ? Theme.good : Theme.bad)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                        .annotation(position: .top, alignment: .trailing,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("limit \(o.buying ? "buy" : "sell") \(Fmt.px(o.px))")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(o.buying ? Theme.good : Theme.bad)
                        }
                }
            }
            .chartXScale(domain: Date(timeIntervalSince1970: tMin)...Date(timeIntervalSince1970: tMax))
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        Text(Fmt.px(v.as(Double.self) ?? 0))
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                }
            }
        }
    }

    private func yDomain(ticks: [PriceTick], calls: [LoopDecision], fills: [LoopFill], order: RestingOrder?) -> ClosedRange<Double> {
        var ys = ticks.map(\.micro) + ticks.map(\.bid) + ticks.map(\.ask)
        ys += calls.map(\.micro)
        ys += fills.map(\.px)
        if let o = order { ys.append(o.px) }
        var lo = ys.min() ?? 0
        var hi = ys.max() ?? 1
        let pad = (hi - lo) * 0.18
        let p = pad > 0 ? pad : max(hi * 0.0001, 1e-6)
        lo -= p
        hi += p
        return lo...hi
    }
}

/// Poslední Jev volání a pravděpodobnosti buy/sell.
struct LatestCallCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let last = model.loop.decisions.last(where: { $0.side != nil })
        let pBuy: Double = {
            guard let l = last, let c = l.conf else { return 0 }
            return l.side == .buy ? c : 1 - c
        }()
        Card("Poslední Jev volání") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(last?.side?.rawValue.uppercased() ?? "—")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(Theme.color(for: last?.side))
                if let c = last?.conf {
                    Text(F.pct(c)).font(.system(size: 24, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            probBar("buy", value: last == nil ? nil : pBuy, color: Theme.good)
            probBar("sell", value: last == nil ? nil : 1 - pBuy, color: Theme.bad)
        }
    }

    private func probBar(_ label: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 36, alignment: .leading).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(color).frame(width: g.size.width * (value ?? 0))
                }
            }
            .frame(height: 9)
            Text(value.map(F.pct) ?? "–").frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

/// Papírový účet: zůstatek, P&L před a po poplatcích, křivka equity.
struct AccountCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let loop = model.loop
        let book = loop.book
        let last = book.equity.last
        let gross = last?.gross ?? 0
        let net = last?.net ?? 0
        let exec = loop.config.maker
            ? String(format: "limitní, %.1f bps", Hyperliquid.makerFee * 1e4)
            : String(format: "tržní, %.1f bps + spread", Hyperliquid.takerFee * 1e4)
        Card("Papírový účet · $1,000 pozice · \(exec)") {
            row("Papírový zůstatek", F.money(book.notional + net), big: true, color: net > 0 ? Theme.good : .primary)
            Divider()
            row("Před poplatky", F.usd(gross), color: gross > 0 ? Theme.good : .primary)
            row("Poplatky (\(book.trades) obchodů)", "−" + F.money(book.fees))
            Divider()
            row("Po poplatcích", F.usd(net), color: net > 0 ? Theme.good : .primary)
            row("Jev volání → obchody", "\(loop.totalCalls) → \(book.trades)")
            row("Správný směr", loop.scored > 0 ? "\(Int((Double(loop.hits) / Double(loop.scored) * 100).rounded())) % z \(loop.scored)" : "–")
            if book.equity.count > 1 {
                EquityChart(points: book.equity)
                    .frame(height: 70)
            }
        }
    }

    private func row(_ k: String, _ v: String, big: Bool = false, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(size: big ? 26 : 13, weight: big ? .heavy : .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .font(.system(size: 13, design: .monospaced))
    }
}

struct EquityChart: View {
    let points: [EquityPoint]

    var body: some View {
        Chart {
            RuleMark(y: .value("Nula", 0))
                .foregroundStyle(Theme.line)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(points) { p in
                LineMark(x: .value("Čas", p.date), y: .value("P&L", p.gross), series: .value("Řada", "před poplatky"))
                    .foregroundStyle(Theme.jev.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            }
            ForEach(points) { p in
                LineMark(x: .value("Čas", p.date), y: .value("P&L", p.net), series: .value("Řada", "po poplatcích"))
                    .foregroundStyle(Theme.jev)
                    .lineStyle(StrokeStyle(lineWidth: 2.4))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

/// Feed posledních Jev volání.
struct FeedCard: View {
    @Environment(AppModel.self) private var model

    private static let labels: [String: String] = [
        "hold · low conviction": "slabý signál",
        "hold · limit order working": "objednávka čeká",
        "hold · too soon to flip": "chladnutí",
        "hold · already long": "v pozici",
        "hold · already short": "v pozici",
        "hold · already flat": "flat",
        "hold · late": "pozdě",
    ]

    var body: some View {
        let rows = Array(model.loop.answered.suffix(22).reversed())
        Card("Feed · každé Jev volání") {
            if rows.isEmpty {
                Text("zatím nic").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rows) { d in
                feedRow(d)
            }
        }
    }

    private func feedRow(_ d: LoopDecision) -> some View {
        let action = FeedCard.labels[d.action] ?? d.action
        return HStack(spacing: 8) {
            Text("\(d.block)").frame(width: 46, alignment: .leading).foregroundStyle(.secondary)
            Text(d.side?.rawValue.uppercased() ?? "—")
                .fontWeight(.bold)
                .foregroundStyle(d.status == .ok ? Theme.color(for: d.side) : Theme.late)
                .frame(width: 40, alignment: .leading)
            Text(d.conf.map { String(format: "%.2f", $0) } ?? "–").frame(width: 36, alignment: .leading)
            Text(d.ms.map { "\($0)" } ?? "–").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(action)
                .lineLimit(1)
                .foregroundStyle(d.isTrade ? Theme.jev : (d.status == .ok ? Color.secondary : Theme.late))
                .fontWeight(d.isTrade ? .bold : .regular)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 2)
    }
}
