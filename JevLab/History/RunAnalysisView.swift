import SwiftUI
import Charts
import JevLabCore

/// Co se dá z uložených rozhodnutí naučit: výsledek po poplatcích, kalibrace jistoty,
/// výsledek pro různé prahy a poctivý walk-forward test. Vše bez dalších Jev volání.
struct RunAnalysisView: View {
    let records: [CallRecord]
    let feeRate: Double
    var notional: Double = 1000
    /// Práh, pro který se počítá výsledek; nil = tick běh (výsledek je z papírového účtu).
    @Binding var minConf: Double
    var showsThreshold = true

    var body: some View {
        let sim = Analysis.simulate(records, minConf: minConf, feeRate: feeRate, notional: notional)
        let done = records.filter { $0.retNextBps != nil }.count
        VStack(spacing: 12) {
            if showsThreshold {
                Card("Výsledek po poplatcích") {
                    HStack {
                        Text("Práh jistoty")
                        Slider(value: $minConf, in: 0.5...0.95, step: 0.05)
                        Text(F.pct(minConf)).font(.system(.body, design: .monospaced)).frame(width: 52)
                    }
                    StatGrid(items: [
                        ("Po poplatcích", F.usd(sim.usd(sim.netBps, notional: notional)), sim.netBps > 0 ? Theme.good : Theme.bad),
                        ("Před poplatky", F.usd(sim.usd(sim.grossBps, notional: notional)), Color.primary),
                        ("Poplatky", "−" + F.money(sim.usd(sim.feesBps, notional: notional)), Color.primary),
                        ("Změny pozice", "\(sim.trades)", Color.primary),
                        ("Správný směr", sim.hitRate.map(F.pct) ?? "–", Color.primary),
                        ("Kupit a držet", F.bps(Analysis.buyHoldBps(records), digits: 0), Color.secondary),
                    ])
                    if sim.equity.count > 1 {
                        Chart(sim.equity) { p in
                            LineMark(x: .value("Čas", p.date), y: .value("$", p.netUsd))
                                .foregroundStyle(Theme.jev)
                        }
                        .chartYAxis { AxisMarks(position: .trailing) }
                        .frame(height: 160)
                    }
                    Text("$\(Int(notional)) pozice · poplatek \(String(format: "%.2f", feeRate * 1e4)) bps na stranu · \(done) vyhodnocených rozhodnutí")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            CalibrationCard(records: records)
            if showsThreshold {
                SweepCard(records: records, feeRate: feeRate, minConf: minConf)
                WalkForwardCard(records: records, feeRate: feeRate, defaultThreshold: minConf)
            }
        }
    }
}

struct StatGrid: View {
    let items: [(String, String, Color)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[i].0).font(.caption).foregroundStyle(.secondary)
                    Text(items[i].1).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(items[i].2)
                }
            }
        }
    }
}

/// Má jistota Jev nějakou hodnotu? Když vyšší jistota znamená vyšší úspěšnost a větší pohyb, ano.
struct CalibrationCard: View {
    let records: [CallRecord]

    var body: some View {
        let buckets = Analysis.calibration(records)
        Card("Kalibrace jistoty") {
            Text("Když Jev říká X %, jak často má skutečně pravdu? A o kolik se cena v průměru pohnula jeho směrem?")
                .font(.footnote).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("jistota").foregroundStyle(.secondary)
                    Text("počet").foregroundStyle(.secondary)
                    Text("pravda").foregroundStyle(.secondary)
                    Text("pohyb jeho směrem").foregroundStyle(.secondary)
                }
                ForEach(buckets) { b in
                    GridRow {
                        Text("\(Int(b.lower * 100))–\(Int((b.upper * 100).rounded())) %")
                        Text("\(b.count)")
                        Text(b.hitRate.map(F.pct) ?? "–")
                            .foregroundStyle((b.hitRate ?? 0.5) > 0.5 ? Theme.good : Color.primary)
                        Text(b.count > 0 ? F.bps(b.avgSignedBps, digits: 2) : "–")
                            .foregroundStyle(b.avgSignedBps > 0 ? Theme.good : (b.avgSignedBps < 0 ? Theme.bad : Color.primary))
                    }
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
        }
    }
}

/// Výsledek po poplatcích pro každý práh jistoty.
struct SweepCard: View {
    let records: [CallRecord]
    let feeRate: Double
    let minConf: Double

    var body: some View {
        let points = Analysis.sweep(records, feeRate: feeRate)
        Card("Který práh by vydělal nejvíc (na celých datech)") {
            Chart(points) { p in
                BarMark(x: .value("Práh", F.pct(p.threshold)), y: .value("bps", p.result.netBps))
                    .foregroundStyle(p.result.netBps >= 0 ? Theme.good : Theme.bad)
                    .opacity(abs(p.threshold - minConf) < 0.001 ? 1 : 0.55)
            }
            .chartYAxis { AxisMarks(position: .trailing) }
            .frame(height: 150)
            Text("Pozor: nejlepší sloupec je vybraný zpětně na stejných datech, takže výsledek přeceňuje. Poctivé číslo je ve walk-forward testu níže.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Práh vybraný na první polovině dat, vyhodnocený na druhé.
struct WalkForwardCard: View {
    let records: [CallRecord]
    let feeRate: Double
    let defaultThreshold: Double

    var body: some View {
        Card("Walk-forward test") {
            if let wf = Analysis.walkForward(records, feeRate: feeRate, defaultThreshold: defaultThreshold) {
                Text("Práh se vybere na prvních \(wf.trainCount) rozhodnutích a pak se vyhodnotí na dalších \(wf.testCount), která výběr neviděl.")
                    .font(.footnote).foregroundStyle(.secondary)
                StatGrid(items: [
                    ("Vybraný práh", F.pct(wf.chosen), Color.primary),
                    ("Na tréninku", F.bps(wf.trainNetBps, digits: 0), Color.secondary),
                    ("Na nových datech", F.bps(wf.testNetBps, digits: 0), wf.testNetBps > 0 ? Theme.good : Theme.bad),
                    ("Tvůj práh na nových", F.bps(wf.testDefaultNetBps, digits: 0), wf.testDefaultNetBps > 0 ? Theme.good : Theme.bad),
                    ("Kupit a držet", F.bps(wf.testBuyHoldBps, digits: 0), Color.secondary),
                ])
                Text(verdict(wf)).font(.callout)
            } else {
                Text("Potřebuje aspoň 20 vyhodnocených rozhodnutí.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func verdict(_ wf: WalkForward) -> String {
        if wf.testNetBps <= 0 {
            return "Na nových datech strategie po poplatcích prodělala. Z tohohle vzorku se nedá říct, že by Jev měl použitelnou výhodu."
        }
        if wf.testNetBps < wf.trainNetBps / 3 {
            return "Na nových datech je výsledek kladný, ale výrazně slabší než na tréninku. Typický znak přeučení, chce to víc dat."
        }
        return "Na nových datech výsledek drží. Slibné, ale jeden vzorek nestačí: ověř na jiných obdobích a trzích."
    }
}
