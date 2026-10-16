import SwiftUI
import JevLabCore

/// Databáze proběhlých běhů: smyčka, živý horizont i backtesty.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if let err = model.saveError {
                    Text(err).foregroundStyle(Theme.bad).font(.footnote)
                }
                if model.runs.isEmpty {
                    Text("Zatím žádné běhy. Každá dokončená smyčka, živý horizont i backtest se sem uloží.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.runs) { run in
                    NavigationLink(value: run.id) {
                        RunRow(run: run)
                    }
                }
                .onDelete { idx in
                    for i in idx { model.deleteRun(model.runs[i].id) }
                }
            }
            .navigationTitle("Historie")
            .navigationDestination(for: UUID.self) { id in
                RunDetailView(id: id)
            }
        }
    }
}

struct RunRow: View {
    let run: RunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.kind.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.jev.opacity(0.18), in: Capsule())
                Text(run.instrument.label).fontWeight(.semibold)
                if let h = run.horizon { Text(h.label).foregroundStyle(.secondary) }
                if run.brain { Image(systemName: "brain").foregroundStyle(.secondary) }
                Spacer()
                Text(F.usd(run.netUsd))
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundStyle(run.netUsd > 0 ? Theme.good : Theme.bad)
            }
            Text("\(run.started.formatted(date: .abbreviated, time: .shortened)) · \(run.calls) volání · \(run.trades) obchodů · \(run.strategy)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var detail: RunDetail?
    @State private var minConf: Double = 0.6
    @State private var csvURL: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let d = detail {
                    header(d.summary)
                    RunAnalysisView(records: d.records, feeRate: d.summary.feeRate, notional: d.summary.notional,
                                    minConf: $minConf, showsThreshold: d.summary.kind != .tick)
                    if d.summary.kind == .tick {
                        Text("U běhu smyčky je výsledek z papírového účtu (limitní objednávky, skutečné fills). Kalibrace měří pohyb do dalšího Jev volání.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(14)
        }
        .background(Theme.background)
        .navigationTitle(detail.map { "\($0.summary.kind.label) · \($0.summary.instrument.label)" } ?? "Běh")
        .toolbar {
            ToolbarItem {
                if let url = csvURL {
                    ShareLink(item: url) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task(id: id) { load() }
    }

    private func load() {
        guard let d = model.store.detail(id) else { return }
        detail = d
        minConf = d.summary.minConf ?? 0.6
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jevlab-\(d.summary.instrument.label)-\(d.summary.kind.rawValue)-\(Int(d.summary.started.timeIntervalSince1970)).csv")
        if (try? RunStore.csv(d).write(to: url, atomically: true, encoding: .utf8)) != nil {
            csvURL = url
        }
    }

    private func header(_ s: RunSummary) -> some View {
        Card("Přehled") {
            StatGrid(items: [
                ("Po poplatcích", F.usd(s.netUsd), s.netUsd > 0 ? Theme.good : Theme.bad),
                ("Poplatky", "−" + F.money(s.feesUsd), Color.primary),
                ("Obchody", "\(s.trades)", Color.primary),
                ("Volání", "\(s.calls)", Color.primary),
                ("Správný směr", s.hitRate.map(F.pct) ?? "–", Color.primary),
                ("Kupit a držet", s.buyHoldBps.map { F.bps($0, digits: 0) } ?? "–", Color.secondary),
            ])
            Text("\(s.started.formatted(date: .abbreviated, time: .shortened)) – \(s.ended.formatted(date: .omitted, time: .shortened)) · \(s.strategy)\(s.note.map { " · \($0)" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            if s.kind != .tick {
                Text("Výsledek v přehledu je pro práh při uložení (\(F.pct(s.minConf ?? 0.6))). Posuvníkem níže ho přepočítáš pro jiný práh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
