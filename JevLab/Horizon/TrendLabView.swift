import SwiftUI
import Charts
import JevLabCore

/// Trendová strategie bez AI: varianty, kapitál, propad a dnešní signál. Zdarma.
struct TrendLabView: View {
    @Environment(AppModel.self) private var model
    @State private var coin = "BTC"
    @State private var horizon: Horizon = .d1

    var body: some View {
        let lab = model.trendLab
        ScrollView {
            VStack(spacing: 12) {
                Card {
                    Text("Trend MA a Průraz na celé historii Hyperliquid, po poplatcích, bez AI. Porovná long/short s „jen long“ a stálou velikost pozice s velikostí podle volatility (ATR). Nahoře je dnešní signál vybrané varianty.")
                        .font(.footnote).foregroundStyle(.secondary)
                    InstrumentPicker(coin: $coin)
                    Picker("Rámec", selection: $horizon) {
                        ForEach([Horizon.h4, .d1]) { Text($0.shortLabel).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        if lab.running { ProgressView().controlSize(.small) }
                        Spacer()
                        Button {
                            lab.run(coin: coin, horizon: horizon)
                        } label: {
                            Label(lab.report == nil ? "Spočítat zdarma" : "Přepočítat", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(lab.running)
                    }
                    if let e = lab.error { Text(e).font(.footnote).foregroundStyle(Theme.bad) }
                }
                if let rep = lab.report {
                    SignalCard(report: rep, variant: lab.selected)
                    VariantsCard(report: rep, selected: Binding(get: { lab.selected }, set: { lab.selected = $0 }))
                    if let sel = lab.selectedResult {
                        EquityCard(report: rep, result: sel)
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.background)
        .navigationTitle("Trend strategie")
        .task {
            if lab.report == nil, !lab.running { lab.run(coin: coin, horizon: horizon) }
        }
    }
}

/// Dnešní signál (poslední uzavřená svíčka) pro vybranou variantu.
struct SignalCard: View {
    let report: TrendReport
    let variant: TrendVariant

    var body: some View {
        let s = report.current[variant.id]
        let pos = s?.position ?? 0
        let color: Color = pos > 0 ? Theme.good : pos < 0 ? Theme.bad : .secondary
        Card("Signál · \(Instrument.find(report.coin).label) \(report.horizon.shortLabel) · \(variant.label)") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(pos > 0 ? "LONG" : pos < 0 ? "SHORT" : "FLAT")
                    .font(.system(size: 36, weight: .heavy)).foregroundStyle(color)
                if pos != 0, abs(pos) != 1 {
                    Text(String(format: "%.2f×", abs(pos))).font(.system(size: 18, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = s?.price { Text(Fmt.px(p)).font(.system(size: 18, design: .monospaced)) }
            }
            if let since = s?.since {
                Text("v pozici od \(since.formatted(date: .abbreviated, time: report.horizon == .d1 ? .omitted : .shortened))")
                    .font(.callout)
            }
            HStack(spacing: 14) {
                if let m = s?.ma20DistBps { Text("od MA20 \(F.bps(m, digits: 0))") }
                if let m = s?.ma50DistBps { Text("od MA50 \(F.bps(m, digits: 0))") }
            }
            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            Text("Podle svíčky uzavřené \(s?.asOf.formatted(date: .abbreviated, time: .shortened) ?? "–"). Papírový signál, ne doporučení k obchodu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Tabulka variant; klepnutím se vybere varianta pro graf a signál.
struct VariantsCard: View {
    let report: TrendReport
    @Binding var selected: TrendVariant

    var body: some View {
        Card("Varianty · \(report.bars) svíček · \(String(format: "%.1f", report.years)) let") {
            Text("Po poplatcích, pozice $1000 (u ATR v průměru). „/rok“ = výsledek dělený počtem let; „propad“ = největší pokles kapitálu od maxima.")
                .font(.footnote).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("varianta").foregroundStyle(.secondary)
                    Text("/rok").foregroundStyle(.secondary)
                    Text("2. pol.").foregroundStyle(.secondary)
                    Text("propad").foregroundStyle(.secondary)
                }
                ForEach(report.variants) { v in
                    GridRow {
                        Button {
                            selected = v.variant
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: v.variant == selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Theme.jev)
                                Text(short(v.variant)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(F.bps(v.full.netBps / report.years, digits: 0))
                            .foregroundStyle(v.full.netBps > report.holdFull.netBps ? Theme.good : (v.full.netBps > 0 ? Color.primary : Theme.bad))
                        Text(F.bps(v.test.netBps, digits: 0))
                            .foregroundStyle(v.test.netBps > report.holdTest.netBps ? Theme.good : (v.test.netBps > 0 ? Color.primary : Theme.bad))
                        Text(F.money(v.maxDrawdownUsd)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Držet long").foregroundStyle(.secondary)
                    Text(F.bps(report.holdFull.netBps / report.years, digits: 0)).foregroundStyle(.secondary)
                    Text(F.bps(report.holdTest.netBps, digits: 0)).foregroundStyle(.secondary)
                    Text(F.money(report.holdDrawdownUsd)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            Text("Zelená = lepší než držení long se stejnou pozicí.").font(.caption).foregroundStyle(.secondary)
            if let url = csvURL() {
                ShareLink(item: url) { Label("Poslat CSV", systemImage: "square.and.arrow.up") }
                    .font(.callout)
            }
        }
    }

    private func short(_ v: TrendVariant) -> String {
        (v.ruleID == "trend" ? "Trend" : "Průraz") + (v.direction == .longOnly ? " L" : " L/S") + (v.sizing == .atr ? " ATR" : "")
    }

    private func csvURL() -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jevlab-trend-\(Instrument.find(report.coin).label)-\(report.horizon.shortLabel)-\(f.string(from: Date())).csv")
        return (try? TrendMath.csv(report).write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}

/// Kapitál vybrané varianty proti držení long.
struct EquityCard: View {
    let report: TrendReport
    let result: TrendVariantResult

    private var hold: [SimPoint] { report.holdFull.equity }

    var body: some View {
        Card("Kapitál · \(result.variant.label)") {
            Chart {
                ForEach(thin(hold)) { p in
                    LineMark(x: .value("Čas", p.date), y: .value("$", p.netUsd), series: .value("Řada", "Držet"))
                        .foregroundStyle(Color.gray.opacity(0.6))
                }
                ForEach(thin(result.full.equity)) { p in
                    LineMark(x: .value("Čas", p.date), y: .value("$", p.netUsd), series: .value("Řada", "Strategie"))
                        .foregroundStyle(Theme.jev)
                }
            }
            .chartYAxis { AxisMarks(position: .trailing) }
            .frame(height: 220)
            StatGrid(items: [
                ("Celkem", F.usd(result.full.usd(result.full.netBps, notional: 1000)), result.full.netBps > 0 ? Theme.good : Theme.bad),
                ("Největší propad", "−" + F.money(result.maxDrawdownUsd), Color.primary),
                ("Obchodů", "\(result.full.trades)", Color.primary),
                ("V pozici", F.pct(result.exposure), Color.primary),
                ("Ziskových svíček", result.full.hitRate.map(F.pct) ?? "–", Color.primary),
                ("Držet long", F.usd(report.holdFull.usd(report.holdFull.netBps, notional: 1000)), Color.secondary),
            ])
            Text("Fialová = strategie, šedá = držení long ($1000 stále v pozici).").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Max. ~400 bodů do grafu.
    private func thin(_ pts: [SimPoint]) -> [SimPoint] {
        guard pts.count > 400 else { return pts }
        let step = pts.count / 400 + 1
        return pts.enumerated().filter { $0.offset % step == 0 || $0.offset == pts.count - 1 }.map(\.element)
    }
}
