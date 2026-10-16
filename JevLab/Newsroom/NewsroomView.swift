import SwiftUI
import Charts
import JevLabCore

/// Newsroom: zrychlený replay skutečných kryptotitulků, Jev čte každý živě
/// a graf ukazuje skutečný pohyb ceny v následující hodině.
struct NewsroomView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 12) {
                    NewsControls()
                    if geo.size.width > 900 {
                        HStack(alignment: .top, spacing: 12) {
                            WireCard().frame(width: geo.size.width * 0.4)
                            VStack(spacing: 12) {
                                ReadCard()
                                ReactionCard()
                            }
                        }
                    } else {
                        ReadCard()
                        ReactionCard()
                        WireCard()
                    }
                    ScoreBoard()
                }
                .padding(14)
            }
        }
        .background(Theme.background)
    }
}

struct NewsControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bindable = model
        let news = model.newsroom
        Card {
            HStack(spacing: 12) {
                Text("**Jev** Newsroom").font(.system(size: 22, weight: .heavy))
                Text(news.round > 1 ? "REPLAY · kolo \(news.round)" : "REPLAY · skutečné titulky")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.late)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Capsule().stroke(Theme.late.opacity(0.4)))
                Spacer()
                if news.isActive {
                    Button(role: .destructive) { news.stop() } label: { Label("Zastavit", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.bad)
                } else {
                    Button { model.startNewsroom() } label: { Label("Spustit", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasKey)
                }
            }
            Text("Zprávy chodí jen párkrát za hodinu, to je na sledování moc pomalé. Proto se přehrávají titulky z posledních hodin zrychleně: Jev je čte živě a graf ukáže, co cena skutečně udělala.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Picker("Historie", selection: $bindable.newsHours) {
                    Text("12 h").tag(12.0)
                    Text("24 h").tag(24.0)
                    Text("36 h").tag(36.0)
                }
                .frame(maxWidth: 200)
                Picker("Tempo", selection: $bindable.newsGap) {
                    Text("4 s").tag(4.0)
                    Text("6 s").tag(6.0)
                    Text("10 s").tag(10.0)
                }
                .frame(maxWidth: 200)
            }
            .disabled(news.isActive)
            statusLine(news)
        }
    }

    @ViewBuilder
    private func statusLine(_ news: NewsroomEngine) -> some View {
        switch news.status {
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("načítám titulky a cenové pohyby…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(news.index), total: Double(max(1, news.total)))
                    .tint(Theme.jev)
                Text("\(news.index) / \(news.total) · \(news.loadNote)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Text(msg).font(.footnote).foregroundStyle(Theme.bad)
        default:
            EmptyView()
        }
    }
}

// MARK: - Jev čte

struct ReadCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let row = model.newsroom.current
        Card("Jev čte") {
            HStack(alignment: .top) {
                Text(row?.item.headline ?? "čekám na první titulek…")
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(latency(row))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.jev)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.jev.opacity(0.12), in: Capsule())
            }
            if let row {
                Text("\(row.item.source.uppercased()) · \(F.dayTime(row.item.published.timeIntervalSince1970))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                if let err = row.error {
                    ErrorBanner(title: "Jev neodpověděl", detail: err)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { questions(row) }
                VStack(alignment: .leading, spacing: 14) { questions(row) }
            }
            decision(row)
        }
    }

    private func latency(_ row: NewsRow?) -> String {
        guard let row else { return "—" }
        if let ms = row.ms { return "odpověď za \(ms) ms" }
        return row.error != nil ? "přeskočeno" : "čte…"
    }

    @ViewBuilder
    private func questions(_ row: NewsRow?) -> some View {
        let a = row?.answers
        bars("Který coin?", options: News.assetOptions, answer: a?["asset"]) { _ in Theme.jev }
        bars("Kterým směrem?", options: News.directionOptions, answer: a?["direction"]) { o in
            o == "bullish" ? Theme.good : o == "bearish" ? Theme.bad : Color.gray
        }
        ImpactMeter(score: a?["impact"]?.score)
    }

    private func bars(_ title: String, options: [String], answer: JevAnswer?, color: @escaping (String) -> Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            ForEach(options, id: \.self) { o in
                let p = answer?.choiceProbs[o] ?? 0
                HStack(spacing: 6) {
                    Text(o == "whole_crypto_market" ? "trh" : o)
                        .fontWeight(answer?.choice == o ? .bold : .regular)
                        .frame(width: 62, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line)
                            Capsule().fill(color(o)).frame(width: g.size.width * p)
                        }
                    }
                    .frame(height: 8)
                    Text(answer == nil ? "" : F.pct(p)).frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
        }
        .frame(minWidth: 180)
    }

    @ViewBuilder
    private func decision(_ row: NewsRow?) -> some View {
        if let row, row.answers != nil {
            if row.trade {
                banner("OBCHOD · \(row.side > 0 ? "LONG" : "SHORT") \(row.coin ?? "")",
                       "1 min po zprávě · držet \(NewsroomEngine.afterMin) min",
                       color: row.side > 0 ? Theme.good : Theme.bad)
            } else {
                let why = row.coin == nil ? "žádný obchodovatelný coin" : row.direction == "neutral" ? "bez jasného směru" : "příliš malý dopad"
                let imp = News.impactLevels[min(3, max(0, Int((row.impact ?? 0).rounded())))]
                banner("BEZ OBCHODU · \(why)", "dopad \(imp)", color: .secondary)
            }
        } else if let row, row.error != nil {
            banner("přeskočeno · Jev neodpověděl", "", color: .secondary)
        } else {
            banner(row == nil ? "čekám na první titulek…" : "Jev čte titulek…", "", color: .secondary)
        }
    }

    private func banner(_ title: String, _ sub: String, color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .bold, design: .monospaced))
            Spacer()
            Text(sub).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
        }
        .foregroundStyle(color)
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ImpactMeter: View {
    let score: Double?

    var body: some View {
        let top = score.map { Int($0.rounded()) } ?? -1
        VStack(alignment: .leading, spacing: 6) {
            Text("JAK VELKÝ?")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(Array(News.impactLevels.enumerated()), id: \.offset) { i, label in
                    Text(label)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(i == top ? Theme.late : (i < top ? Theme.late.opacity(0.25) : Theme.line),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(i == top ? Color.black : (i < top ? Theme.late : Color.secondary))
                }
            }
            Text("skóre \(score.map { String(format: "%.2f", $0) } ?? "–")")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 220)
    }
}

