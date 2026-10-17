import SwiftUI
import JevLabCore

/// Backtest pravidel na všech trzích bez AI: maximální historie, nic nestojí.
struct RuleLabView: View {
    @Environment(AppModel.self) private var model
    @State private var horizon: Horizon = .d1
    @State private var multiTF = true
    @State private var crypto: Set<String> = Set(Instrument.crypto.map(\.coin))
    @State private var stocks: Set<String> = []
    @State private var addingStocks = false

    var body: some View {
        let lab = model.ruleLab
        ScrollView {
            VStack(spacing: 12) {
                controls(lab)
                if let run = model.ruleRuns.first, !lab.isRunning, !lab.results.isEmpty {
                    ExportCard(run: run)
                }
                if !lab.results.isEmpty {
                    SummaryCard(summaries: lab.summaries, markets: lab.results)
                    ForEach(lab.results) { m in
                        MarketCard(market: m)
                    }
                }
                ForEach(lab.errors, id: \.self) { e in
                    Text(e).font(.footnote).foregroundStyle(Theme.late)
                }
                SavedRunsCard()
            }
            .padding(14)
        }
        .background(Theme.background)
        .navigationTitle("Pravidla bez AI")
        .sheet(isPresented: $addingStocks) {
            StockSearchSheet(selection: $stocks)
        }
    }

    @ViewBuilder
    private func controls(_ lab: RuleLab) -> some View {
        Card {
            Text("Projde maximální historii z Hyperliquid (~5000 svíček na rámec), spočítá indikátory a support/rezistenci a vyhodnotí všechna pravidla po poplatcích. Bez Jev a bez Clauda, takže nic nestojí. Výsledek se uloží a jde poslat jako CSV.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Rámec", selection: $horizon) {
                ForEach([Horizon.h1, .h4, .d1]) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Kontext z vyšších rámců (týden, měsíc…)", isOn: $multiTF)

            Text("Krypto").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowChips(items: Instrument.crypto.map { (id: $0.coin, label: $0.label) }, selected: $crypto)

            HStack {
                Text("Akcie").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !stocks.isEmpty {
                    Button("Zrušit") { stocks.removeAll() }.font(.caption)
                }
                Button {
                    addingStocks = true
                } label: {
                    Label("Přidat", systemImage: "plus")
                }
                .font(.caption.weight(.semibold))
            }
            if stocks.isEmpty {
                Text("Žádné. Přidej přes vyhledávání; ★ přidá akcii do oblíbených i ve výběru trhu.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                FlowChips(items: stocks.sorted().map { (id: $0, label: Instrument.find($0).label) }, selected: $stocks)
            }

            HStack {
                Text(lab.isRunning ? lab.progressText : "\(crypto.count + stocks.count) trhů")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if lab.isRunning {
                    Button(role: .destructive) { lab.stop() } label: { Label("Zastavit", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.bad)
                } else {
                    Button {
                        let order = Instrument.crypto.map(\.coin).filter { crypto.contains($0) } + stocks.sorted()
                        lab.run(coins: order, horizon: horizon, multiTF: multiTF)
                    } label: {
                        Label("Spustit zdarma", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(crypto.isEmpty && stocks.isEmpty)
                }
            }
            if lab.isRunning { ProgressView().frame(maxWidth: .infinity) }
        }
    }
}

/// Poslání posledního výsledku jako CSV.
struct ExportCard: View {
    let run: RuleLabRun

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Uloženo").font(.caption.weight(.semibold)).foregroundStyle(Theme.good)
                Text(run.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let url = RuleRunFile.url(run) {
                ShareLink(item: url) { Label("Poslat CSV", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.good.opacity(0.4)))
    }
}

enum RuleRunFile {
    /// Zapíše CSV běhu do dočasné složky a vrátí jeho URL (pro sdílení).
    static func url(_ run: RuleLabRun) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jevlab-pravidla-\(run.horizon.shortLabel)-\(f.string(from: run.date)).csv")
        return (try? run.csv.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}

/// Seznam uložených výsledků.
struct SavedRunsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.ruleRuns.isEmpty {
            Card("Uložené výsledky") {
                ForEach(model.ruleRuns) { run in
                    NavigationLink {
                        SavedRunView(run: run)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.title).font(.callout.weight(.semibold)).lineLimit(1)
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let t = run.summary(rule: "trend")
                            if t.n > 0 {
                                Text("Trend \(F.bps(t.avgTest, digits: 0))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(t.avgTest > 0 ? Theme.good : Theme.bad)
                            }
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

/// Detail uloženého výsledku (souhrn + trhy) s exportem a smazáním.
struct SavedRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: RuleLabRun

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Card("Souhrn přes \(run.markets.count) trhů") {
                    Text(run.date.formatted(date: .abbreviated, time: .shortened) + " · " + run.title)
                        .font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Text("pravidlo").foregroundStyle(.secondary)
                            Text("celé").foregroundStyle(.secondary)
                            Text("2. pol.").foregroundStyle(.secondary)
                            Text("v plusu").foregroundStyle(.secondary)
                            Text("> držet").foregroundStyle(.secondary)
                        }
                        ForEach(RuleStrategy.all) { rule in
                            let s = run.summary(rule: rule.id)
                            GridRow {
                                Text(rule.name).fontWeight(.semibold)
                                Text(F.bps(s.avgFull, digits: 0)).foregroundStyle(s.avgFull > 0 ? Theme.good : Theme.bad)
                                Text(F.bps(s.avgTest, digits: 0)).foregroundStyle(s.avgTest > 0 ? Theme.good : Theme.bad)
                                Text("\(s.positive)/\(s.n)")
                                Text("\(s.beatHold)/\(s.n)")
                            }
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
                ForEach(run.markets, id: \.coin) { m in
                    Card("\(Instrument.find(m.coin).label) · \(m.bars) svíček") {
                        Text("\(m.from.formatted(date: .abbreviated, time: .omitted)) – \(m.to.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            ForEach(run.rows.filter { $0.coin == m.coin }, id: \.rule) { r in
                                GridRow {
                                    Text(r.ruleName)
                                    Text(F.bps(r.netFullBps, digits: 0)).foregroundStyle(r.netFullBps > 0 ? Theme.good : Theme.bad)
                                    Text(r.netTestBps.map { F.bps($0, digits: 0) } ?? "–")
                                        .foregroundStyle((r.netTestBps ?? 0) > m.buyHoldTest ? Theme.good : Color.primary)
                                    Text("\(r.trades)×").foregroundStyle(.secondary)
                                }
                            }
                            GridRow {
                                Text("Kupit a držet").foregroundStyle(.secondary)
                                Text(F.bps(m.buyHoldFull, digits: 0)).foregroundStyle(.secondary)
                                Text(F.bps(m.buyHoldTest, digits: 0)).foregroundStyle(.secondary)
                                Text("")
                            }
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
                Button(role: .destructive) {
                    model.deleteRuleRun(run.id)
                    dismiss()
                } label: {
                    Label("Smazat výsledek", systemImage: "trash")
                }
            }
            .padding(14)
        }
        .background(Theme.background)
        .navigationTitle(run.horizon.shortLabel + " · \(run.markets.count) trhů")
        .toolbar {
            ToolbarItem {
                if let url = RuleRunFile.url(run) {
                    ShareLink(item: url) { Label("Poslat CSV", systemImage: "square.and.arrow.up") }
                }
            }
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
