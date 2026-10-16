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
    @Binding var mode: SimMode
    var showsThreshold = true

    var body: some View {
        let hasBias = Analysis.hasBias(records)
        let m: SimMode = hasBias ? mode : .jev
        let sim = Analysis.simulate(records, minConf: minConf, feeRate: feeRate, notional: notional, mode: m)
        let done = records.filter { $0.retNextBps != nil }.count
        VStack(spacing: 12) {
            if showsThreshold && hasBias {
                ComparisonCard(records: records, feeRate: feeRate, notional: notional, minConf: minConf)
            }
            if showsThreshold {
                Card("Výsledek po poplatcích") {
                    if hasBias {
                        Picker("Kdo rozhoduje", selection: $mode) {
                            ForEach(SimMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
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
            if showsThreshold && records.contains(where: { $0.state != nil }) {
                RulesCard(records: records, feeRate: feeRate, notional: notional)
                ModelCard(records: records, feeRate: feeRate)
            }
            if showsThreshold {
                SweepCard(records: records, feeRate: feeRate, minConf: minConf, mode: m)
                WalkForwardCard(records: records, feeRate: feeRate, defaultThreshold: minConf, mode: m)
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
    var mode: SimMode = .jev

    var body: some View {
        let points = Analysis.sweep(records, feeRate: feeRate, mode: mode)
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
    var mode: SimMode = .jev

    var body: some View {
        Card(mode == .jev ? "Walk-forward test" : "Walk-forward test · \(mode.label)") {
            if let wf = Analysis.walkForward(records, feeRate: feeRate, defaultThreshold: defaultThreshold, mode: mode) {
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

/// Jev sám vs Jev + Claude vs Claude sám ze stejných uložených rozhodnutí (bez dalších volání).
struct ComparisonCard: View {
    let records: [CallRecord]
    let feeRate: Double
    let notional: Double
    let minConf: Double

    var body: some View {
        Card("Přidává Claude hodnotu?") {
            Text("Stejná data, tři způsoby rozhodování. „Nová data“ = druhá polovina období, stejná část jako ve walk-forward testu.")
                .font(.footnote).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("celé období").foregroundStyle(.secondary)
                    Text("nová data").foregroundStyle(.secondary)
                    Text("obchodů").foregroundStyle(.secondary)
                }
                ForEach(SimMode.allCases, id: \.self) { m in
                    row(m)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            Text("Kupit a držet za celé období: \(F.bps(Analysis.buyHoldBps(records), digits: 0))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ m: SimMode) -> some View {
        let all = Analysis.simulate(records, minConf: minConf, feeRate: feeRate, notional: notional, mode: m)
        let test = Analysis.testHalf(records, minConf: minConf, feeRate: feeRate, mode: m)
        GridRow {
            Text(m.label).fontWeight(.semibold)
            Text(F.usd(all.usd(all.netBps, notional: notional)))
                .foregroundStyle(all.netBps > 0 ? Theme.good : Theme.bad)
            Text(test.map { F.bps($0.netBps, digits: 0) } ?? "–")
                .foregroundStyle((test?.netBps ?? 0) > 0 ? Theme.good : Theme.bad)
            Text("\(all.trades)")
        }
    }
}

/// Pravidlové strategie nad uloženými featurami (bez Jev volání).
struct RulesCard: View {
    let records: [CallRecord]
    let feeRate: Double
    let notional: Double

    var body: some View {
        let results = Analysis.rules(records, feeRate: feeRate)
        Card("Pravidla nad indikátory (bez Jev)") {
            Text("Stejné featury, ale rozhoduje pevné pravidlo. Signál otevře pozici, bez nového signálu se drží max. 5 svíček. Pravidla nemají nic naučeného, takže i celé období je poctivé číslo.")
                .font(.footnote).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("pravidlo").foregroundStyle(.secondary)
                    Text("celé").foregroundStyle(.secondary)
                    Text("2. pol.").foregroundStyle(.secondary)
                    Text("signálů").foregroundStyle(.secondary)
                }
                ForEach(results) { r in
                    GridRow {
                        Text(r.rule.name).fontWeight(.semibold)
                        Text(F.bps(r.full.netBps, digits: 0))
                            .foregroundStyle(r.full.netBps > 0 ? Theme.good : Theme.bad)
                        Text(r.test.map { F.bps($0.netBps, digits: 0) } ?? "–")
                            .foregroundStyle((r.test?.netBps ?? 0) > 0 ? Theme.good : Theme.bad)
                        Text("\(r.signals)")
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            ForEach(results) { r in
                Text("\(r.rule.name): \(r.rule.detail)").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Kupit a držet: \(F.bps(Analysis.buyHoldBps(records), digits: 0)) za celé období")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Jednoduchý model (logistická regrese) natrénovaný na první polovině, test na druhé.
struct ModelCard: View {
    let records: [CallRecord]
    let feeRate: Double

    var body: some View {
        Card("Dá se z featur něco naučit?") {
            if let m = FeatureModel.walkForward(records, feeRate: feeRate) {
                Text("Logistická regrese odhaduje, jestli další svíčka skončí výš. Učí se na prvních \(m.trainCount) svíčkách z \(m.features) featur, testuje na dalších \(m.testCount). Obchoduje jen při odhadu nad 55 % nebo pod 45 %.")
                    .font(.footnote).foregroundStyle(.secondary)
                StatGrid(items: [
                    ("Trefa na tréninku", F.pct(m.trainAccuracy), Color.secondary),
                    ("Trefa na nových", F.pct(m.testAccuracy), m.testAccuracy > max(m.testBaseRate, 1 - m.testBaseRate) ? Theme.good : Color.primary),
                    ("Základ (vždy většinový směr)", F.pct(max(m.testBaseRate, 1 - m.testBaseRate)), Color.secondary),
                    ("Na nových po poplatcích", F.bps(m.test.netBps, digits: 0), m.test.netBps > 0 ? Theme.good : Theme.bad),
                ])
                Text("Největší váhy (+ = víc nahoru, − = víc dolů):").font(.caption.weight(.semibold))
                ForEach(m.topWeights) { w in
                    HStack {
                        Text(w.feature).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%+.2f", w.weight)).foregroundStyle(w.weight > 0 ? Theme.good : Theme.bad)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
                Text(verdict(m)).font(.callout)
            } else {
                Text("Potřebuje aspoň 40 rozhodnutí s uloženými featurami.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func verdict(_ m: ModelReport) -> String {
        let base = max(m.testBaseRate, 1 - m.testBaseRate)
        if m.testAccuracy <= base + 0.02 {
            return "Na nových datech model nepřekonal ani prosté „vždy většinový směr“. Ve featurách tu není naučitelný signál; Jev z nich tím spíš nic nevytěží."
        }
        if m.test.netBps <= 0 {
            return "Model směr trefuje o něco líp než náhoda, ale po poplatcích to nestačí."
        }
        return "Model má na nových datech kladný výsledek. Ověř na jiném období a trhu, než tomu uvěříš."
    }
}
