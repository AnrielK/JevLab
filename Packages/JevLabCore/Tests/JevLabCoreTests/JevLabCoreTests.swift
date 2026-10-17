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

final class HorizonTests: XCTestCase {
    func makeCandles() -> [Hyperliquid.Candle] {
        var out: [Hyperliquid.Candle] = []
        for i in 0..<30 {
            let o: Double = 100 + 0.3 * Double(i) + Double(i % 4) * 0.2
            let c: Double = o + Double((i % 3) - 1) * 0.15
            let h: Double = max(o, c) + 0.1 + Double(i % 2) * 0.05
            let l: Double = min(o, c) - 0.1
            let v: Double = 10 + Double(i % 5) * 2
            out.append(Hyperliquid.Candle(openMs: Int64(i) * 3_600_000, open: o, close: c, high: h, low: l, volume: v))
        }
        return out
    }

    func testFeaturesMatchPythonReference() throws {
        let s = try XCTUnwrap(Features.state(candles: makeCandles(), at: 25, horizon: .h1))
        let expected: [String: Double] = [
            "bar_minutes": 60,
            "return_last_bar_bps": 60.72,
            "return_3_bars_bps": 65.42,
            "return_12_bars_bps": 345.82,
            "volatility_20_bars_bps": 39.85,
            "position_in_20_bar_range": 0.975,
            "volume_vs_20_bar_avg": 0.71,
            "close_vs_20_bar_mean_bps": 262.76,
            "last_bar_body_ratio": 0,
        ]
        XCTAssertEqual(Set(s.keys), Set(expected.keys))
        for (k, v) in expected { XCTAssertEqual(s[k] ?? .nan, v, accuracy: 0.011, k) }
        XCTAssertNil(Features.state(candles: makeCandles(), at: 5, horizon: .h1))
    }

    func testClosedCandlesDropFormingBar() {
        let c = makeCandles()
        let closed = Features.closed(c, horizon: .h1, nowMs: 29 * 3_600_000 + 1_000)
        XCTAssertEqual(closed.count, 29)
    }

    func testInstrumentsAndFees() {
        let nvda = Instrument.find("xyz:NVDA")
        XCTAssertTrue(nvda.isStock)
        XCTAssertEqual(nvda.label, "NVDA")
        XCTAssertEqual(nvda.takerFee, Hyperliquid.takerFee * 2, accuracy: 1e-12)
        XCTAssertEqual(Instrument.find("BTC").takerFee, Hyperliquid.takerFee, accuracy: 1e-12)
        XCTAssertEqual(Hyperliquid.dex(of: "xyz:TSLA"), "xyz")
        XCTAssertNil(Hyperliquid.dex(of: "ETH"))
        // čtvrtek 15. 10. 2026 16:00 UTC = 12:00 New York → otevřeno; neděle zavřeno
        XCTAssertTrue(USMarketHours.isOpen(at: Date(timeIntervalSince1970: 1_792_080_000)))
        XCTAssertFalse(USMarketHours.isOpen(at: Date(timeIntervalSince1970: 1_792_080_000 + 3 * 86_400)))
    }
}

final class AnalysisTests: XCTestCase {
    let records: [CallRecord] = [
        CallRecord(id: 0, t: 1, side: .buy, conf: 0.9, price: 100, retNextBps: 10),
        CallRecord(id: 1, t: 2, side: .buy, conf: 0.95, price: 100, retNextBps: -5),
        CallRecord(id: 2, t: 3, side: .sell, conf: 0.7, price: 100, retNextBps: -20),
        CallRecord(id: 3, t: 4, side: .sell, conf: 0.9, price: 100, retNextBps: -8),
    ]

