import XCTest
@testable import JevLabCore

/// Referenční hodnoty pocházejí z původního Python kódu jev-starteru (stejné vstupy).
final class MarketBookTests: XCTestCase {
    func makeBook() -> MarketBook {
        var book = MarketBook()
        for i in 0..<61 {
            let bid = 10.0 + 0.001 * Double((i * 7) % 13)
            book.apply(quote: Quote(bid: bid, ask: bid + 0.002, bidSize: 1 + Double(i % 5), askSize: 2 + Double(i % 3), t: 940 + Double(i)))
        }
        let trades = (0..<40).map { i in
            MarketTrade(t: 960.5 + Double(i), isBuy: i % 3 != 0, px: 10.005, sz: 1 + Double(i % 4))
        }
        book.apply(trades: trades, now: 1000.5)
        let bids: [(Double, Double)] = [(10.0, 100), (9.99, 50), (9.98, 20), (9.97, 10), (9.96, 5)]
        let asks: [(Double, Double)] = [(10.01, 80), (10.02, 60), (10.03, 30), (10.04, 10), (10.05, 1)]
        book.apply(depthBidUSD: bids.reduce(0) { $0 + $1.0 * $1.1 }, depthAskUSD: asks.reduce(0) { $0 + $1.0 * $1.1 })
        return book
    }

    func testSnapshotMatchesPythonReference() throws {
        let snap = try XCTUnwrap(makeBook().snapshot(now: 1000.5))
        let expected: [String: Double] = [
            "spread_bps": 1.999,
            "microprice_vs_mid_bps": -0.333,
            "top_of_book_imbalance": -0.333,
            "aggressor_buy_share_5s": 0.643,
            "aggressor_buy_share_30s": 0.675,
            "trades_last_5s": 5,
            "return_5s_bps": 2.0,
            "return_30s_bps": -5.0,
            "tick_volatility_60s_bps": 6.472,
            "depth5_imbalance": 0.01,
        ]
        XCTAssertEqual(Set(snap.state.keys), Set(expected.keys))
        for (k, v) in expected {
            XCTAssertEqual(snap.state[k] ?? .nan, v, accuracy: 0.0011, k)
        }
        XCTAssertEqual(snap.mid, 10.005, accuracy: 1e-9)
        XCTAssertEqual(snap.micro, 10.004666666666667, accuracy: 1e-9)
    }

    func testEmptyBookHasNoSnapshot() {
        XCTAssertNil(MarketBook().snapshot(now: 1))
    }

    func testTicksAreThinnedAndPruned() {
        var book = MarketBook()
        book.apply(quote: Quote(bid: 1, ask: 1.1, bidSize: 1, askSize: 1, t: 0))
        book.apply(quote: Quote(bid: 1, ask: 1.1, bidSize: 1, askSize: 1, t: 0.01)) // pod 50 ms → bez nového ticku
        XCTAssertEqual(book.ticks.count, 1)
        XCTAssertEqual(book.mids.count, 2)
        book.apply(quote: Quote(bid: 1, ask: 1.1, bidSize: 1, askSize: 1, t: 500))
        XCTAssertEqual(book.mids.count, 1)
        XCTAssertEqual(book.ticks.count, 1)
    }
}

final class PaperBookTests: XCTestCase {
    func testFillsAndFees() {
        var pb = PaperBook(notional: 1000)
        pb.fill(target: 1, px: 10.0, feeRate: 0.00015)
        pb.fill(target: -1, px: 10.5, feeRate: 0.00015)
        pb.fill(target: 0, px: 10.2, feeRate: 0.00045)
        XCTAssertEqual(pb.qty, 0, accuracy: 1e-9)
        XCTAssertEqual(pb.cash, 78.57142857142856, accuracy: 1e-9)
        XCTAssertEqual(pb.fees, 0.8946428571428571, accuracy: 1e-9)
        XCTAssertEqual(pb.trades, 3)
        XCTAssertEqual(pb.gross(mid: 10.3), 78.57142857142856, accuracy: 1e-9)
        XCTAssertEqual(pb.pos, 0)
    }
}

final class JevNormaliserTests: XCTestCase {
    let questions: [String: JevQuestion] = [
        "side": .choice("?", ["buy", "sell"]),
        "impact": .score("?", ["Noise", "Minor", "Notable", "Major"]),
        "yes": .noul("?"),
    ]

    func testFixtureAnswer() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "jev_answer", withExtension: "json", subdirectory: "Fixtures"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let raw = try XCTUnwrap(json["answers"] as? [String: Any])
        let a = try JevNormaliser.normalise(questions: questions, raw: raw)

