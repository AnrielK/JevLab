import SwiftUI
import JevLabCore

/// Backtest pravidel na všech trzích bez AI: maximální historie, nic nestojí.
struct RuleLabView: View {
    @Environment(AppModel.self) private var model
    @State private var horizon: Horizon = .d1
    @State private var multiTF = true
    @State private var selected: Set<String> = Set(Instrument.crypto.map(\.coin))

    var body: some View {
        let lab = model.ruleLab
        ScrollView {
            VStack(spacing: 12) {
                controls(lab)
                if !lab.results.isEmpty {
                    SummaryCard(summaries: lab.summaries, markets: lab.results)
                    ForEach(lab.results) { m in
                        MarketCard(market: m)
                    }
                }
                ForEach(lab.errors, id: \.self) { e in
                    Text(e).font(.footnote).foregroundStyle(Theme.late)
                }
            }
            .padding(14)
        }
        .background(Theme.background)
        .navigationTitle("Pravidla bez AI")
    }

    @ViewBuilder
    private func controls(_ lab: RuleLab) -> some View {
        Card {
            Text("Projde maximální historii z Hyperliquid (~5000 svíček na rámec), spočítá indikátory a support/rezistenci a vyhodnotí všechna pravidla po poplatcích. Bez Jev a bez Clauda, takže nic nestojí.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Rámec", selection: $horizon) {
                ForEach([Horizon.h1, .h4, .d1]) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Kontext z vyšších rámců (týden, měsíc…)", isOn: $multiTF)
            Text("Trhy").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowChips(items: (Instrument.crypto + model.stocks).map { (id: $0.coin, label: $0.label) }, selected: $selected)
            HStack {
                Text(lab.progressText).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if lab.isRunning {
                    Button(role: .destructive) { lab.stop() } label: { Label("Zastavit", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.bad)
                } else {
                    Button {
                        let order = (Instrument.crypto + model.stocks).map(\.coin).filter { selected.contains($0) }
                        lab.run(coins: order, horizon: horizon, multiTF: multiTF)
                    } label: {
                        Label("Spustit zdarma", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
            }
            if lab.isRunning { ProgressView().frame(maxWidth: .infinity) }
        }
    }
}

/// Jednoduché přepínací štítky (výběr trhů).
struct FlowChips: View {
    let items: [(id: String, label: String)]
    @Binding var selected: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
            ForEach(items, id: \.id) { item in
                let on = selected.contains(item.id)
                Button {
                    if on { selected.remove(item.id) } else { selected.insert(item.id) }
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? Theme.jev.opacity(0.25) : Theme.line, in: Capsule())
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Souhrn pravidel přes všechny trhy.
struct SummaryCard: View {
    let summaries: [RuleSummary]
    let markets: [RuleMarketResult]

    var body: some View {
        let holdTest = markets.map(\.buyHoldTest).reduce(0, +) / Double(max(1, markets.count))
        Card("Souhrn přes \(markets.count) trhů") {
            Text("Průměr po poplatcích v bps na pozici. „2. pol.“ = druhá polovina historie. Počty říkají, na kolika trzích bylo pravidlo na 2. polovině v plusu a kolikrát porazilo „kupit a držet“.")
                .font(.footnote).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("pravidlo").foregroundStyle(.secondary)
                    Text("celé").foregroundStyle(.secondary)
                    Text("2. pol.").foregroundStyle(.secondary)
                    Text("v plusu").foregroundStyle(.secondary)
                    Text("> držet").foregroundStyle(.secondary)
                }
                ForEach(summaries) { s in
                    GridRow {
                        Text(s.rule.name).fontWeight(.semibold)
                        Text(F.bps(s.avgFull, digits: 0)).foregroundStyle(s.avgFull > 0 ? Theme.good : Theme.bad)
                        Text(F.bps(s.avgTest, digits: 0)).foregroundStyle(s.avgTest > 0 ? Theme.good : Theme.bad)
                        Text("\(s.positiveTest)/\(s.markets)")
                        Text("\(s.beatHoldTest)/\(s.markets)")
                    }
                }
                GridRow {
                    Text("Kupit a držet").foregroundStyle(.secondary)
                    Text(F.bps(markets.map(\.buyHoldFull).reduce(0, +) / Double(max(1, markets.count)), digits: 0)).foregroundStyle(.secondary)
                    Text(F.bps(holdTest, digits: 0)).foregroundStyle(.secondary)
                    Text("")
                    Text("")
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            Text("Pravidla nemají nic naučeného, takže celé období je poctivé číslo. Výsledek ale pořád platí jen pro tuto historii; trh se může chovat jinak.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Detail jednoho trhu.
struct MarketCard: View {
    let market: RuleMarketResult

    var body: some View {
        Card("\(market.label) · \(market.horizon.shortLabel) · \(market.bars) svíček") {
            Text("\(market.from.formatted(date: .abbreviated, time: .omitted)) – \(market.to.formatted(date: .abbreviated, time: .omitted)) · poplatek \(String(format: "%.2f", market.feeRate * 1e4)) bps")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(market.results) { r in
                    GridRow {
                        Text(r.rule.name)
                        Text(F.bps(r.full.netBps, digits: 0)).foregroundStyle(r.full.netBps > 0 ? Theme.good : Theme.bad)
                        Text(r.test.map { F.bps($0.netBps, digits: 0) } ?? "–")
                            .foregroundStyle((r.test?.netBps ?? 0) > market.buyHoldTest ? Theme.good : Color.primary)
                        Text("\(r.full.trades)×").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Kupit a držet").foregroundStyle(.secondary)
                    Text(F.bps(market.buyHoldFull, digits: 0)).foregroundStyle(.secondary)
                    Text(F.bps(market.buyHoldTest, digits: 0)).foregroundStyle(.secondary)
                    Text("")
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
        }
    }
}
