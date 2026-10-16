import SwiftUI
import Charts
import JevLabCore

/// Jev smyčka: živá cena, Jev volání, strategie a papírový účet.
struct LoopView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 12) {
                    LoopControls()
                    if geo.size.width > 900 {
                        HStack(alignment: .top, spacing: 12) {
                            mainColumn.frame(maxWidth: .infinity)
                            sideColumn.frame(width: min(420, geo.size.width * 0.34))
                        }
                    } else {
                        mainColumn
                        sideColumn
                    }
                }
                .padding(14)
            }
        }
        .background(Theme.background)
    }

    private var mainColumn: some View {
        VStack(spacing: 12) {
            PriceHeader()
            StateBox()
            Card {
                PriceChart()
                    .frame(height: 320)
                DecisionDots()
                Text("jedna tečka = jedno Jev volání · ◆ = vyplněný obchod · strategie: \(model.loop.strategySummary)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sideColumn: some View {
        VStack(spacing: 12) {
            LatestCallCard()
            AccountCard()
            FeedCard()
        }
    }
}

// MARK: - Ovládání

struct LoopControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let loop = model.loop
        Card {
            HStack(spacing: 12) {
                Text("**Jev** Smyčka").font(.system(size: 22, weight: .heavy))
                statusPill(loop)
                Spacer()
                if loop.isActive {
                    Button(role: .destructive) { loop.stop() } label: {
                        Label("Zastavit", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.bad)
                } else {
                    Button { model.startLoop() } label: {
                        Label("Spustit", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasKey)
                }
            }
            if !model.hasKey {
                Text("Nejdřív vlož Jev klíč v záložce Nastavení.")
                    .font(.footnote)
                    .foregroundStyle(Theme.late)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { controls(model: model) }
                VStack(alignment: .leading, spacing: 8) { controls(model: model) }
            }
            .disabled(loop.isActive)
            if case .failed(let msg) = loop.status {
                Text(msg).font(.footnote).foregroundStyle(Theme.bad)
            }
            if let err = loop.lastError, (loop.counts[.error] ?? 0) + (loop.counts[.throttled] ?? 0) > 0 {
                ErrorBanner(title: "Jev volání selhávají (\(loop.counts[.error] ?? 0)× chyba, \(loop.counts[.throttled] ?? 0)× omezeno)",
                            detail: err)
            }
        }
    }

    @ViewBuilder
    private func controls(model: AppModel) -> some View {
        @Bindable var bindable = model
        Picker("Coin", selection: $bindable.loopConfig.coin) {
            ForEach(["HYPE", "BTC", "ETH", "SOL"], id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        Picker("Délka", selection: $bindable.loopConfig.minutes) {
            Text("5 min").tag(5.0)
            Text("10 min").tag(10.0)
            Text("30 min").tag(30.0)
            Text("do zastavení").tag(0.0)
        }
        .frame(maxWidth: 220)
        Toggle("Limitní objednávky", isOn: $bindable.loopConfig.maker)
            .fixedSize()
    }

    private func statusPill(_ loop: LoopEngine) -> some View {
        let text: String
        let color: Color
        switch loop.status {
        case .idle: text = "papírový režim"; color = .secondary
        case .connecting: text = "připojuji Hyperliquid…"; color = Theme.late
        case .running: text = "běží · \(F.duration(loop.updatedAt - loop.startedAt))"; color = Theme.good
        case .done: text = "hotovo"; color = .secondary
        case .failed: text = "chyba"; color = Theme.bad
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(Capsule().stroke(Theme.line))
    }
}

// MARK: - Cena

struct PriceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let loop = model.loop
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loop.price.map(Fmt.px) ?? "—")
                        .font(.system(size: 52, weight: .heavy, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    HStack(spacing: 14) {
                        positionText(loop.book.pos)
                        if let o = loop.order {
                            Text("limit \(o.buying ? "buy" : "sell") \(Fmt.px(o.px)) čeká")
                        }
                        Text("spread \(loop.spreadBps.map { String(format: "%.2f bps", $0) } ?? "–")")
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                actionView(loop)
            }
            stats(loop)
        }
    }

    private func positionText(_ pos: Int) -> some View {
        Group {
            if pos > 0 { Text("LONG $1,000").foregroundStyle(Theme.good) }
            else if pos < 0 { Text("SHORT $1,000").foregroundStyle(Theme.bad) }
            else { Text("FLAT").foregroundStyle(.primary) }
        }
        .fontWeight(.bold)
    }

    @ViewBuilder
    private func actionView(_ loop: LoopEngine) -> some View {
        let now = Date().timeIntervalSince1970
        VStack(alignment: .trailing, spacing: 6) {
            if let f = loop.fills.last, now - f.t < 3 {
                Text(f.side == .buy ? "Koupeno" : "Prodáno")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.color(for: f.side))
                Text("\(f.kind) fill @ \(Fmt.px(f.px))")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            } else if let d = loop.answered.last, let side = d.side {
                Text(side == .buy ? "BUY" : "SELL")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.color(for: side))
                Text("Jev · \(F.pct(d.conf ?? 0)) · \(d.ms ?? 0) ms")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("Čekám").font(.system(size: 30, weight: .bold)).foregroundStyle(.secondary)
            }
        }
    }

    private func stats(_ loop: LoopEngine) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 4) {
            stat("volání", "\(loop.totalCalls)")
            stat("posl.", loop.lastMs.map { "\($0) ms" } ?? "–")
            stat("prům.", loop.avgMs.map { "\($0) ms" } ?? "–")
            stat("tempo", String(format: "%.1f/s", loop.ratePerSecond))
            stat("pozdě", "\(loop.counts[.late] ?? 0)")
            stat("omez.", "\(loop.counts[.throttled] ?? 0)")
            stat("chyby", "\(loop.counts[.error] ?? 0)")
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(.primary)
        }
        .lineLimit(1)
    }
}

/// Co Jev viděl při posledním volání.
struct StateBox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.loop.answered.last?.state ?? [:]
        Card {
            Text("co Jev viděl · \(state.count) polí")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.jev)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(StateField.labels, id: \.key) { field in
                    if let v = state[field.key] {
                        HStack(spacing: 4) {
                            Text(field.label).foregroundStyle(.secondary)
                            Text(F.num(v)).foregroundStyle(.primary)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
            }
        }
    }
}

/// Pruh barevných teček: jedna na každé zodpovězené volání.
struct DecisionDots: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = Array(model.loop.answered.suffix(60))
        HStack(spacing: 3) {
            ForEach(recent) { d in
                RoundedRectangle(cornerRadius: 2)
                    .fill(d.status == .ok ? Theme.color(for: d.side) : Theme.late)
                    .frame(width: 6, height: 14)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
        .clipped()
    }
}
