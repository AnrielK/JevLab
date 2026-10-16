import Foundation
import Observation

/// Claudův směr pro další úsek: jen nákupy, jen prodeje, nebo mimo trh.
public enum Bias: String, Codable, Sendable, CaseIterable {
    case long, short, flat
}

/// Souhrn trhu, který Claude čte (z 5min svíček Hyperliquid).
public struct MarketSummary: Sendable, Equatable {
    public var coin: String
    public var price: Double
    public var change15mPct: Double
    public var change1hPct: Double
    public var change4hPct: Double
    public var change24hPct: Double?
    public var avg5mMovePct: Double
    public var high4h: Double
    public var low4h: Double
    public var fundingRatePct: Double?

    var json: [String: Any] {
        var d: [String: Any] = [
            "coin": coin, "price": price,
            "change_15m_pct": change15mPct, "change_1h_pct": change1hPct, "change_4h_pct": change4hPct,
            "avg_5m_move_pct": avg5mMovePct, "high_4h": high4h, "low_4h": low4h,
        ]
        if let c = change24hPct { d["change_24h_pct"] = c }
        if let f = fundingRatePct { d["funding_rate_pct"] = f }
        return d
    }
}

/// Stav Claudova „mozku“ pro UI.
public struct BrainState: Sendable, Equatable {
    public var bias: Bias?
    public var confidence: Double?
    public var reason: String = "čekám na první Claudovo čtení trhu"
    public var t: Double?
    public var ms: Int?
    public var error: String?
    public var model: String = ""
    public var summary: MarketSummary?
}

/// Čistá logika mozku (testovatelná bez sítě).
public enum BrainLogic {
    /// Souhrn ze zavíracích cen 5min svíček, od nejstarší (port `market_summary` z jev-starteru).
    public static func summary(coin: String, closes: [Double], change24hPct: Double?, fundingRatePct: Double?) -> MarketSummary? {
        guard closes.count >= 13, let last = closes.last else { return nil }
        func pct(_ a: Double, _ b: Double) -> Double { rounded(100 * (b / a - 1), 2) }
        var moves: [Double] = []
        for k in 1..<closes.count { moves.append(abs(pct(closes[k - 1], closes[k]))) }
        let n = closes.count
        return MarketSummary(
            coin: coin, price: last,
            change15mPct: pct(closes[n - 4], last),
            change1hPct: pct(closes[n - 13], last),
            change4hPct: pct(closes[0], last),
            change24hPct: change24hPct,
            avg5mMovePct: rounded(moves.reduce(0, +) / Double(moves.count), 3),
            high4h: closes.max() ?? last,
            low4h: closes.min() ?? last,
            fundingRatePct: fundingRatePct
        )
    }

    /// Vytáhne JSON {"bias", "confidence", "reason"} z Claudovy odpovědi. Neznámý bias = flat.
    public static func parseReply(_ text: String) -> (bias: Bias, confidence: Double, reason: String)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        let bias = Bias(rawValue: (obj["bias"] as? String ?? "").lowercased()) ?? .flat
        let conf = max(0, min(1, jsonNumber(obj["confidence"]) ?? 0))
        let reason = String((obj["reason"] as? String ?? "").prefix(200))
        return (bias, conf, reason)
    }

    /// Claudova brána před strategií (stejná pravidla jako výchozí `decide()` ve starteru).
    /// Vrací akci, když Claude rozhodne sám; nil = ať rozhodne strategie.
    public static func gate(bias: Bias?, want: Int, position: Int) -> StrategyAction? {
        guard let bias else { return .hold("waiting for Claude") }
        switch bias {
        case .flat:
            return position != 0 ? .flat : .hold("Claude says stay out")
        case .long:
            if position < 0 { return .flat } // Claude změnil názor: nejdřív ven ze starého směru
            if want < 0 { return .hold("against Claude's long bias") }
        case .short:
            if position > 0 { return .flat }
            if want > 0 { return .hold("against Claude's short bias") }
        }
        return nil
    }

    public static func prompt(minutes: Double, summary: MarketSummary, headlines: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: summary.json, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let news = headlines.isEmpty ? "- (none)" : headlines.map { "- \($0)" }.joined(separator: "\n")
        return """
        You are the portfolio manager for a small, cautious crypto trading bot (paper trading).
        A fast AI makes buy/sell calls every second, but it can only trade in the direction you allow.
        Decide the bias for the next \(Int(minutes)) minutes: "long" (only buying allowed), "short" (only selling allowed),
        or "flat" (stay out, close any position).
        If the evidence leans one way (momentum across timeframes, funding, the news), pick that side and let
        "confidence" say how strongly it leans. Choose "flat" only when the signals genuinely conflict or the market is dead.

        Market data:
        \(data)

        Latest crypto headlines:
        \(news)

        Reply with ONLY a JSON object: {"bias": "long" | "short" | "flat", "confidence": 0.0-1.0, "reason": "one short sentence in Czech"}
        """
    }
}