        XCTAssertEqual(a["side"]?.choice, "sell")
        XCTAssertEqual(a["side"]?.choiceProbs["buy"] ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(a["side"]?.choiceProbs["sell"] ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(a["impact"]?.score ?? 0, 1.69, accuracy: 1e-9)
        let expected = [0.08333333333333334, 0.16666666666666669, 0.5, 0.25]
        for (x, y) in zip(a["impact"]?.scoreProbs ?? [], expected) { XCTAssertEqual(x, y, accuracy: 1e-9) }
        XCTAssertEqual(a["yes"], .noul(p: 1.0))
    }

    func testFallbacks() throws {
        let raw: [String: Any] = [
            "side": ["probabilities": [3, 1]],
            "impact": ["score": "Notable"],
            "yes": 0.25,
        ]
        let a = try JevNormaliser.normalise(questions: questions, raw: raw)
        XCTAssertEqual(a["side"]?.choice, "buy")
        XCTAssertEqual(a["side"]?.choiceProbs["buy"] ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(a["impact"]?.score, 2.0)
        XCTAssertEqual(a["impact"]?.scoreProbs, [0, 0, 1, 0])
        XCTAssertEqual(a["yes"], .noul(p: 0.25))
    }

    func testMissingAnswerThrows() {
        XCTAssertThrowsError(try JevNormaliser.normalise(questions: questions, raw: [:]))
    }
}

final class StrategyTests: XCTestCase {
    func testConviction() {
        let s = ConvictionStrategy(minConf: 0.85, minHold: 15)
        XCTAssertEqual(s.decide(call: JevCall(side: .buy, conf: 0.8), market: [:], position: 0, secondsSinceTrade: 100), .hold("low conviction"))
        XCTAssertEqual(s.decide(call: JevCall(side: .buy, conf: 0.9), market: [:], position: 1, secondsSinceTrade: 100), .hold("already long"))
        XCTAssertEqual(s.decide(call: JevCall(side: .sell, conf: 0.9), market: [:], position: 1, secondsSinceTrade: 5), .hold("too soon to flip"))
        XCTAssertEqual(s.decide(call: JevCall(side: .sell, conf: 0.9), market: [:], position: 1, secondsSinceTrade: 20), .sell)
    }

    func testTrend() {
        let s = TrendStrategy()
        let up = ["return_30s_bps": 3.0, "aggressor_buy_share_30s": 0.7]
        XCTAssertEqual(s.decide(call: JevCall(side: .buy, conf: 0.9), market: up, position: 0, secondsSinceTrade: 0), .buy)
        XCTAssertEqual(s.decide(call: JevCall(side: .sell, conf: 0.9), market: up, position: 0, secondsSinceTrade: 0), .hold("against the trend"))
        XCTAssertEqual(s.decide(call: JevCall(side: .buy, conf: 0.5), market: up, position: 0, secondsSinceTrade: 0), .hold("low conviction"))
    }
}

final class NewsTests: XCTestCase {
    func testRSSParsing() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "feed", withExtension: "rss", subdirectory: "Fixtures"))
        let items = RSSParser.parse(try Data(contentsOf: url))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(News.htmlUnescape(items[0].title), "Bitcoin tops & holds $100K")
        XCTAssertEqual(News.cleanSummary(items[0].description), "BTC rallied after the news.")
        XCTAssertEqual(News.htmlUnescape(items[1].title), "ETH upgrade \u{2019}goes live\u{2019}")
        XCTAssertNotNil(News.parseDate(items[0].pubDate))
        XCTAssertNotNil(News.parseDate(items[1].pubDate))
        XCTAssertEqual(News.parseDate("Thu, 15 Oct 2026 09:30:00 +0000")?.timeIntervalSince1970, 1_792_056_600)
    }

    func testJudgeCall() {
        let a: [String: JevAnswer] = [
            "asset": .choice("whole_crypto_market", probs: [:]),
            "direction": .choice("bearish", probs: [:]),
            "impact": .score(2.4, probs: []),
        ]
        let r = News.judgeCall(a)
        XCTAssertEqual(r.coin, "BTC")
        XCTAssertEqual(r.side, -1)
        var small = a
        small["impact"] = .score(1.2, probs: [])
        XCTAssertEqual(News.judgeCall(small).side, 0)
        var none = a
        none["asset"] = .choice("none", probs: [:])
        XCTAssertNil(News.judgeCall(none).coin)
    }

    func testPricePaths() {
        // zpráva 09:30:20 → vstup 09:31:00
        var h = Headline(source: "t", headline: "x", summary: "", published: Date(timeIntervalSince1970: 1_792_056_620))
        h.paths = [:]
        let entry: Int64 = 1_792_056_660_000
        let candles = (-10...60).map { m in
            Hyperliquid.Candle(openMs: entry + Int64(m) * 60_000, open: 100 + Double(m) * 0.01, close: 100 + Double(m) * 0.01 + 0.005)
        }
        let out = News.pricePaths(for: [h], candles: ["BTC": candles])
        let path = out[0].paths["BTC"] ?? []
        XCTAssertEqual(path.count, 71)
        XCTAssertEqual(path.first?.minute, -10)
        XCTAssertEqual(path.first(where: { $0.minute == 60 })?.bps ?? 0, 60.5, accuracy: 0.01)
    }
}

