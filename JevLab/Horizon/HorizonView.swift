import SwiftUI
import Charts
import JevLabCore

/// Svíčkový režim: Jev odhaduje směr na 5 min / 15 min / 1 h. Backtest na historii, nebo živě.
struct HorizonView: View {
    @Environment(AppModel.self) private var model
    @State private var live = false

    var body: some View {
        let engine = model.horizon
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    NavigationLink {
                        TrendLabView()
                    } label: {
                        HStack {
                            Label("Trend strategie · signál a varianty, zdarma", systemImage: "chart.line.uptrend.xyaxis")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.good.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        RuleLabView()
                    } label: {
                        HStack {
                            Label("Pravidla bez AI · všechny trhy, zdarma", systemImage: "function")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.jev.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    controls(engine)
                    if !engine.records.isEmpty {
                        if let c = engine.lastClaude {
                            HorizonClaudeCard(state: c, every: engine.config.claudeEvery, horizon: engine.config.horizon,
                                              errors: engine.claudeErrors)
                        }
                        RunAnalysisView(records: engine.records, feeRate: engine.feeRate, notional: engine.config.notional,
                                        minConf: Binding(get: { engine.minConf }, set: { engine.minConf = $0 }),
                                        mode: Binding(get: { engine.simMode }, set: { engine.simMode = $0 }))
                        if let last = engine.records.last(where: { $0.state != nil }), let st = last.state {
                            SRCard(state: st, tradingLabel: engine.config.horizon.shortLabel)
                            StateCard(state: st, date: last.date)
                        }
                        DecisionList(records: engine.records, minConf: engine.minConf)
                    }
                }
                .padding(14)
            }
            .background(Theme.background)
            .navigationTitle("Horizont")
            .onChange(of: model.horizonConfig.horizon) {
                let defaults: [Horizon: Double] = [.m5: 7, .m15: 14, .h1: 30, .h4: 180, .d1: 365]
                let cfg = model.horizonConfig
                model.horizonConfig.days = min(defaults[cfg.horizon] ?? 30, cfg.maxDays.rounded(.down))
            }
            .onChange(of: model.horizonConfig.multiTF) {
                model.horizonConfig.days = min(model.horizonConfig.days, model.horizonConfig.maxDays.rounded(.down))
            }
        }
    }

