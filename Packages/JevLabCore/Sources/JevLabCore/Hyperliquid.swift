import Foundation

/// Veřejná tržní data Hyperliquid. Mainnet, jen čtení, bez klíče, bez objednávek.
/// Fills se jen simulují proti těmto datům se skutečnými poplatky základního tieru.
public enum Hyperliquid {
    public static let infoURL = URL(string: "https://api.hyperliquid.xyz/info")!
    public static let wsURL = URL(string: "wss://api.hyperliquid.xyz/ws")!

    /// Perp poplatky, základní tier (na stranu).
    public static let takerFee = 0.00045
    public static let makerFee = 0.00015

    public struct Candle: Equatable, Sendable, Codable {
        public var openMs: Int64
        public var open: Double
        public var close: Double
        public var high: Double = 0
        public var low: Double = 0
        public var volume: Double = 0

        public init(openMs: Int64, open: Double, close: Double, high: Double = 0, low: Double = 0, volume: Double = 0) {
            self.openMs = openMs
            self.open = open
            self.close = close
            self.high = high == 0 ? max(open, close) : high
            self.low = low == 0 ? min(open, close) : low
            self.volume = volume
        }
    }

    /// HIP-3 trh ("xyz:NVDA" → "xyz"), nil pro nativní perpy.
    public static func dex(of coin: String) -> String? {
        guard let i = coin.firstIndex(of: ":") else { return nil }
        return String(coin[..<i])
    }

    static func info(_ body: [String: Any], timeout: Double = 10) async throws -> Any {
        var req = URLRequest(url: infoURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Střední ceny všech coinů.
    public static func mids(_ coins: [String]) async throws -> [String: Double] {
        var out: [String: Double] = [:]
        let groups = Dictionary(grouping: coins) { dex(of: $0) ?? "" }
        for (dexName, list) in groups {
            var body: [String: Any] = ["type": "allMids"]
            if !dexName.isEmpty { body["dex"] = dexName }
            let d = (try await info(body)) as? [String: Any] ?? [:]
            for c in list { if let v = jsonNumber(d[c]) { out[c] = v } }
        }
        return out
    }

    /// Minutové (či jiné) svíčky od `startMs`, stránkuje přes limit 5000 svíček.
    public static func candles(coin: String, interval: String, startMs: Int64, endMs: Int64? = nil) async throws -> [Candle] {
        let end = endMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        var rows: [Int64: Candle] = [:]
        var cursor = startMs
        while cursor < end {
            let req: [String: Any] = ["coin": coin, "interval": interval, "startTime": cursor, "endTime": end]
            let batch = (try await info(["type": "candleSnapshot", "req": req])) as? [[String: Any]] ?? []
            if batch.isEmpty { break }
            var lastOpen: Int64 = cursor
            for r in batch {
                guard let t = jsonNumber(r["t"]), let o = jsonNumber(r["o"]), let c = jsonNumber(r["c"]) else { continue }
                let ms = Int64(t)
                rows[ms] = Candle(openMs: ms, open: o, close: c, high: jsonNumber(r["h"]) ?? 0,
                                  low: jsonNumber(r["l"]) ?? 0, volume: jsonNumber(r["v"]) ?? 0)
                lastOpen = max(lastOpen, ms)
            }
            if lastOpen <= cursor || batch.count < 2 { break }
            cursor = lastOpen + 1
        }
        return rows.values.sorted { $0.openMs < $1.openMs }
    }
}

/// Událost z živého streamu.
public enum FeedEvent: Sendable {
    case quote(Quote)
    case depth(bidUSD: Double, askUSD: Double)
    case trades([MarketTrade], now: Double)
}

/// Živý WebSocket stream Hyperliquid pro jeden coin: bbo (~8× za sekundu), l2Book a obchody.
/// Sám se znovu připojí. Události doručuje na hlavní vlákno.
public final class HyperliquidFeed: NSObject {
    public let coin: String
    public var onEvent: (@MainActor (FeedEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var stopped = true

    public init(coin: String) {
        self.coin = coin
    }

    public func start() {
        stopped = false
        connect()
    }

    public func stop() {
        stopped = true
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        guard !stopped else { return }
        let t = URLSession.shared.webSocketTask(with: Hyperliquid.wsURL)
        task = t
        t.resume()
        for sub in ["bbo", "l2Book", "trades"] {
            send(["method": "subscribe", "subscription": ["type": sub, "coin": coin]], on: t)
        }
        receive(on: t)
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !Task.isCancelled, self.task === t else { return }
                self.send(["method": "ping"], on: t)
            }
        }
    }

    private func send(_ obj: [String: Any], on t: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, self.task === t else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let s): self.handle(Data(s.utf8))
                case .data(let d): self.handle(d)
                @unknown default: break
                }
                self.receive(on: t)
            case .failure:
                self.task = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.connect() }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let events = HyperliquidFeed.parse(data, now: Date().timeIntervalSince1970), !events.isEmpty else { return }
        let deliver = onEvent
        Task { @MainActor in
            for ev in events { deliver?(ev) }
        }
    }

    /// Rozparsuje jednu zprávu streamu (veřejné kvůli testům).
    public static func parse(_ data: Data, now: Double) -> [FeedEvent]? {
        guard let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let channel = msg["channel"] as? String else { return nil }
        switch channel {
        case "bbo":
            guard let d = msg["data"] as? [String: Any], let bbo = d["bbo"] as? [Any], bbo.count == 2,
                  let b = bbo[0] as? [String: Any], let a = bbo[1] as? [String: Any],
                  let bp = jsonNumber(b["px"]), let bs = jsonNumber(b["sz"]),
                  let ap = jsonNumber(a["px"]), let asz = jsonNumber(a["sz"]) else { return nil }
            return [.quote(Quote(bid: bp, ask: ap, bidSize: bs, askSize: asz, t: now))]
        case "l2Book":
            guard let d = msg["data"] as? [String: Any], let levels = d["levels"] as? [[[String: Any]]], levels.count == 2 else { return nil }
            func usd(_ side: [[String: Any]]) -> Double {
                side.prefix(5).reduce(0) { $0 + (jsonNumber($1["px"]) ?? 0) * (jsonNumber($1["sz"]) ?? 0) }
            }
            return [.depth(bidUSD: usd(levels[0]), askUSD: usd(levels[1]))]
        case "trades":
            guard let arr = msg["data"] as? [[String: Any]] else { return nil }
            let trades = arr.compactMap { tr -> MarketTrade? in
                guard let t = jsonNumber(tr["time"]), let px = jsonNumber(tr["px"]), let sz = jsonNumber(tr["sz"]) else { return nil }
                return MarketTrade(t: t / 1000, isBuy: (tr["side"] as? String) == "B", px: px, sz: sz)
            }
            return [.trades(trades, now: now)]
        default:
            return nil
        }
    }
}