final class FeedParseTests: XCTestCase {
    func testBBOAndTrades() {
        let bbo = #"{"channel":"bbo","data":{"coin":"HYPE","time":1,"bbo":[{"px":"40.1","sz":"12","n":3},{"px":"40.2","sz":"4","n":1}]}}"#
        guard case .quote(let q)? = HyperliquidFeed.parse(Data(bbo.utf8), now: 5)?.first else { return XCTFail("bbo") }
        XCTAssertEqual(q.bid, 40.1)
        XCTAssertEqual(q.askSize, 4)
        XCTAssertEqual(q.micro, (40.1 * 4 + 40.2 * 12) / 16, accuracy: 1e-12)

        let tr = #"{"channel":"trades","data":[{"coin":"HYPE","side":"B","px":"40.15","sz":"2","time":1700000000123}]}"#
        guard case .trades(let list, _)? = HyperliquidFeed.parse(Data(tr.utf8), now: 5)?.first else { return XCTFail("trades") }
        XCTAssertEqual(list.first?.isBuy, true)
        XCTAssertEqual(list.first?.t ?? 0, 1_700_000_000.123, accuracy: 1e-6)

        XCTAssertNil(HyperliquidFeed.parse(Data(#"{"channel":"bbo","data":{"bbo":[null,{"px":"1","sz":"1"}]}}"#.utf8), now: 0))
    }
}

final class BrainTests: XCTestCase {
    func testSummaryMatchesPythonReference() throws {
        let closes: [Double] = (0..<49).map { (i: Int) -> Double in
            let base: Double = 100 + 0.1 * Double(i)
            return base + Double(i % 3) * 0.05
        }
        let s = try XCTUnwrap(BrainLogic.summary(coin: "BTC", closes: closes, change24hPct: 1.5, fundingRatePct: 0.001))
        XCTAssertEqual(s.price, 104.8, accuracy: 1e-9)
        XCTAssertEqual(s.change15mPct, 0.29, accuracy: 1e-9)
        XCTAssertEqual(s.change1hPct, 1.16, accuracy: 1e-9)
        XCTAssertEqual(s.change4hPct, 4.8, accuracy: 1e-9)
        XCTAssertEqual(s.avg5mMovePct, 0.098, accuracy: 0.0011)
        XCTAssertEqual(s.high4h, 104.8, accuracy: 1e-9)
        XCTAssertEqual(s.low4h, 100, accuracy: 1e-9)
        XCTAssertNil(BrainLogic.summary(coin: "BTC", closes: [1, 2, 3], change24hPct: nil, fundingRatePct: nil))
    }

    func testParseReply() throws {
        let r = try XCTUnwrap(BrainLogic.parseReply("Sure:\n```json\n{\"bias\": \"Long\", \"confidence\": 1.4, \"reason\": \"Momentum roste.\"}\n```"))
        XCTAssertEqual(r.bias, .long)
        XCTAssertEqual(r.confidence, 1)
        XCTAssertEqual(r.reason, "Momentum roste.")
        XCTAssertEqual(BrainLogic.parseReply("{\"bias\": \"sideways\"}")?.bias, .flat)
        XCTAssertNil(BrainLogic.parseReply("no json here"))
    }

    func testGate() {
        XCTAssertEqual(BrainLogic.gate(bias: nil, want: 1, position: 0), .hold("waiting for Claude"))
        XCTAssertEqual(BrainLogic.gate(bias: .flat, want: 1, position: 0), .hold("Claude says stay out"))
        XCTAssertEqual(BrainLogic.gate(bias: .flat, want: 1, position: 1), .flat)
        XCTAssertEqual(BrainLogic.gate(bias: .long, want: 1, position: -1), .flat)
        XCTAssertEqual(BrainLogic.gate(bias: .long, want: -1, position: 0), .hold("against Claude's long bias"))
        XCTAssertNil(BrainLogic.gate(bias: .long, want: 1, position: 0))
        XCTAssertEqual(BrainLogic.gate(bias: .short, want: 1, position: 0), .hold("against Claude's short bias"))
        XCTAssertNil(BrainLogic.gate(bias: .short, want: -1, position: 0))
    }
}
