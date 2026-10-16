import SwiftUI
import JevLabCore

/// Jev klíč (uložený v Keychainu) a kontrola nastavení.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyKind: AppModel.KeyKind = .gateway
    @State private var keyText = ""

    var body: some View {
        @Bindable var bindable = model
        NavigationStack {
            Form {
                Section {
                    Picker("Typ klíče", selection: $keyKind) {
                        ForEach(AppModel.KeyKind.allCases) { Text($0.label).tag($0) }
                    }
                    SecureField(keyKind == .gateway ? "AI_GATEWAY_API_KEY" : "TYPESAFE_API_KEY", text: $keyText)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    HStack {
                        Button("Uložit do Keychainu") {
                            model.saveKey(keyText, kind: keyKind)
                            keyText = ""
                        }
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        if isStored(keyKind) {
                            Button("Smazat", role: .destructive) { model.deleteKey(keyKind) }
                        }
                    }
                    Label(isStored(keyKind) ? "Klíč je uložený" : "Klíč zatím chybí",
                          systemImage: isStored(keyKind) ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(isStored(keyKind) ? Theme.good : Theme.late)
                } header: {
                    Text("Jev klíč")
                } footer: {
                    Text("Klíč získáš na vercel.com/dashboard → AI Gateway → API Keys → Create key. Vercel vyžaduje platební kartu a Jev funguje jen s placenými kredity v AI Gateway. Doporučuji klíči nastavit budget. Klíč zůstává jen v Keychainu tohoto zařízení a nikde se nezobrazuje.")
                }

                Section {
                    TextField("anthropic/claude-sonnet-5.5", text: $bindable.claudeModel)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .font(.system(.body, design: .monospaced))
                    Button("Výchozí model") { model.claudeModel = ClaudeClient.defaultModel }
                } header: {
                    Text("Claude mozek")
                } footer: {
                    Text("Model přes Vercel AI Gateway (stejný klíč jako Jev). Claude čte trh jednou za 5–15 minut, takže stojí jen zlomek ceny Jev volání.")
                }

                Section {
                    Button {
                        Task { await model.runCheck() }
                    } label: {
                        HStack {
                            Text("Zkontrolovat nastavení")
                            if model.checking {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(model.checking)
                    ForEach(model.checkLines) { line in
                        CheckRow(line: line)
                    }
                } header: {
                    Text("Kontrola")
                } footer: {
                    Text("Ceny Hyperliquid, zpravodajské feedy, jedno skutečné Jev volání a rychlost tvého tieru.")
                }

                Section("O aplikaci") {
                    Text("JevLab je jen papírové obchodování: čte veřejná data Hyperliquid a fills simuluje. Nikdy neposílá skutečnou objednávku a nepotřebuje účet na burze.")
                    Text("Není to finanční poradenství. Žádná strategie nemá zaručený zisk.")
                        .foregroundStyle(.secondary)
                    LabeledContent("Verze", value: appVersion)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Nastavení")
            .onChange(of: model.claudeModel) { model.saveClaudeModel() }
        }
    }

    private func isStored(_ kind: AppModel.KeyKind) -> Bool {
        kind == .gateway ? model.hasGatewayKey : model.hasDirectKey
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }
}

struct CheckRow: View {
    let line: CheckLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).fontWeight(.semibold)
                Text(line.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch line.state {
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.late)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.bad)
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}