    @ViewBuilder
    private func controls(_ engine: HorizonEngine) -> some View {
        @Bindable var bindable = model
        let cfg = model.horizonConfig
        Card {
            Text("Jev odhaduje, jestli cena na konci další svíčky bude výš, nebo níž. Poplatky tu váží míň než u sekundové smyčky, protože pohyb za svíčku bývá větší.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Režim", selection: $live) {
                Text("Backtest").tag(false)
                Text("Živě").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(engine.isActive)

            InstrumentPicker(coin: $bindable.horizonConfig.coin)
                .disabled(engine.isActive)
            Picker("Horizont", selection: $bindable.horizonConfig.horizon) {
                ForEach(Horizon.allCases) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isActive)
            Toggle(isOn: $bindable.horizonConfig.multiTF) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kontext z dalších timeframů")
                    Text("Obchod na \(cfg.horizon.shortLabel), rozhodování i z " + cfg.horizon.context.map(\.label).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(engine.isActive)

            claudeControls(engine, cfg: cfg)

            if !live {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Historie")
                        Spacer()
                        Text("\(Int(cfg.days)) dní · \(cfg.backtestBars) svíček").font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $bindable.horizonConfig.days, in: 1...max(2, min(1500, cfg.maxDays.rounded(.down))), step: 1)
                        .disabled(engine.isActive)
                    Text("≈ \(cfg.backtestBars) Jev volání · Jev odhadem ~$\(String(format: "%.2f", Double(cfg.backtestBars) * 0.00002)) (Claude se platí zvlášť a je výrazně dražší; skutečnou útratu ukazuje Vercel → Spend by Model) · max \(Int(min(1500, cfg.maxDays))) dní (Hyperliquid drží ~5000 svíček na rámec; u akciových perpů je historie kratší)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(cfg.horizon == .d1
                     ? "Rozhoduje na zavření denní svíčky (00:00 UTC = 2:00 v noci u nás), takže appka musí běžet přes noc, nejlépe na Macu. Jedno Jev volání denně."
                     : "Rozhoduje na každém zavření svíčky, dokud běh nezastavíš (appka musí zůstat otevřená). Jedno Jev volání na svíčku.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                status(engine)
                Spacer()
                if engine.isActive {
                    Button(role: .destructive) { engine.stop() } label: { Label("Zastavit", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.bad)
                } else {
                    Button {
                        if live {
                            model.startHorizonLive()
                        } else {
                            model.startBacktest()
                        }
                    } label: {
                        Label(live ? "Spustit živě" : "Spustit backtest", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasKey)
                }
            }
            if engine.status == .running, engine.mode == .backtest, engine.total > 0 {
                ProgressView(value: Double(engine.progress), total: Double(engine.total)).tint(Theme.jev)
            }
            if let err = engine.lastError, engine.errors > 0 {
                ErrorBanner(title: "\(engine.errors)× chyba", detail: err)
            }
            if case .failed(let msg) = engine.status {
                Text(msg).font(.footnote).foregroundStyle(Theme.bad)
            }
        }
    }

    @ViewBuilder
    private func claudeControls(_ engine: HorizonEngine, cfg: HorizonConfig) -> some View {
        @Bindable var bindable = model
        Toggle(isOn: $bindable.horizonConfig.claude) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Claude mozek", systemImage: "brain")
                Text(model.hasGatewayKey
                     ? "Claude určuje směr, Jev obchoduje jen tím směrem. Výsledek ukáže Jev sám / Jev + Claude / Claude sám vedle sebe."
                     : "Potřebuje Vercel AI Gateway klíč.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(engine.isActive || !model.hasGatewayKey)
        if cfg.claude {
            Picker("Claude čte trh", selection: $bindable.horizonConfig.claudeEveryBars) {
                Text("výchozí (každých \(HorizonConfig.defaultEvery(cfg.horizon)) sv.)").tag(0)
                Text("každou svíčku").tag(1)
                Text("každé 4 svíčky").tag(4)
                Text("každých 12 svíček").tag(12)
            }
            .disabled(engine.isActive)
            if !live {
                Text("≈ \(cfg.claudeCalls) Claude volání navíc. Claude je dražší než Jev; přesnou cenu uvidíš ve Vercelu ve Spend by Model, takže začni krátkým backtestem. Claude dostane jen relativní čísla (žádné ceny, data ani zprávy), aby z historie nepoznal, o jaké období jde.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ engine: HorizonEngine) -> some View {
        let text: String
        switch engine.status {
        case .idle: text = "připraveno"
        case .loading: text = "stahuji svíčky…"
        case .running:
            if engine.mode == .live {
                let pos = engine.livePosition > 0 ? "LONG" : engine.livePosition < 0 ? "SHORT" : "FLAT"
                let next = engine.nextBarAt.map { "další rozhodnutí \(F.time($0.timeIntervalSince1970))" } ?? ""
                text = "živě · \(pos) · \(next)"
            } else {
                text = "\(engine.progress) / \(engine.total) svíček"
            }
        case .done: text = "hotovo · uloženo do Historie"
        case .failed: text = "chyba"
        }
        return Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
    }
}

/// Výběr trhu: krypto a akciové perpy (HIP-3), u akcií stav burzy v USA.
struct InstrumentPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var coin: String
    @State private var searching = false

    /// Akcie v nabídce: oblíbené + aktuálně vybraná (když v oblíbených není).
    private var stockOptions: [Instrument] {
        var list = model.favoriteInstruments
        if Instrument.find(coin).isStock, !list.contains(where: { $0.coin == coin }) {
            list.append(Instrument(coin: coin, isStock: true))
        }
        return list
    }

    var body: some View {
        let inst = Instrument.find(coin)
        HStack {
            Picker("Trh", selection: $coin) {
                Section("Krypto") {
                    ForEach(Instrument.crypto) { Text($0.label).tag($0.coin) }
                }
                if !stockOptions.isEmpty {
                    Section("Akcie (oblíbené)") {
                        ForEach(stockOptions) { Text($0.label).tag($0.coin) }
                    }
                }
            }
            .pickerStyle(.menu)
            Button {
                searching = true
            } label: {
                Label("Akcie…", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            if inst.isStock {
                let open = USMarketHours.isOpen()
                Image(systemName: open ? "building.columns.fill" : "moon.fill")
                    .foregroundStyle(open ? Theme.good : Theme.late)
                    .accessibilityLabel(open ? "burza otevřená" : "burza zavřená")
            }
        }
        .sheet(isPresented: $searching) {
            StockSearchSheet(selection: nil, onPick: { coin = $0 })
        }
        if inst.isStock {
            Text("\(USMarketHours.isOpen() ? "Burza otevřená." : "Burza zavřená.") Perp sledující akcii přes oracle, ne skutečná akcie: obchoduje se 24/7, mimo seanci NYSE cena nesleduje burzu a po otevření bývají skoky. Poplatky 2× vyšší než u krypta.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Posledních pár rozhodnutí s výsledkem.
struct DecisionList: View {
    let records: [CallRecord]
    let minConf: Double

    var body: some View {
        Card("Rozhodnutí (nejnovější nahoře)") {
            ForEach(Array(records.suffix(30).reversed())) { r in
                HStack(spacing: 8) {
                    Text(F.dayTime(r.t)).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                    Text(r.side?.rawValue.uppercased() ?? "—")
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.color(for: r.side))
                        .frame(width: 40, alignment: .leading)
                    Text(r.conf.map { String(format: "%.2f", $0) } ?? "–").frame(width: 40, alignment: .leading)
                    Text((r.conf ?? 0) >= minConf && r.side != nil ? "obchod" : "flat")
                        .foregroundStyle((r.conf ?? 0) >= minConf && r.side != nil ? Theme.jev : Color.secondary)
                    Spacer()
                    Text(r.retNextBps.map { F.bps($0, digits: 1) } ?? "čeká")
                        .foregroundStyle(outcomeColor(r))
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
        }
    }

    private func outcomeColor(_ r: CallRecord) -> Color {
        guard let ret = r.retNextBps, r.side != nil else { return .secondary }
        return r.sign * ret > 0 ? Theme.good : Theme.bad
    }
}

/// Co Jev viděl u posledního rozhodnutí, seskupené podle timeframu.
struct StateCard: View {
    let state: [String: Double]
    let date: Date

    var body: some View {
        let groups = Dictionary(grouping: state.keys.sorted()) { key -> String in
            for tf in Timeframe.allCases where key.hasPrefix(tf.prefix) { return tf.label }
            return "obchodní rámec"
        }
        let order = ["obchodní rámec"] + Timeframe.allCases.map(\.label)
        Card("Co Jev viděl · \(date.formatted(date: .abbreviated, time: .shortened))") {
            ForEach(order.filter { groups[$0] != nil }, id: \.self) { g in
                VStack(alignment: .leading, spacing: 3) {
                    Text(g).font(.caption.weight(.semibold)).foregroundStyle(Theme.jev)
                    ForEach(groups[g] ?? [], id: \.self) { k in
                        HStack {
                            Text(shortKey(k, group: g)).foregroundStyle(.secondary)
                            Spacer()
                            Text(F.num(state[k] ?? 0))
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
            }
        }
    }

    private func shortKey(_ k: String, group: String) -> String {
        for tf in Timeframe.allCases where k.hasPrefix(tf.prefix) { return String(k.dropFirst(tf.prefix.count)) }
        return k
    }
}

/// Poslední Claudovo čtení v Horizontu.
struct HorizonClaudeCard: View {
    let state: BrainState
    let every: Int
    let horizon: Horizon
    let errors: Int

    var body: some View {
        let color: Color = state.bias == .long ? Theme.good : state.bias == .short ? Theme.bad : .secondary
        Card("Claude · čte trh každých \(every) × \(horizon.shortLabel)") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(state.bias?.rawValue.uppercased() ?? "…")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(color)
                if let c = state.confidence {
                    Text(F.pct(c)).font(.system(size: 18, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text(state.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("\(state.model)\(state.ms.map { " · \($0) ms" } ?? "")\(errors > 0 ? " · \(errors)× chyba" : "")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// Nejbližší support a rezistence podle rámců (u posledního rozhodnutí).
struct SRCard: View {
    let state: [String: Double]
    let tradingLabel: String

    private var rows: [(label: String, prefix: String)] {
        var out: [(label: String, prefix: String)] = [(label: tradingLabel + " (obchodní)", prefix: "")]
        for tf in Timeframe.allCases { out.append((label: tf.label, prefix: tf.prefix)) }
        return out.filter { state[$0.prefix + "support_dist_bps"] != nil || state[$0.prefix + "resistance_dist_bps"] != nil }
    }

    var body: some View {
        Card("Support a rezistence") {
            if rows.isEmpty {
                Text("Zatím málo historie na nalezení úrovní.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.prefix) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label).font(.caption.weight(.semibold)).foregroundStyle(Theme.jev)
                    line("rezistence", prefix: row.prefix + "resistance", color: Theme.bad, sign: "+")
                    line("support", prefix: row.prefix + "support", color: Theme.good, sign: "−")
                }
            }
            Text("Úrovně = shluky swing maxim/minim; vzdálenost v % a v násobcích ATR (běžný pohyb jedné svíčky daného rámce), dotyky = kolikrát se od ní cena otočila.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func line(_ name: String, prefix: String, color: Color, sign: String) -> some View {
        if let bps = state[prefix + "_dist_bps"] {
            HStack {
                Text(name).foregroundStyle(color).frame(width: 80, alignment: .leading)
                Text(sign + String(format: "%.2f %%", abs(bps) / 100))
                Spacer()
                if let atr = state[prefix + "_dist_atr"] { Text(String(format: "%.1f ATR", atr)).foregroundStyle(.secondary) }
                if let t = state[prefix + "_touches"] { Text("\(Int(t))× dotyk").foregroundStyle(.secondary) }
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }
}