// MARK: - Co trh udělal potom

struct ReactionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let row = model.newsroom.current
        let coin = row?.coin ?? "BTC"
        Card("Co \(coin) udělal potom · \(NewsroomEngine.afterMin) min po titulku") {
            if let row, row.answers != nil, row.path.count > 1 {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let reveal = min(1, (ctx.date.timeIntervalSince1970 - (row.answered ?? 0)) / 2.2)
                    VStack(alignment: .leading, spacing: 8) {
                        ReactionChart(row: row, reveal: reveal)
                            .frame(height: 220)
                        if reveal >= 1 { verdict(row) }
                    }
                }
            } else {
                Text(row?.answers == nil ? "skutečný pohyb ceny se ukáže, jakmile Jev odpoví" : "pro tuhle zprávu nejsou cenová data")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }

    @ViewBuilder
    private func verdict(_ row: NewsRow) -> some View {
        let move = row.retBps ?? row.path.last?.bps ?? 0
        if row.trade {
            let right = Double(row.side) * move > 0
            Text("\(right ? "SPRÁVNĚ" : "ŠPATNĚ") · \(F.bps(row.netBps ?? move)) po nákladech")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(right ? Theme.good : Theme.line, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(right ? Color.black : Color.primary)
        } else {
            Text("JEV PASOVAL · pohyb byl \(F.bps(move))")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

struct ReactionChart: View {
    let row: NewsRow
    let reveal: Double

    var body: some View {
        let before = Double(NewsroomEngine.beforeMin)
        let after = Double(NewsroomEngine.afterMin)
        let lastMin = -before + reveal * (after + before)
        let shown = row.path.filter { $0.minute <= lastMin }
        let ys = row.path.map(\.bps) + [0]
        let lo = ys.min() ?? -5
        let hi = ys.max() ?? 5
        let pad = (hi - lo) * 0.15 > 0 ? (hi - lo) * 0.15 : 5
        Chart {
            if row.trade {
                RectangleMark(xStart: .value("od", 0.0), xEnd: .value("do", after))
                    .foregroundStyle((row.side > 0 ? Theme.good : Theme.bad).opacity(0.06))
            }
            RuleMark(y: .value("nula", 0.0)).foregroundStyle(Theme.line)
            RuleMark(x: .value("zpráva", 0.0))
                .foregroundStyle(Theme.jev)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            ForEach(shown, id: \.minute) { p in
                AreaMark(x: .value("min", p.minute), y: .value("bps", p.bps))
                    .foregroundStyle(Theme.jev.opacity(0.18))
            }
            ForEach(shown, id: \.minute) { p in
                LineMark(x: .value("min", p.minute), y: .value("bps", p.bps))
                    .foregroundStyle(Color.white)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let e = shown.last {
                PointMark(x: .value("min", e.minute), y: .value("bps", e.bps))
                    .foregroundStyle(Color.white)
                    .annotation(position: .trailing) {
                        Text(F.bps(e.bps)).font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
            }
        }
        .chartXScale(domain: -before...after)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis {
            AxisMarks(values: [-10.0, 0, 15, 30, 45, 60]) { v in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    let m = v.as(Double.self) ?? 0
                    Text(m == 0 ? "zpráva" : (m > 0 ? "+" : "") + "\(Int(m))m")
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))") }
            }
        }
    }
}

// MARK: - Drát a skóre

struct WireCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = Array(model.newsroom.feed.suffix(9).reversed())
        Card("Zpravodajský drát") {
            if rows.isEmpty {
                Text("cointelegraph · coindesk · decrypt · the block")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                WireRow(row: row, isNow: i == 0)
            }
        }
        .animation(.easeOut(duration: 0.4), value: rows.first?.id)
    }
}

struct WireRow: View {
    let row: NewsRow
    let isNow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(F.dayTime(row.item.published.timeIntervalSince1970))
                Text(row.item.source.uppercased()).foregroundStyle(.secondary)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(row.item.headline)
                .font(.system(size: 14))
                .foregroundStyle(isNow ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            tags
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isNow ? Theme.jev.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isNow ? Theme.jev.opacity(0.45) : Color.clear))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var tags: some View {
        if row.answers != nil {
            HStack(spacing: 6) {
                chip(row.coin.map { _ in row.answers?["asset"]?.choice == "whole_crypto_market" ? "TRH" : (row.coin ?? "") } ?? "BEZ COINU",
                     color: row.coin == nil ? Color.secondary : Theme.jev)
                chip(row.direction == "bullish" ? "▲ BULLISH" : row.direction == "bearish" ? "▼ BEARISH" : "NEUTRAL",
                     color: row.direction == "bullish" ? Theme.good : row.direction == "bearish" ? Theme.bad : Color.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i <= Int((row.impact ?? 0).rounded()) ? Theme.late : Theme.line)
                            .frame(width: 7, height: 7)
                    }
                }
                if row.trade { chip("OBCHOD", color: .white) }
            }
        } else if row.error != nil {
            chip("přeskočeno", color: .secondary)
        } else {
            Text("Jev čte ▍").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.jev)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ScoreBoard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.newsroom.score
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            tile("Přečteno titulků", "\(s.read)")
            tile("Přiřazeno coinu", "\(s.tagged)")
            tile("K obchodu (Notable+)", "\(s.trades)")
            tile("Správný směr", s.trades > 0 ? "\(s.right) z \(s.trades)" : "–")
            tile("Po nákladech, 60min držení", s.trades > 0 ? F.bps(s.netBps, digits: 0) : "–",
                 color: s.netBps > 0 ? Theme.good : .primary)
        }
    }

    private func tile(_ k: String, _ v: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}