    func testSimulateWithFees() {
        let hi = Analysis.simulate(records, minConf: 0.8, feeRate: 0.0005)
        XCTAssertEqual(hi.grossBps, 13, accuracy: 1e-9)
        XCTAssertEqual(hi.feesBps, 15, accuracy: 1e-9)
        XCTAssertEqual(hi.netBps, -2, accuracy: 1e-9)
        XCTAssertEqual(hi.trades, 3)
        XCTAssertEqual(hi.exposed, 3)
        XCTAssertEqual(hi.hits, 2)

        let lo = Analysis.simulate(records, minConf: 0.6, feeRate: 0.0005)
        XCTAssertEqual(lo.grossBps, 33, accuracy: 1e-9)
        XCTAssertEqual(lo.feesBps, 15, accuracy: 1e-9)
        XCTAssertEqual(lo.netBps, 18, accuracy: 1e-9)
        XCTAssertEqual(lo.trades, 2)
        XCTAssertEqual(lo.equity.last?.netUsd ?? 0, 1.8, accuracy: 1e-9)
    }

    func testCalibrationAndBuyHold() {
        let cal = Analysis.calibration(records)
        let top = cal.first { $0.lower == 0.9 }
        XCTAssertEqual(top?.count, 3)
        XCTAssertEqual(top?.hits, 2)
        XCTAssertEqual(top?.avgSignedBps ?? 0, 13.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(cal.first { $0.lower == 0.7 }?.avgSignedBps ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(Analysis.buyHoldBps(records), -23.002978008, accuracy: 1e-6)
    }

    func testWalkForwardNeedsEnoughData() {
        XCTAssertNil(Analysis.walkForward(records, feeRate: 0.0005, defaultThreshold: 0.6))
        var many: [CallRecord] = []
        for i in 0..<40 {
            many.append(CallRecord(id: i, t: Double(i), side: i % 2 == 0 ? .buy : .sell, conf: 0.55 + Double(i % 9) * 0.05,
                                   price: 100, retNextBps: i % 2 == 0 ? 12 : -12))
        }
        let wf = Analysis.walkForward(many, feeRate: 0.0005, defaultThreshold: 0.6)
        XCTAssertEqual(wf?.trainCount, 20)
        XCTAssertEqual(wf?.testCount, 20)
        XCTAssertNotNil(wf?.chosen)
    }

    func testTickOutcomes() {
        let raw = [
            CallRecord(id: 0, t: 1, side: .buy, conf: 0.9, price: 100),
            CallRecord(id: 1, t: 2, side: .buy, conf: 0.9, price: 100),
            CallRecord(id: 2, t: 3, side: .sell, conf: 0.9, price: 100.1),
        ]
        let out = Analysis.fillTickOutcomes(raw)
        XCTAssertEqual(out[0].retNextBps ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(out[1].retNextBps ?? 0, 10, accuracy: 1e-6)
        XCTAssertNil(out[2].retNextBps)
    }

    func testStoreRoundTripAndCSV() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RunStore(directory: dir)
        let summary = RunSummary(kind: .backtest, started: Date(timeIntervalSince1970: 100), ended: Date(timeIntervalSince1970: 200),
                                 coin: "BTC", horizon: .h1, strategy: "test", minConf: 0.6, feeRate: 0.00045,
                                 calls: 4, trades: 2, grossUsd: 3.3, feesUsd: 1.5, netUsd: 1.8, hitRate: 0.75,
                                 buyHoldBps: -23, note: nil)
        try store.save(RunDetail(summary: summary, records: records))
        XCTAssertEqual(store.summaries().count, 1)
        let back = try XCTUnwrap(store.detail(summary.id))
        XCTAssertEqual(back.records, records)
        XCTAssertEqual(back.summary.horizon, .h1)
        let csv = RunStore.csv(back)
        XCTAssertTrue(csv.hasPrefix("time,side,conf,price,ret_next_bps,action,claude_bias"))
        XCTAssertEqual(csv.split(separator: "\n").count, 5)
        store.delete(summary.id)
        XCTAssertTrue(store.summaries().isEmpty)
    }
}

final class ContextTests: XCTestCase {
    let day: Int64 = 86_400_000

    func weekly() -> [Hyperliquid.Candle] {
        let opens: [Double] = [100, 100, 105, 110]
        let closes: [Double] = [100, 105, 110, 120]
        return (0..<4).map { k in
            Hyperliquid.Candle(openMs: Int64(k) * 7 * day, open: opens[k], close: closes[k],
                               high: closes[k] + 1, low: opens[k] - 1, volume: 1)
        }
    }

    func testWeeklyContextUsesOnlyClosedBars() {
        let f = Features.context(.w1, candles: weekly(), tMs: 22 * day, price: 115)
        XCTAssertEqual(f["weekly_return_last_bar_bps"] ?? .nan, 476.19, accuracy: 0.011)
        XCTAssertNil(f["weekly_return_3_bars_bps"])
        XCTAssertNil(f["weekly_price_vs_3_bar_mean_bps"], "proměnlivé názvy featur se nepoužívají")
        XCTAssertEqual(f["weekly_position_in_range"] ?? .nan, 1.0, accuracy: 1e-9)
        XCTAssertEqual(f["weekly_volatility_bps"] ?? .nan, 11.9, accuracy: 0.011)
        XCTAssertEqual(f["weekly_current_bar_so_far_bps"] ?? .nan, 454.55, accuracy: 0.011)
        // poslední týden (close 120) se ještě tvoří: jeho zavírací cena se nesmí nikde projevit
        let later = Features.context(.w1, candles: weekly(), tMs: 28 * day, price: 120)
        XCTAssertEqual(later["weekly_return_last_bar_bps"] ?? .nan, 1e4 * (120.0 / 110 - 1), accuracy: 0.011)
        XCTAssertTrue(Features.context(.w1, candles: weekly(), tMs: 8 * day, price: 101).isEmpty)
    }

    func testMonthCloseUsesCalendar() {
        XCTAssertEqual(Timeframe.mo1.closeMs(openMs: 1_767_225_600_000), 1_769_904_000_000)
        XCTAssertEqual(Timeframe.d1.closeMs(openMs: 0), day)
    }

    func testDailyHorizonWithContext() throws {
        var daily: [Hyperliquid.Candle] = []
        for i in 0..<40 {
            let o: Double = 100 + Double(i)
            daily.append(Hyperliquid.Candle(openMs: Int64(i) * day, open: o, close: o + 0.5, high: o + 1, low: o - 1, volume: 5))
        }
        let s = try XCTUnwrap(Features.state(candles: daily, at: 30, horizon: .d1, context: [.w1: weekly()]))
        XCTAssertEqual(s["bar_minutes"], 1440)
        XCTAssertNotNil(s["weekly_return_last_bar_bps"])
        XCTAssertEqual(Horizon.d1.context, [.h4, .w1, .mo1])
        XCTAssertTrue(Horizon.d1.question["side"]?.instructions.contains("1-day") ?? false)
        XCTAssertLessThanOrEqual(Horizon.d1.maxDaysWithContext, Horizon.d1.maxDays)
    }
}

final class ClaudeModeTests: XCTestCase {
    func testSimulationModes() {
        let recs: [CallRecord] = [
            CallRecord(id: 0, t: 1, side: .buy, conf: 0.9, price: 100, retNextBps: 10, bias: .long),
            CallRecord(id: 1, t: 2, side: .sell, conf: 0.9, price: 100, retNextBps: -10, bias: .long),
            CallRecord(id: 2, t: 3, side: .sell, conf: 0.9, price: 100, retNextBps: -10, bias: .short),
            CallRecord(id: 3, t: 4, side: .buy, conf: 0.9, price: 100, retNextBps: 5, bias: .flat),
        ]
        // Jev sám: +10, +10, +10, +5 = 35 bps; změny: 0→1, 1→-1, -1→1 = 3 změny, 5 stran
        let jev = Analysis.simulate(recs, minConf: 0.6, feeRate: 0.0001, mode: .jev)
        XCTAssertEqual(jev.grossBps, 35, accuracy: 1e-9)
        XCTAssertEqual(jev.feesBps, 5, accuracy: 1e-9)
        // Jev + Claude: long +10, (proti biasu) flat 0, short +10, flat 0 = 20 bps; strany 1+1+1+1 = 4
        let both = Analysis.simulate(recs, minConf: 0.6, feeRate: 0.0001, mode: .jevClaude)
        XCTAssertEqual(both.grossBps, 20, accuracy: 1e-9)
        XCTAssertEqual(both.feesBps, 4, accuracy: 1e-9)
        // Claude sám: long +10, long -10, short +10, flat 0 = 10 bps; strany 1+2+1 = 4
        let claude = Analysis.simulate(recs, minConf: 0.6, feeRate: 0.0001, mode: .claude)
        XCTAssertEqual(claude.grossBps, 10, accuracy: 1e-9)
        XCTAssertEqual(claude.feesBps, 4, accuracy: 1e-9)
        XCTAssertTrue(Analysis.hasBias(recs))
    }

    func testHorizonPromptHasNoPrices() {
        let p = BrainLogic.horizonPrompt(state: ["return_last_bar_bps": 12.5, "weekly_position_in_range": 0.4], horizon: .d1, everyBars: 1)
        XCTAssertTrue(p.contains("1 day(s)"))
        XCTAssertTrue(p.contains("weekly_position_in_range"))
        var cfg = HorizonConfig()
        cfg.horizon = .d1
        cfg.days = 30
        cfg.claude = true
        XCTAssertEqual(cfg.claudeEvery, 1)
        XCTAssertEqual(cfg.claudeCalls, cfg.backtestBars)
    }
}

final class IndicatorTests: XCTestCase {
    /// Stejné svíčky jako v Python referenci: trojúhelníková vlna (perioda 20) + drift.
    func series() -> [Hyperliquid.Candle] {
        func tri(_ i: Int) -> Double {
            let x = Double(i % 20)
            return x < 10 ? 10.0 * (x / 10.0) : 10.0 * ((20.0 - x) / 10.0)
        }
        var out: [Hyperliquid.Candle] = []
        var prev = 100.0
        for i in 0..<80 {
            let c: Double = 100 + tri(i) + 0.1 * Double(i)
            out.append(Hyperliquid.Candle(openMs: Int64(i) * 86_400_000, open: prev, close: c,
                                          high: max(prev, c) + 0.5, low: min(prev, c) - 0.5, volume: 1))
            prev = c
        }
        return out
    }

    func testIndicatorsMatchPythonReference() throws {
        let c = series()
        let price = c[75].close
        XCTAssertEqual(price, 112.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Indicators.sma(c, end: 75, n: 20)), 111.55, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Indicators.rsi(c, end: 75)), 52.5, accuracy: 0.051)
        let f = Indicators.features(c, end: 75, price: price, prefix: "", pivotK: 3, lookback: 120, maPeriods: [20, 50, 200])
        let expected: [String: Double] = [
            "ma20_dist_bps": 85.2, "ma50_dist_bps": 176.4, "ma20_slope_5bars_bps": 45.0,
            "rsi14": 52.5, "atr14_bps": 177.3,
            "dist_from_50bar_high_bps": -425.5, "dist_from_50bar_low_bps": 869.6,
            "support_dist_bps": 89.7, "support_dist_atr": 0.5, "support_touches": 1,
            "resistance_dist_bps": 88.9, "resistance_dist_atr": 0.5, "resistance_touches": 1,
        ]
        for (k, v) in expected { XCTAssertEqual(f[k] ?? .nan, v, accuracy: 0.051, k) }
        XCTAssertNil(f["ma200_dist_bps"], "MA200 nemá dost historie")
    }

