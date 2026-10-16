import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Bod cenové reakce: minuty od vstupu (1 min po zprávě) a pohyb v bps.
public struct PathPoint: Equatable, Sendable {
    public var minute: Double
    public var bps: Double
}

public struct Headline: Identifiable, Sendable {
    public var source: String
    public var headline: String
    public var summary: String
    public var published: Date
    public var paths: [String: [PathPoint]] = [:]

    public var id: String { headline.lowercased() }

    public init(source: String, headline: String, summary: String, published: Date) {
        self.source = source
        self.headline = headline
        self.summary = summary
        self.published = published
    }
}

/// Kryptozprávy z veřejných RSS feedů a otázky, na které Jev u každé odpovídá.
public enum News {
    public static let feeds: [(name: String, url: String)] = [
        ("cointelegraph", "https://cointelegraph.com/rss"),
        ("coindesk", "https://www.coindesk.com/arc/outboundfeeds/rss/"),
        ("decrypt", "https://decrypt.co/feed"),
        ("theblock", "https://www.theblock.co/rss.xml"),
    ]
    public static let coins = ["BTC", "ETH", "SOL"]
    public static let assetOptions = ["BTC", "ETH", "SOL", "whole_crypto_market", "none"]
    public static let directionOptions = ["bullish", "bearish", "neutral"]
    public static let impactLevels = ["Noise", "Minor", "Notable", "Major"]

    public static let questions: [String: JevQuestion] = [
        "asset": .choice("Which tradable asset does this news most directly affect?", assetOptions),
        "direction": .choice("Is this news likely to push that asset's price up or down from here?", directionOptions),
        "impact": .score("How much is this news likely to move that asset's price?", impactLevels),
    ]

    /// Stáhne titulky z posledních `hours` hodin, seřazené od nejstarších. Vrací i počty po feedech.
    public static func fetchHeadlines(hours: Double) async -> (items: [Headline], perFeed: [String: Int]) {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        var items: [Headline] = []
        var seen = Set<String>()
        var perFeed: [String: Int] = [:]
        for feed in feeds {
            guard let url = URL(string: feed.url) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            req.setValue("jev-lab/0.1 rss reader", forHTTPHeaderField: "User-Agent")
            let result = try? await URLSession.shared.data(for: req)
            guard let data = result?.0, (result?.1 as? HTTPURLResponse)?.statusCode == 200 else {
                perFeed[feed.name] = -1
                continue
            }
            var n = 0
            for raw in RSSParser.parse(data) {
                let title = htmlUnescape(raw.title).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let pub = parseDate(raw.pubDate), !seen.contains(title.lowercased()), pub >= cutoff else { continue }
                seen.insert(title.lowercased())
                items.append(Headline(source: feed.name, headline: title, summary: cleanSummary(raw.description), published: pub))
                n += 1
            }
            perFeed[feed.name] = n
        }
        return (items.sorted { $0.published < $1.published }, perFeed)
    }

    /// Coin a směr obchodu podle Jev odpovědi: obchoduje se jen "Notable" a "Major".
    public static func judgeCall(_ ans: [String: JevAnswer]) -> (coin: String?, side: Int) {
        let asset = ans["asset"]?.choice
        let coin: String? = ["BTC": "BTC", "ETH": "ETH", "SOL": "SOL", "whole_crypto_market": "BTC"][asset ?? ""]
        var side = ["bullish": 1, "bearish": -1][ans["direction"]?.choice ?? ""] ?? 0
        if (ans["impact"]?.score ?? 0) < 2 { side = 0 }
        return (coin, side)
    }

    /// Cenové cesty kolem každé zprávy ze skutečných 1min svíček (minuty -10 … +60 od vstupu).
    public static func pricePaths(for items: [Headline], candles: [String: [Hyperliquid.Candle]],
                                  before: Int = 10, after: Int = 60) -> [Headline] {
        var maps: [String: [Int64: Hyperliquid.Candle]] = [:]
        for (c, list) in candles {
            var m: [Int64: Hyperliquid.Candle] = [:]
            for k in list { m[k.openMs] = k }
            maps[c] = m
        }
        return items.map { item in
            var it = item
            let pubMs = Int64(item.published.timeIntervalSince1970 * 1000)
            let entry = (pubMs / 60_000) * 60_000 + 60_000 // začátek minuty + 1 min
            for (c, m) in maps {
                guard let base = m[entry]?.open, base > 0 else { continue }
                var path: [PathPoint] = []
                for minute in -before...after {
                    if let k = m[entry + Int64(minute) * 60_000] {
                        path.append(PathPoint(minute: Double(minute), bps: rounded(1e4 * (k.close / base - 1), 2)))
                    }
                }
                it.paths[c] = path
            }
            return it
        }
    }

    // MARK: - Pomocné

    static let dateFormats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z",
                              "dd MMM yyyy HH:mm:ss Z"]

    public static func parseDate(_ s: String) -> Date? {
        let str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let d = f.date(from: str) { return d }
        }
        return ISO8601DateFormatter().date(from: str)
    }

    public static func cleanSummary(_ s: String) -> String {
        var t = htmlUnescape(s)
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
    }

    public static func htmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
                                       "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}"]
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                } else if name.hasPrefix("#") {
                    if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                } else {
                    rep = named[name]
                }
                if let r = rep {
                    out += r
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

/// Minimalistický RSS parser (title, pubDate, description z každého <item>).
final class RSSParser: NSObject, XMLParserDelegate {
    struct Item {
        var title = ""
        var pubDate = ""
        var description = ""
    }

    private var items: [Item] = []
    private var current: Item?
    private var field: String?

    static func parse(_ data: Data) -> [Item] {
        let p = RSSParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" {
            current = Item()
        } else if current != nil, ["title", "pubDate", "description"].contains(elementName) {
            field = elementName
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        append(String(data: CDATABlock, encoding: .utf8) ?? "")
    }

    private func append(_ s: String) {
        guard let f = field, current != nil else { return }
        switch f {
        case "title": current!.title += s
        case "pubDate": current!.pubDate += s
        case "description": current!.description += s
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item", let c = current {
            items.append(c)
            current = nil
            field = nil
        } else if elementName == field {
            field = nil
        }
    }
}