/// Claude přes Vercel AI Gateway (OpenAI-kompatibilní Chat Completions).
public struct ClaudeClient: Sendable {
    public static let url = URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!
    public static let defaultModel = "anthropic/claude-sonnet-5.5"

    public var key: String
    public var model: String

    public init(gatewayKey: String, model: String = ClaudeClient.defaultModel) {
        key = gatewayKey
        self.model = model.isEmpty ? ClaudeClient.defaultModel : model
    }

    public func complete(_ prompt: String, maxTokens: Int = 300) async throws -> (text: String, ms: Int) {
        var req = URLRequest(url: ClaudeClient.url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "temperature": 0, "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw JevError(status: status, message: String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw JevError(message: "neplatná odpověď od Clauda")
        }
        return (text, Int((Date().timeIntervalSince(t0) * 1000).rounded()))
    }
}

extension Hyperliquid {
    /// Funding (v %) a 24h změna (v %) pro coin z metaAndAssetCtxs.
    public static func assetContext(coin: String) async throws -> (fundingPct: Double?, change24hPct: Double?) {
        guard let arr = (try await info(["type": "metaAndAssetCtxs"])) as? [Any], arr.count == 2,
              let meta = arr[0] as? [String: Any], let universe = meta["universe"] as? [[String: Any]],
              let ctxs = arr[1] as? [[String: Any]],
              let i = universe.firstIndex(where: { ($0["name"] as? String) == coin }), i < ctxs.count else {
            return (nil, nil)
        }
        let c = ctxs[i]
        let funding = jsonNumber(c["funding"]).map { rounded($0 * 100, 4) }
        var change: Double?
        if let mark = jsonNumber(c["markPx"]), let prev = jsonNumber(c["prevDayPx"]), prev > 0 {
            change = rounded(100 * (mark / prev - 1), 2)
        }
        return (funding, change)
    }
}

/// Claude jako „mozek“: každých N minut přečte trh a titulky a nastaví bias long/short/flat.
/// Jev a strategie dál dělají rychlá volání, ale jen ve směru, který Claude dovolí.
@MainActor
@Observable
public final class ClaudeBrain {
    public private(set) var state = BrainState()
    public private(set) var thinking = false
    public let coin: String
    public let everyMinutes: Double

    @ObservationIgnored private let client: ClaudeClient
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(coin: String, everyMinutes: Double, client: ClaudeClient) {
        self.coin = coin
        self.everyMinutes = everyMinutes
        self.client = client
        state.model = client.model
    }

    public func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.think()
                let wait = (self?.everyMinutes ?? 10) * 60
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func thinkNow() {
        Task { [weak self] in await self?.think() }
    }

    public func think() async {
        guard !thinking else { return }
        thinking = true
        defer { thinking = false }
        do {
            let startMs = Int64((Date().timeIntervalSince1970 - 49 * 5 * 60) * 1000)
            let candles = try await Hyperliquid.candles(coin: coin, interval: "5m", startMs: startMs)
            var funding: Double?
            var change24h: Double?
            if let ctx = try? await Hyperliquid.assetContext(coin: coin) {
                funding = ctx.fundingPct
                change24h = ctx.change24hPct
            }
            guard let summary = BrainLogic.summary(coin: coin, closes: candles.suffix(49).map(\.close),
                                                   change24hPct: change24h, fundingRatePct: funding) else {
                throw JevError(message: "málo cenových dat pro souhrn trhu")
            }
            let news = await News.fetchHeadlines(hours: 6).items.suffix(8).map(\.headline)
            let prompt = BrainLogic.prompt(minutes: everyMinutes, summary: summary, headlines: Array(news))
            let reply = try await client.complete(prompt)
            guard let parsed = BrainLogic.parseReply(reply.text) else {
                throw JevError(message: "Claude neodpověděl platným JSON: \(reply.text.prefix(120))")
            }
            state.bias = parsed.bias
            state.confidence = parsed.confidence
            state.reason = parsed.reason
            state.t = Date().timeIntervalSince1970
            state.ms = reply.ms
            state.error = nil
            state.summary = summary
        } catch {
            // poslední bias zůstává; když ještě žádný nebyl, bot zůstane mimo trh
            state.error = String(error.localizedDescription.prefix(200))
            if state.bias == nil {
                state.bias = .flat
                state.reason = "Claude nedostupný, zůstávám mimo trh"
                state.t = Date().timeIntervalSince1970
            }
        }
    }
}