    func testLevelClusteringAndNearest() {
        let lv = Indicators.levels(from: [105.3, 100, 110, 100.4, 105, 105.2], tolerance: 0.5)
        XCTAssertEqual(lv.count, 3)
        XCTAssertEqual(lv[0].touches, 2)
        XCTAssertEqual(lv[0].price, 100.2, accuracy: 1e-9)
        XCTAssertEqual(lv[1].touches, 3)
        XCTAssertEqual(lv[1].price, (105 + 105.2 + 105.3) / 3, accuracy: 1e-9)
        let near = Indicators.nearest(lv, price: 106)
        XCTAssertEqual(near.support?.touches, 3)
        XCTAssertEqual(near.resistance?.price ?? 0, 110, accuracy: 1e-9)
    }

    func testPivotsNeverUseFutureBars() {
        let c = series()
        // swing high na svíčce 10 (vrchol vlny) se smí objevit až když existují 3 svíčky za ní
        XCTAssertFalse(Indicators.pivots(c, end: 12, k: 3, lookback: 50).contains(c[10].high))
        XCTAssertTrue(Indicators.pivots(c, end: 13, k: 3, lookback: 50).contains(c[10].high))
    }
}

final class RulesAndModelTests: XCTestCase {
    func testSetupsAndRuleTargets() {
        let bounce: [String: Double] = ["support_dist_atr": 0.4, "rsi14": 32]
        XCTAssertEqual(Setups.supportBounce(bounce), 1)
        XCTAssertEqual(Setups.supportBounce(["resistance_dist_atr": 0.8, "rsi14": 65]), -1)
        XCTAssertEqual(Setups.supportBounce(["support_dist_atr": 2.0, "rsi14": 32]), 0)
        XCTAssertEqual(Setups.flags(bounce)["setup_support_bounce"], 1)
        XCTAssertNil(Setups.flags(bounce)["setup_weekly_pullback"])

        // signál long, pak 2 svíčky bez signálu → při hold 2 se po druhé zavře
        let recs = (0..<5).map { i in
            CallRecord(id: i, t: Double(i), side: nil, conf: nil, price: 100, retNextBps: 10,
                       state: i == 0 ? bounce : ["support_dist_atr": 3, "rsi14": 50])
        }
        let rule = RuleStrategy.all.first { $0.id == "bounce" }!
        XCTAssertEqual(Analysis.ruleTargets(recs, rule: rule, hold: 2), [1, 1, 0, 0, 0])
        let r = Analysis.simulate(recs, targets: [1, 1, 0, 0, 0], feeRate: 0.0001)
        XCTAssertEqual(r.grossBps, 20, accuracy: 1e-9)
        XCTAssertEqual(r.feesBps, 2, accuracy: 1e-9)
    }

