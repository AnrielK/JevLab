import Foundation

/// Výsledek jednoduchého modelu natrénovaného na featurách.
public struct ModelReport: Sendable {
    public struct Weight: Identifiable, Sendable {
        public var feature: String
        public var weight: Double
        public var id: String { feature }
    }

    public var trainCount: Int
    public var testCount: Int
    public var features: Int
    /// Úspěšnost odhadu směru (je zítra nahoru?) na tréninku a na nových datech.
    public var trainAccuracy: Double
    public var testAccuracy: Double
    /// Jak často šla cena v testovací části nahoru (základ, který musí model porazit).
    public var testBaseRate: Double
    public var test: SimResult
    public var topWeights: [Weight]
}

/// Logistická regrese s L2 regularizací: odhaduje pravděpodobnost, že další svíčka skončí výš.
/// Trénuje se na první polovině, testuje na druhé. Deterministická, bez dalších volání.
public enum FeatureModel {
    public static func walkForward(_ records: [CallRecord], feeRate: Double, threshold: Double = 0.05,
                                   lambda: Double = 5, iterations: Int = 400, rate: Double = 0.1) -> ModelReport? {
        let done = records.filter { $0.retNextBps != nil && $0.state != nil }
        guard done.count >= 40 else { return nil }
        let half = done.count / 2
        let train = Array(done[..<half])
        let test = Array(done[half...])

        // featury přítomné aspoň v 80 % tréninkových záznamů a nekonstantní
        var counts: [String: Int] = [:]
        for r in train { for k in (r.state ?? [:]).keys { counts[k, default: 0] += 1 } }
        var keys: [String] = []
        var mean: [Double] = []
        var std: [Double] = []
        for (k, n) in counts.sorted(by: { $0.key < $1.key }) where Double(n) >= 0.8 * Double(train.count) {
            let vals = train.compactMap { $0.state?[k] }
            let m = vals.reduce(0, +) / Double(vals.count)
            let v = vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count)
            if v > 1e-12 {
                keys.append(k)
                mean.append(m)
                std.append(v.squareRoot())
            }
        }
        guard !keys.isEmpty else { return nil }

        func row(_ r: CallRecord) -> [Double] {
            keys.indices.map { j in
                guard let x = r.state?[keys[j]] else { return 0 }
                return max(-5, min(5, (x - mean[j]) / std[j]))
            }
        }
        let xTrain = train.map(row)
        let yTrain = train.map { ($0.retNextBps ?? 0) > 0 ? 1.0 : 0.0 }
        let d = keys.count
        var w = [Double](repeating: 0, count: d)
        var b = 0.0
        let n = Double(xTrain.count)

        func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-max(-30, min(30, z)))) }
        func predict(_ x: [Double]) -> Double {
            var z = b
            for j in 0..<d { z += w[j] * x[j] }
            return sigmoid(z)
        }

        for _ in 0..<iterations {
            var gw = [Double](repeating: 0, count: d)
            var gb = 0.0
            for (x, y) in zip(xTrain, yTrain) {
                let e = predict(x) - y
                for j in 0..<d { gw[j] += e * x[j] }
                gb += e
            }
            for j in 0..<d { w[j] -= rate * (gw[j] / n + lambda / n * w[j]) }
            b -= rate * gb / n
        }

        func accuracy(_ xs: [[Double]], _ recs: [CallRecord]) -> Double {
            var ok = 0
            for (x, r) in zip(xs, recs) where ((predict(x) > 0.5) == ((r.retNextBps ?? 0) > 0)) { ok += 1 }
            return Double(ok) / Double(max(1, recs.count))
        }
        let xTest = test.map(row)
        let targets: [Double] = xTest.map { x in
            let p = predict(x)
            return p > 0.5 + threshold ? 1 : (p < 0.5 - threshold ? -1 : 0)
        }
        let weights = keys.indices
            .map { ModelReport.Weight(feature: keys[$0], weight: w[$0]) }
            .sorted { abs($0.weight) > abs($1.weight) }
        let ups = test.filter { ($0.retNextBps ?? 0) > 0 }.count
        return ModelReport(trainCount: train.count, testCount: test.count, features: d,
                           trainAccuracy: accuracy(xTrain, train), testAccuracy: accuracy(xTest, test),
                           testBaseRate: Double(ups) / Double(test.count),
                           test: Analysis.simulate(test, targets: targets, feeRate: feeRate),
                           topWeights: Array(weights.prefix(8)))
    }
}
