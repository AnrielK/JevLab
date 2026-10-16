# JevLab

Nativní aplikace pro **macOS a iPhone** postavená podle *Jev Starteru*: živý obchodní dashboard, kde Jev (rychlé AI odpovídající na otázky typu „buy nebo sell?“ s jistotou za ~0,5 s) volá na skutečném trhu, newsroom se skutečnými kryptotitulky a nastavitelná strategie.

**Jen papírové obchodování.** Aplikace čte veřejná data Hyperliquid a fills simuluje se skutečnými poplatky. Nikdy neposílá objednávku a nepotřebuje účet na burze. Není to finanční poradenství.

## Co umí (0.1)

| Záložka | Co dělá |
|---|---|
| **Smyčka** | Živá microprice z Hyperliquid (WebSocket, ~8× za s), Jev volání jako tečky v grafu, ◆ vyplněné obchody, ležící limitní objednávka, „co Jev viděl“, papírový účet $1,000 s P&L před/po poplatcích a křivkou equity, feed všech volání. Coiny HYPE/BTC/ETH/SOL, délka 5/10/30 min nebo do zastavení, limitní (maker 1,5 bps) nebo tržní (taker 4,5 bps + spread) objednávky. Tempo se samo zpomalí při 429 (free tier). |
| **Newsroom** | Zrychlený replay titulků z posledních 12/24/36 h (Cointelegraph, CoinDesk, Decrypt, The Block). Jev u každého určí coin, směr a dopad; obchoduje se jen „Notable“/„Major“, 1 min po zprávě, držení 60 min. Graf ukáže skutečný pohyb ceny z 1min svíček. Skóre po nákladech (10 bps round-trip). |
| **Strategie** | Výběr strategie a jejích parametrů, platí okamžitě i za běhu: *Přesvědčení* (jistota ≥ X %, pauza mezi otočkami) nebo *Po trendu* (30s návrat + podíl agresivních nákupů). |
| **Nastavení** | Jev klíč (Vercel AI Gateway nebo přímý TypeSafe) uložený v Keychainu, kontrola nastavení (ceny, feedy, jedno Jev volání, rychlost tieru). |

## Jev klíč

vercel.com/dashboard → **AI Gateway → API Keys → Create key**. Vercel vyžaduje u týmu platební kartu a **Jev je dostupný jen s placenými kredity** v AI Gateway (free tier vrací HTTP 403 „Free tier users do not have access to this model“, na rozdíl od tvrzení v Jev Starteru). Doporučeno nastavit klíči budget.

## Struktura

```
project.yml                       XcodeGen: target JevLab pro iOS i macOS (JevLab_iOS, JevLab_macOS)
JevLab/                           SwiftUI aplikace
  App/                            @main, AppModel (@Observable, @MainActor), kontrola nastavení
  Loop/                           záložka Smyčka (graf, karty, feed)
  Newsroom/                       záložka Newsroom
  Strategy/                       záložka Strategie
  Settings/                       záložka Nastavení
  Shared/                         barvy, formátování, Keychain
  Resources/Assets.xcassets       AppIcon + AccentColor
Packages/JevLabCore/              logika bez UI (testovatelná přes swift test)
  Jev.swift                       Jev klient + normalizace odpovědí
  Hyperliquid.swift               REST (ceny, svíčky) + WebSocket feed
  MarketBook.swift                stav trhu a snapshot pro Jev
  PaperBook.swift                 papírová pozice, poplatky, equity
  Strategy.swift                  strategie + uložitelné nastavení
  LoopEngine.swift                Jev smyčka (tempo, backoff, limitní objednávky)
  News.swift, NewsroomEngine.swift  RSS, cenové cesty, replay
.github/workflows/build.yml       CI: testy jádra → iOS IPA + macOS app (nepodepsané)
```

## Build

```sh
brew install xcodegen
xcodegen generate
open JevLab.xcodeproj           # schéma JevLab_iOS nebo JevLab_macOS
swift test --package-path Packages/JevLabCore
```

CI na GitHub Actions staví nepodepsanou `JevLab-unsigned.ipa` (k podepsání/sideloadu) a `JevLab-macOS-unsigned.zip`.

## Omezení

- Jen papír: žádné skutečné objednávky, žádný burzovní klíč.
- Strategie se v aplikaci nastavuje parametry, ne volným kódem (na iPhonu nejde editovat Python jako ve starteru).
- Na iOS běží smyčka jen v popředí; po zamčení telefonu se WebSocket přeruší.
- Newsroom potřebuje titulky starší než ~62 min, aby šel vyhodnotit pohyb ceny.

## Plán

- 0.2: Bybit **demo** bot (post-only limitní objednávky, Claude jako „mozek“ nastavující bias long/short/flat, denní limit ztráty, kill switch). Live režim jen s explicitním potvrzením.
- Vlastní pravidla strategie poskládaná v UI (podmínky nad poli stavu).
- Ukládání historie běhů a srovnání strategií po poplatcích.
- Widget / Live Activity s aktuálním P&L.
