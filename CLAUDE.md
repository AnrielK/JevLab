# JevLab – konvence

- Komunikace, UI, README a ZMENY.md česky. Interní hodnoty akcí strategie ("hold · low conviction" apod.) zůstávají anglicky kvůli shodě s Jev Starterem; v UI se překládají ve `FeedCard.labels`.
- Logika a síť patří do `Packages/JevLabCore` (čistý Swift, `swift test`). App target jen UI.
- iOS 17+ / macOS 14+, SwiftUI, `@Observable`, Swift Charts, `SWIFT_VERSION 5.0`. Žádné závislosti třetích stran.
- Projekt se generuje XcodeGenem (`xcodegen generate`); `*.xcodeproj` není v gitu. Schémata `JevLab_iOS`, `JevLab_macOS`.
- Bezpečnost: aplikace je jen papírová. Nikdy nepřidávat skutečné objednávky bez explicitního požadavku; Bybit (plán 0.2) jen demo jako výchozí, live jen s potvrzovací frází, žádná oprávnění k výběru. Klíče jen v Keychainu, nikdy je nelogovat ani nezobrazovat.
- Výpočty (`MarketBook.snapshot`, `PaperBook`, `JevNormaliser`, `News.judgeCall`) odpovídají Python referenci v Jev Starteru; při změně aktualizovat testy.
- Každá verze dostane záznam v ZMENY.md.
