import Foundation

/// Obchodovatelný trh na Hyperliquid: nativní krypto perp, nebo akciový HIP-3 perp ("xyz:NVDA").
public struct Instrument: Identifiable, Hashable, Sendable, Codable {
    /// Název v API Hyperliquid ("BTC", "xyz:NVDA").
    public var coin: String
    /// Krátký popisek do UI ("BTC", "NVDA").
    public var label: String
    public var isStock: Bool

    public var id: String { coin }

    public init(coin: String, label: String? = nil, isStock: Bool? = nil) {
        self.coin = coin
        self.label = label ?? coin.split(separator: ":").last.map(String.init) ?? coin
        self.isStock = isStock ?? (Hyperliquid.dex(of: coin) != nil)
    }

    /// HIP-3 trhy mají dvojnásobné poplatky (polovina jde nasazovateli trhu).
    public var feeMultiplier: Double { Hyperliquid.dex(of: coin) != nil ? 2 : 1 }
    public var makerFee: Double { Hyperliquid.makerFee * feeMultiplier }
    public var takerFee: Double { Hyperliquid.takerFee * feeMultiplier }

    public static let crypto: [Instrument] = ["HYPE", "BTC", "ETH", "SOL"].map { Instrument(coin: $0) }
    public static let stocks: [Instrument] = ["NVDA", "TSLA", "AAPL", "MSFT", "GOOGL", "AMZN"].map {
        Instrument(coin: "xyz:\($0)", label: $0, isStock: true)
    }
    public static let all: [Instrument] = crypto + stocks

    /// Akciové trhy z API (dex "xyz" = TradeXYZ). Vrací tickery, které opravdu existují.
    public static func loadStocks(dex: String = "xyz") async throws -> [Instrument] {
        let names = try await Hyperliquid.perpNames(dex: dex)
        return names.sorted().map { Instrument(coin: $0, isStock: true) }
    }

    public static func find(_ coin: String) -> Instrument {
        all.first { $0.coin == coin } ?? Instrument(coin: coin)
    }
}

/// Obchodní hodiny burzy v USA (NYSE/Nasdaq, běžná seance 9:30–16:00 New York, po–pá).
/// Svátky se nezohledňují. Akciové perpy na Hyperliquid běží 24/7, mimo seanci ale cena
/// nesleduje živou burzu a po otevření bývají skoky.
public enum USMarketHours {
    public static func isOpen(at date: Date = Date()) -> Bool {
        guard let tz = TimeZone(identifier: "America/New_York") else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute else { return false }
        let minutes = h * 60 + m
        return minutes >= 9 * 60 + 30 && minutes < 16 * 60
    }
}
