import SwiftUI
import JevLabCore

/// Vyhledávání akciových trhů. Jednoduchý výběr (vrátí ticker) nebo vícenásobný (přepíná v množině).
struct StockSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// Vícenásobný výběr: množina vybraných trhů. Když je nil, jde o jednoduchý výběr přes `onPick`.
    var selection: Binding<Set<String>>?
    var onPick: ((String) -> Void)?

    private var filtered: [Instrument] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        let all = model.stocks
        guard !q.isEmpty else { return all }
        return all.filter { $0.label.uppercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty, !model.favoriteStocks.isEmpty {
                    Section("Oblíbené") {
                        ForEach(model.favoriteInstruments) { row($0) }
                    }
                }
                Section(query.isEmpty ? "Všechny akcie (\(model.stocks.count))" : "Výsledky") {
                    ForEach(filtered) { row($0) }
                }
                if let note = model.stocksNote {
                    Text(note).font(.caption).foregroundStyle(Theme.late)
                }
            }
            .searchable(text: $query, prompt: "Ticker, např. NVDA")
            .autocorrectionDisabled()
            .navigationTitle("Akcie")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
    }

    private func row(_ inst: Instrument) -> some View {
        let fav = model.favoriteStocks.contains(inst.coin)
        let picked = selection?.wrappedValue.contains(inst.coin) ?? false
        return HStack {
            Button {
                if let sel = selection {
                    if picked { sel.wrappedValue.remove(inst.coin) } else { sel.wrappedValue.insert(inst.coin) }
                } else {
                    onPick?(inst.coin)
                    dismiss()
                }
            } label: {
                HStack {
                    if selection != nil {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked ? Theme.jev : Color.secondary)
                    }
                    Text(inst.label).font(.body.weight(.semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                model.toggleFavorite(inst.coin)
            } label: {
                Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? Theme.late : Color.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}
