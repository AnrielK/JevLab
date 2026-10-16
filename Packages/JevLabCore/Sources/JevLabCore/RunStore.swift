import Foundation

public enum RunKind: String, Codable, Sendable, CaseIterable {
    case tick, live, backtest

    public var label: String {
        switch self {
        case .tick: return "Smyčka"
        case .live: return "Horizont živě"
        case .backtest: return "Backtest"
        }
    }
}

public struct FillRecord: Codable, Sendable, Equatable {
    public var t: Double
    public var side: Side
    public var px: Double
    public var kind: String
}

/// Přehled jednoho běhu (do seznamu v Historii).
public struct RunSummary: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var kind: RunKind
    public var started: Date
    public var ended: Date
    public var coin: String
    public var horizon: Horizon?
    public var strategy: String
    public var brain: Bool = false
    public var minConf: Double?
    /// Poplatek na stranu použitý v běhu.
    public var feeRate: Double
    public var notional: Double = 1000
    public var calls: Int
    public var trades: Int
    public var grossUsd: Double
    public var feesUsd: Double
    public var netUsd: Double
    public var hitRate: Double?
    public var buyHoldBps: Double?
    public var note: String?

    public var instrument: Instrument { Instrument.find(coin) }
}

/// Celý běh: přehled + všechna rozhodnutí a obchody.
public struct RunDetail: Codable, Sendable {
    public var summary: RunSummary
    public var records: [CallRecord]
    public var fills: [FillRecord] = []

    public init(summary: RunSummary, records: [CallRecord], fills: [FillRecord] = []) {
        self.summary = summary
        self.records = records
        self.fills = fills
    }
}

/// Databáze proběhlých běhů: JSON soubory v Application Support (jeden na běh + index).
public final class RunStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Výchozí umístění: Application Support/JevLab/runs.
    public static func standard() -> RunStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RunStore(directory: base.appendingPathComponent("JevLab/runs", isDirectory: true))
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func summaries() -> [RunSummary] {
        lock.lock()
        defer { lock.unlock() }
        return loadIndex().sorted { $0.started > $1.started }
    }

    private func loadIndex() -> [RunSummary] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? RunStore.decoder.decode([RunSummary].self, from: data) else { return [] }
        return list
    }

    private func writeIndex(_ list: [RunSummary]) throws {
        try RunStore.encoder.encode(list).write(to: indexURL, options: .atomic)
    }

    public func save(_ detail: RunDetail) throws {
        lock.lock()
        defer { lock.unlock() }
        try RunStore.encoder.encode(detail).write(to: fileURL(detail.summary.id), options: .atomic)
        var list = loadIndex().filter { $0.id != detail.summary.id }
        list.append(detail.summary)
        try writeIndex(list)
    }

    public func detail(_ id: UUID) -> RunDetail? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? RunStore.decoder.decode(RunDetail.self, from: data)
    }

    public func delete(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(id))
        try? writeIndex(loadIndex().filter { $0.id != id })
    }

    /// CSV všech rozhodnutí běhu (čas, směr, jistota, cena, výsledek, featury).
    public static func csv(_ detail: RunDetail) -> String {
        let keys = Array(Set(detail.records.flatMap { $0.state?.keys.map { $0 } ?? [] })).sorted()
        let iso = ISO8601DateFormatter()
        var lines = [(["time", "side", "conf", "price", "ret_next_bps", "action"] + keys).joined(separator: ",")]
        for r in detail.records {
            var row = [
                iso.string(from: r.date),
                r.side?.rawValue ?? "",
                r.conf.map { String($0) } ?? "",
                String(r.price),
                r.retNextBps.map { String($0) } ?? "",
                "\"\((r.action ?? "").replacingOccurrences(of: "\"", with: "'"))\"",
            ]
            for k in keys { row.append(r.state?[k].map { String($0) } ?? "") }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
