import Foundation

/// Otázka pro Jev (TypeSafe systemone API).
///   noul    ano/ne, odpověď jako pravděpodobnost "ano"
///   choice  výběr jedné možnosti
///   score   úroveň ze seznamu seřazeného od nejnižší
public struct JevQuestion: Sendable {
    public enum Kind: Sendable, Equatable {
        case noul
        case choice([String])
        case score([String])
    }

    public var instructions: String
    public var kind: Kind

    public init(instructions: String, kind: Kind) {
        self.instructions = instructions
        self.kind = kind
    }

    public static func choice(_ instructions: String, _ options: [String]) -> JevQuestion {
        JevQuestion(instructions: instructions, kind: .choice(options))
    }

    public static func score(_ instructions: String, _ levels: [String]) -> JevQuestion {
        JevQuestion(instructions: instructions, kind: .score(levels))
    }

    public static func noul(_ instructions: String) -> JevQuestion {
        JevQuestion(instructions: instructions, kind: .noul)
    }

    var json: [String: Any] {
        switch kind {
        case .noul:
            return ["type": "noul", "instructions": instructions]
        case .choice(let options):
            var criteria: [String: Any] = [:]
            for o in options { criteria[o] = NSNull() }
            return ["type": "choice", "instructions": instructions, "criteria": criteria]
        case .score(let levels):
            return ["type": "score", "instructions": instructions, "criteria": levels]
        }
    }
}

/// Normalizovaná odpověď Jev.
public enum JevAnswer: Equatable, Sendable {
    case noul(p: Double)
    case choice(String, probs: [String: Double])
    case score(Double, probs: [Double])

    public var choice: String? {
        if case .choice(let c, _) = self { return c }
        return nil
    }

    public var choiceProbs: [String: Double] {
        if case .choice(_, let p) = self { return p }
        return [:]
    }

    public var score: Double? {
        if case .score(let s, _) = self { return s }
        return nil
    }

    public var scoreProbs: [Double] {
        if case .score(_, let p) = self { return p }
        return []
    }
}

public struct JevError: Error, LocalizedError, Sendable {
    public var status: Int?
    public var message: String

    public init(status: Int? = nil, message: String) {
        self.status = status
        self.message = message
    }

    public var isThrottled: Bool { status == 429 }
    /// Chyby, u kterých nemá smysl pokračovat (došel rozpočet/kredity, neplatný klíč).
    public var isFatal: Bool { status == 401 || status == 402 || status == 403 }

    /// Fatální chyba poznaná z textu (když se chyba předává jako řetězec).
    public static func isFatal(_ text: String?) -> Bool {
        guard let t = text else { return false }
        return t.hasPrefix("HTTP 401") || t.hasPrefix("HTTP 402") || t.hasPrefix("HTTP 403")
    }
    public var isAuth: Bool { status == 401 || status == 403 }
    public var errorDescription: String? {
        if let s = status { return "HTTP \(s): \(message)" }
        return message
    }
}

public struct JevResult: Sendable {
    public var answers: [String: JevAnswer]
    public var latencyMs: Int
    public var model: String
}

public enum JevNormaliser {
    static func normProbs(_ raw: Any?, _ options: [String]) -> [String: Double] {
        var probs: [String: Double] = [:]
        if let d = raw as? [String: Any] {
            for o in options { probs[o] = jsonNumber(d[o]) ?? 0 }
        } else if let a = raw as? [Any], a.count == options.count {
            for (o, v) in zip(options, a) { probs[o] = jsonNumber(v) ?? 0 }
        } else {
            return [:]
        }
        let total = probs.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return probs.mapValues { $0 / total }
    }

