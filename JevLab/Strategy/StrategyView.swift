import SwiftUI
import JevLabCore

/// Strategie rozhoduje, která Jev volání se stanou obchody. Změny platí hned, i za běhu smyčky.
struct StrategyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bindable = model
        Form {
                Section {
                    Text("Jev volá několikrát za sekundu („buy, 91 %“). Strategie rozhoduje, která volání se stanou obchody. Většina má skončit „hold“: každý obchod něco stojí, takže bot, který obchoduje každé volání, krvácí.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Strategie") {
                    Picker("Typ", selection: $bindable.strategy.kind) {
                        Text("Přesvědčení").tag(StrategySettings.Kind.conviction)
                        Text("Po trendu").tag(StrategySettings.Kind.trend)
                    }
                    .pickerStyle(.segmented)
                    Text(model.strategy.make().summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.jev)
                }

                if model.strategy.kind == .conviction {
                    Section {
                        slider("Minimální jistota Jev", value: $bindable.strategy.minConf, range: 0.5...0.99, step: 0.01) { F.pct($0) }
                        slider("Pauza mezi otočkami", value: $bindable.strategy.minHold, range: 0...120, step: 1) { "\(Int($0)) s" }
                    } header: {
                        Text("Přesvědčení")
                    } footer: {
                        Text("Obchoduje jen když si je Jev dost jistý a od posledního obchodu uplynula pauza (žádné cukání sem a tam).")
                    }
                } else {
                    Section {
                        slider("Minimální jistota Jev", value: $bindable.strategy.trendMinConf, range: 0.5...0.99, step: 0.01) { F.pct($0) }
                        slider("Podíl agresivních nákupů (30 s)", value: $bindable.strategy.trendBuyShare, range: 0.5...0.8, step: 0.01) { F.pct($0) }
                    } header: {
                        Text("Po trendu")
                    } footer: {
                        Text("Kupuje jen když cena za 30 s roste a kupující mají navrch, prodává jen při opaku. Proti trendu drží.")
                    }
                }

                Section("Než strategii uvěříš") {
                    Label("Proč by měla vydělávat?", systemImage: "1.circle")
                    Label("Vydělává i po nákladech (poplatky, spread)?", systemImage: "2.circle")
                    Label("Funguje na datech, která nikdy neviděla?", systemImage: "3.circle")
                }

                Section {
                    Button("Obnovit výchozí") { model.strategy = StrategySettings() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Strategie smyčky")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
