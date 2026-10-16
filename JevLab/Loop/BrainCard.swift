import SwiftUI
import JevLabCore

/// Claudův bias: směr, jistota, zdůvodnění a souhrn trhu, ze kterého vycházel.
struct BrainCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let brain = model.loop.brain {
            content(brain)
        }
    }

    private func content(_ brain: ClaudeBrain) -> some View {
        let s = brain.state
        return Card("Claude mozek · každých \(Int(brain.everyMinutes)) min") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(biasLabel(s.bias))
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(biasColor(s.bias))
                if let c = s.confidence {
                    Text(F.pct(c)).font(.system(size: 22, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    brain.thinkNow()
                } label: {
                    if brain.thinking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Přečíst teď", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(brain.thinking)
            }
            Text(s.reason)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(meta(s))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if let sum = s.summary {
                Text(summaryLine(sum))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let err = s.error {
                ErrorBanner(title: "Claude neodpověděl, platí poslední směr", detail: err)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(red: 0.88, green: 0.48, blue: 0.33).opacity(0.45)))
    }

    private func biasLabel(_ b: Bias?) -> String {
        switch b {
        case .long: return "LONG"
        case .short: return "SHORT"
        case .flat: return "FLAT"
        case nil: return "…"
        }
    }

    private func biasColor(_ b: Bias?) -> Color {
        switch b {
        case .long: return Theme.good
        case .short: return Theme.bad
        default: return .secondary
        }
    }

    private func meta(_ s: BrainState) -> String {
        var parts = [s.model]
        if let ms = s.ms { parts.append("\(ms) ms") }
        if let t = s.t {
            let mins = Int((Date().timeIntervalSince1970 - t) / 60)
            parts.append(mins < 1 ? "právě teď" : "před \(mins) min")
        } else {
            parts.append("přemýšlí…")
        }
        return parts.joined(separator: " · ")
    }

    private func summaryLine(_ m: MarketSummary) -> String {
        var parts = [
            "15m \(signed(m.change15mPct)) %",
            "1h \(signed(m.change1hPct)) %",
            "4h \(signed(m.change4hPct)) %",
        ]
        if let c = m.change24hPct { parts.append("24h \(signed(c)) %") }
        if let f = m.fundingRatePct { parts.append("funding \(String(format: "%.4f", f)) %") }
        return parts.joined(separator: " · ")
    }

    private func signed(_ v: Double) -> String {
        (v > 0 ? "+" : "") + String(format: "%.2f", v)
    }
}