    func testModelLearnsObviousSignal() throws {
        // featura "x" přesně určuje směr zítřka, "noise" je šum
        var recs: [CallRecord] = []
        for i in 0..<200 {
            let up = (i * 7) % 3 != 0
            let noise = Double((i * 13) % 17) - 8
            recs.append(CallRecord(id: i, t: Double(i), side: .buy, conf: 0.6, price: 100,
                                   retNextBps: up ? 20 : -20, state: ["x": up ? 1 : -1, "noise": noise]))
        }
        let rep = try XCTUnwrap(FeatureModel.walkForward(recs, feeRate: 0.0001))
        XCTAssertEqual(rep.trainCount, 100)
        XCTAssertGreaterThan(rep.testAccuracy, 0.95)
        XCTAssertEqual(rep.topWeights.first?.feature, "x")
        XCTAssertGreaterThan(rep.test.netBps, 0)
    }
}

final class FatalErrorTests: XCTestCase {
    func testFatalDetection() {
        XCTAssertTrue(JevError(status: 402, message: "Team budget exceeded").isFatal)
        XCTAssertFalse(JevError(status: 429, message: "slow down").isFatal)
        XCTAssertTrue(JevError.isFatal(JevError(status: 402, message: "x").localizedDescription))
        XCTAssertFalse(JevError.isFatal("The request timed out."))
        XCTAssertFalse(JevError.isFatal(nil))
    }
}
