import SwiftUI
import JevLabCore

enum Theme {
    static let jev = Color(red: 0.545, green: 0.482, blue: 1.0)      // #8b7bff
    static let good = Color(red: 0.247, green: 0.839, blue: 0.541)   // #3fd68a
    static let bad = Color(red: 1.0, green: 0.365, blue: 0.424)      // #ff5d6c
    static let late = Color(red: 0.961, green: 0.71, blue: 0.239)    // #f5b53d
    static let card = Color(red: 0.055, green: 0.075, blue: 0.102)   // #0e131a
    static let line = Color(red: 0.102, green: 0.133, blue: 0.176)   // #1a222d
    static let background = Color(red: 0.024, green: 0.031, blue: 0.047)

    static func color(for side: Side?) -> Color {
        switch side {
        case .buy: return good
        case .sell: return bad
        case nil: return late
        }
    }
}

/// Karta se zaobleným rámečkem.
struct Card<Content: View>: View {
    var title: String?
    var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
    }
}

enum F {
    static func usd(_ v: Double) -> String {
        (v >= 0 ? "+$" : "−$") + String(format: "%.2f", abs(v))
    }

    static func money(_ v: Double) -> String {
        "$" + String(format: "%.2f", v)
    }

    static func pct(_ v: Double) -> String {
        "\(Int((v * 100).rounded())) %"
    }

    static func bps(_ v: Double, digits: Int = 1) -> String {
        (v > 0 ? "+" : v < 0 ? "−" : "") + String(format: "%.\(digits)f", abs(v)) + " bps"
    }

    static func duration(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// "dnes 14:07" / "včera 14:07" / "15. 10. 14:07".
    static func dayTime(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        let cal = Calendar.current
        let prefix: String
        if cal.isDateInToday(d) {
            prefix = "dnes"
        } else if cal.isDateInYesterday(d) {
            prefix = "včera"
        } else {
            let f = DateFormatter()
            f.dateFormat = "d. M."
            prefix = f.string(from: d)
        }
        return "\(prefix) \(time(t))"
    }

    static func num(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e6 ? String(Int(v)) : String(format: "%g", v)
    }
}

/// Viditelná chybová hláška se skutečným textem chyby.
struct ErrorBanner: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.octagon.fill")
                .font(.footnote.weight(.semibold))
            Text(detail)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
            Text(ErrorBanner.hint(for: detail))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Theme.bad)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    static func hint(for detail: String) -> String {
        if detail.contains("HTTP 401") || detail.contains("HTTP 403") {
            return "Klíč byl odmítnut: zkontroluj, že je celý (začíná vck_), a že má Vercel tým kartu nebo kredity."
        }
        if detail.contains("HTTP 429") { return "Free tier je vytížený: počkej, nebo přidej kredity v AI Gateway." }
        if detail.contains("HTTP 402") { return "Došly kredity v AI Gateway." }
        if detail.contains("HTTP 404") { return "Endpoint nenalezen: Jev na tomhle klíči nemusí být dostupný." }
        return "Pošli tenhle text a podívám se na to."
    }
}
