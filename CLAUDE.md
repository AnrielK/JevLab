# JevLab – konvence

- Komunikace, UI, README a ZMENY.md česky. Interní hodnoty akcí strategie ("hold · low conviction" apod.) zůstávají anglicky kvůli shodě s Jev Starterem; v UI se překládají ve `FeedCard.labels`.
- Logika a síť patří do `Packages/JevLabCore` (čistý Swift, `swift test`). App target jen UI.
- iOS 17+ / macOS 14+, SwiftUI, `@Observable`, Swift Charts, `SWIFT_VERSION 5.0`. Žádné závislosti třetích stran.
- Projekt se generuje XcodeGenem (`xcodegen generate`); `*.xcodeproj` není v gitu. Schémata `JevLab_iOS`, `JevLab_macOS`.
- Bezpečnost: aplikace je jen papírová. Nikdy nepřidávat skutečné objednávky bez explicitního požadavku; Bybit (plán 0.2) jen demo jako výchozí, live jen s potvrzovací frází, žádná oprávnění k výběru. Klíče jen v Keychainu, nikdy je nelogovat ani nezobrazovat.
- Výpočty (`MarketBook.snapshot`, `PaperBook`, `JevNormaliser`, `News.judgeCall`) odpovídají Python referenci v Jev Starteru; při změně aktualizovat testy.
- Databáze běhů: `RunStore` (JSON v Application Support/JevLab/runs, `index.json` + soubor na běh). Analýza (`Analysis`) se počítá z uložených rozhodnutí, nikdy nevolá Jev.
- Akciové perpy jsou HIP-3 trhy (`xyz:TICKER`): REST volání potřebují `dex`, poplatky 2×.
- Každá verze dostane záznam v ZMENY.md.
