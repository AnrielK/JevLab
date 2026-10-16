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
                    controls(engine)
                    if !engine.records.isEmpty {
                        RunAnalysisView(records: engine.records, feeRate: engine.feeRate, notional: engine.config.notional,
                                        minConf: Binding(get: { engine.minConf }, set: { engine.minConf = $0 }))
                        DecisionList(records: engine.records, minConf: engine.minConf)
                    }
                }
                .padding(14)
            }
            .background(Theme.background)
            .navigationTitle("Horizont")
            .onChange(of: model.horizonConfig.horizon) {
                model.horizonConfig.days = min(model.horizonConfig.days, model.horizonConfig.horizon.maxDays.rounded(.down))
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
                ForEach(Horizon.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isActive)

            if !live {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Historie")
                        Spacer()
                        Text("\(Int(cfg.days)) dní · \(cfg.backtestBars) svíček").font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $bindable.horizonConfig.days, in: 1...max(2, min(60, cfg.horizon.maxDays.rounded(.down))), step: 1)
                        .disabled(engine.isActive)
                    Text("≈ \(cfg.backtestBars) Jev volání · odhad ~$\(String(format: "%.2f", Double(cfg.backtestBars) * 0.00002)) podle ceny z tvého testu · max \(Int(cfg.horizon.maxDays)) dní (Hyperliquid drží ~5000 svíček)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Rozhoduje na každém zavření svíčky, dokud běh nezastavíš (appka musí zůstat otevřená). Jedno Jev volání na svíčku.")
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
    @Binding var coin: String

    var body: some View {
        let inst = Instrument.find(coin)
        HStack {
            Picker("Trh", selection: $coin) {
                Section("Krypto") {
                    ForEach(Instrument.crypto) { Text($0.label).tag($0.coin) }
                }
                Section("US akcie (perpy na Hyperliquid)") {
                    ForEach(Instrument.stocks) { Text($0.label).tag($0.coin) }
                }
            }
            .pickerStyle(.menu)
            if inst.isStock {
                let open = USMarketHours.isOpen()
                Label(open ? "burza otevřená" : "burza zavřená", systemImage: open ? "building.columns.fill" : "moon.fill")
                    .font(.caption)
                    .foregroundStyle(open ? Theme.good : Theme.late)
            }
        }
        if inst.isStock {
            Text("Perp sledující akcii přes oracle, ne skutečná akcie. Obchoduje se 24/7; mimo seanci NYSE cena nesleduje burzu a po otevření bývají skoky. Poplatky 2× vyšší než u krypta.")
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