    /// Převede surové odpovědi do jednoho tvaru (port `normalise` z jev-starteru).
    public static func normalise(questions: [String: JevQuestion], raw: [String: Any]) throws -> [String: JevAnswer] {
        var out: [String: JevAnswer] = [:]
        for (qid, q) in questions {
            guard let a = raw[qid], !(a is NSNull) else {
                throw JevError(message: "chybí odpověď pro '\(qid)'")
            }
            let dict = a as? [String: Any]
            switch q.kind {
            case .noul:
                let p: Double?
                if let d = dict {
                    p = jsonNumber(d["noul"]) ?? jsonNumber(d["p"])
                } else {
                    p = jsonNumber(a)
                }
                guard let pv = p else { throw JevError(message: "špatná noul odpověď pro '\(qid)'") }
                out[qid] = .noul(p: max(0, min(1, pv)))

            case .choice(let options):
                let rawP = dict?["probabilities"] ?? dict?["probs"]
                var probs = normProbs(rawP, options)
                var choice = dict?["choice"] as? String
                if choice == nil || !options.contains(choice!) {
                    guard !probs.isEmpty else { throw JevError(message: "špatná choice odpověď pro '\(qid)'") }
                    choice = options.max(by: { (probs[$0] ?? 0) < (probs[$1] ?? 0) })
                }
                let picked = choice ?? options[0]
                if probs.isEmpty {
                    for o in options { probs[o] = o == picked ? 1 : 0 }
                }
                out[qid] = .choice(picked, probs: probs)

            case .score(let levels):
                var score: Double?
                if let s = dict?["score"] as? String {
                    if let i = levels.firstIndex(of: s) { score = Double(i) } else { score = Double(s) }
                } else {
                    score = jsonNumber(dict?["score"])
                }
                guard let sc = score else { throw JevError(message: "špatná score odpověď pro '\(qid)'") }
                var rawP: Any? = dict?["probabilities"] ?? dict?["probs"]
                if let d = rawP as? [String: Any], !d.isEmpty, d.keys.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                    var mapped: [String: Any] = [:]
                    for (k, v) in d { if let i = Int(k), i < levels.count { mapped[levels[i]] = v } }
                    rawP = mapped
                }
                let pd = normProbs(rawP, levels)
                let probs: [Double]
                if pd.isEmpty {
                    let r = Int(sc.rounded(.toNearestOrEven))
                    probs = levels.indices.map { $0 == r ? 1 : 0 }
                } else {
                    probs = levels.map { pd[$0] ?? 0 }
                }
                out[qid] = .score(max(0, min(Double(levels.count) - 1, sc)), probs: probs)
            }
        }
        return out
    }
}

/// Klient Jev přes Vercel AI Gateway (nebo přímo TypeSafe klíčem).
public struct JevClient: Sendable {
    public static let gatewayURL = URL(string: "https://ai-gateway.vercel.sh/typesafe/v1/systemone")!
    public static let directURL = URL(string: "https://api.typesafe.ai/v1/systemone")!

    public var url: URL
    public var key: String
    public var model: String

    /// Gateway klíč (AI_GATEWAY_API_KEY).
    public init(gatewayKey: String) {
        url = JevClient.gatewayURL
        key = gatewayKey
        model = "typesafe-ai/jev"
    }

    /// Přímý TypeSafe klíč.
    public init(directKey: String) {
        url = JevClient.directURL
        key = directKey
        model = "jev-latest"
    }

    public func ask(state: [String: Any], questions: [String: JevQuestion],
                    timeout: Double = 20, retries: Int = 6) async throws -> JevResult {
        var qs: [String: Any] = [:]
        for (k, q) in questions { qs[k] = q.json }
        let body: [String: Any] = ["state": state, "model": model, "questions": qs]
        let data = try JSONSerialization.data(withJSONObject: body)

        let t0 = Date()
        let json = try await post(data, timeout: timeout, retries: retries)
        let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
        let raw = (json["answers"] as? [String: Any]) ?? json
        let answers = try JevNormaliser.normalise(questions: questions, raw: raw)
        return JevResult(answers: answers, latencyMs: ms, model: (json["model"] as? String) ?? model)
    }

    private func post(_ body: Data, timeout: Double, retries: Int) async throws -> [String: Any] {
        var attempt = 0
        while true {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body

            var retryAfter: Double?
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw JevError(message: "neplatná odpověď")
                    }
                    return obj
                }
                let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
                if ![429, 500, 502, 503, 529].contains(status) || attempt >= retries {
                    throw JevError(status: status, message: text)
                }
                retryAfter = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
            } catch let e as JevError {
                throw e
            } catch {
                if attempt >= retries || error is CancellationError { throw JevError(message: error.localizedDescription) }
            }
            // 429 = free tier je vytížený. Počkat (s ohledem na Retry-After) místo zahození volání.
            let wait = retryAfter ?? (min(8.0, 0.75 * pow(2.0, Double(attempt))) + Double.random(in: 0..<1))
            try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            attempt += 1
        }
    }
}
