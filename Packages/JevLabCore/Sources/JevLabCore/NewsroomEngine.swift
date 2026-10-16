import Foundation
import Observation

/// Jedna zpráva v newsroomu a co si o ní Jev myslí.
public struct NewsRow: Identifiable, Sendable {
    public var id = UUID()
    public var item: Headline
    public var arrived: Double
    public var answered: Double?
    public var answers: [String: JevAnswer]?
    public var ms: Int?
    public var error: String?
    public var coin: String?
    public var side: Int = 0
    public var retBps: Double?
    public var netBps: Double?

    public var trade: Bool { side != 0 }
    public var direction: String? { answers?["direction"]?.choice }
    public var impact: Double? { answers?["impact"]?.score }
    /// Cesta ceny pro coin, ke kterému se zpráva vztahuje (jinak BTC).
    public var path: [PathPoint] { item.paths[coin ?? "BTC"] ?? [] }
}

public struct NewsScore: Sendable, Equatable {
    public var read = 0
    public var tagged = 0
    public var trades = 0
    public var right = 0
    public var netBps = 0.0
    public var latencies: [Int] = []

    public var medianMs: Int? {
        guard !latencies.isEmpty else { return nil }
        return latencies.sorted()[latencies.count / 2]
    }
}

public enum NewsroomStatus: Equatable, Sendable {
    case idle, loading, running, done
    case failed(String)
}

/// Newsroom: přehrává posledních N hodin skutečných titulků zrychleně, Jev čte každý živě
/// a graf ukazuje, co cena skutečně udělala potom. Pravidlo: obchodovat jen "Notable"/"Major",
/// ve směru Jev, od 1 min po zprávě, držet 60 min. Žádné objednávky.
@MainActor
@Observable
public final class NewsroomEngine {
    public static let beforeMin = 10
    public static let afterMin = 60
    /// Náklady round-tripu: 2× taker + 1 bps skluz.
    public static let costBps = 2e4 * Hyperliquid.takerFee + 1

    public private(set) var status: NewsroomStatus = .idle
    public private(set) var hours: Double = 36
    public private(set) var gap: Double = 6
    public private(set) var total = 0
    public private(set) var index = 0
    public private(set) var round = 1
    public private(set) var feed: [NewsRow] = []
    public private(set) var score = NewsScore()
    public private(set) var model = ""
    public private(set) var loadNote = ""

    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public var isActive: Bool { status == .loading || status == .running }
    public var current: NewsRow? { feed.last }

    public func start(hours: Double, gap: Double, jev: JevClient) {
        stop()
        self.hours = hours
        self.gap = gap
        model = jev.model
        feed = []
        score = NewsScore()
        round = 1
        index = 0
        total = 0
        status = .loading
        task = Task { [weak self] in await self?.run(jev) }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if isActive { status = .done }
    }

    private func load() async -> [Headline] {
        let (all, perFeed) = await News.fetchHeadlines(hours: hours)
        let now = Date()
        let fresh = all.filter { $0.published.addingTimeInterval(Double(NewsroomEngine.afterMin + 2) * 60) < now }
        loadNote = perFeed.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value < 0 ? "nedostupný" : "\($0.value)")" }
            .joined(separator: " · ")
        guard let first = fresh.first else { return [] }
        let startMs = Int64((first.published.timeIntervalSince1970 - Double(NewsroomEngine.beforeMin + 5) * 60) * 1000)
        var candles: [String: [Hyperliquid.Candle]] = [:]
        for c in News.coins {
            candles[c] = (try? await Hyperliquid.candles(coin: c, interval: "1m", startMs: startMs)) ?? []
        }
        return News.pricePaths(for: fresh, candles: candles, before: NewsroomEngine.beforeMin, after: NewsroomEngine.afterMin)
    }

    private func run(_ jev: JevClient) async {
        var items = await load()
        if Task.isCancelled { return }
        guard !items.isEmpty else {
            status = .failed("Zatím žádné titulky dost staré na vyhodnocení (\(loadNote)).")
            return
        }
        total = items.count
        status = .running

        while !Task.isCancelled {
            for it in items {
                if Task.isCancelled { return }
                index += 1
                let t0 = Date()
                feed.append(NewsRow(item: it, arrived: t0.timeIntervalSince1970))
                if feed.count > 300 { feed.removeFirst(feed.count - 300) }
                let row = feed.count - 1 // zpráva je na drátě dřív, než Jev odpoví

                let state: [String: Any] = ["headline": it.headline, "summary": it.summary, "source": it.source]
                do {
                    let res = try await jev.ask(state: state, questions: News.questions, timeout: 10, retries: 3)
                    if Task.isCancelled { return }
                    apply(res, to: row)
                } catch {
                    if Task.isCancelled { return }
                    feed[row].error = String(error.localizedDescription.prefix(120))
                    feed[row].answered = Date().timeIntervalSince1970
                }
                let left = gap - Date().timeIntervalSince(t0)
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1e9)) }
            }
            // kolo hotové: načíst čerstvé titulky a jet znovu s novým skóre
            round += 1
            index = 0
            score = NewsScore()
            let next = await load()
            if !next.isEmpty { items = next }
            total = items.count
        }
    }

    private func apply(_ res: JevResult, to row: Int) {
        let (coin, rawSide) = News.judgeCall(res.answers)
        let side = coin == nil ? 0 : rawSide // bez obchodovatelného coinu žádný obchod
        var r = feed[row]
        r.answers = res.answers
        r.ms = res.latencyMs
        r.answered = Date().timeIntervalSince1970
        r.coin = coin
        r.side = side
        r.retBps = r.path.first(where: { $0.minute == Double(NewsroomEngine.afterMin) })?.bps

        score.read += 1
        score.latencies.append(res.latencyMs)
        if coin != nil { score.tagged += 1 }
        if side != 0, let ret = r.retBps {
            score.trades += 1
            if Double(side) * ret > 0 { score.right += 1 }
            let net = rounded(Double(side) * ret - NewsroomEngine.costBps, 1)
            r.netBps = net
            score.netBps += net
        }
        feed[row] = r
    }
}
