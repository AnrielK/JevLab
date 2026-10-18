# Změny

## 0.9.1 · 2026-10-18

- Graf v Trend strategii: TradingView Lightweight Charts™ 5.2.1 (přibalené v aplikaci, Apache 2.0) se svíčkami, MA20/MA50, šipkami vstupů a výstupů vybrané varianty a čárkovaným supportem a rezistencí. Posun a zoom prstem. Atribuce TradingView v grafu a v Nastavení → Licence.
- `pine/jevlab_trend_ma.pine`: stejná strategie Trend MA jako Pine Script v6 pro TradingView (Strategy Tester) k nezávislému ověření.
- Výchozí varianta Trend strategie je „Trend MA · jen long“.

## 0.9.0 · 2026-10-17

- Trend strategie (z Horizontu, zdarma, bez AI): Trend MA a Průraz na celé historii Hyperliquid v 8 variantách (long/short vs jen long, stálá pozice vs velikost podle ATR). Pro každou výsledek za rok, na 2. polovině, největší propad, obchody a čas v pozici; srovnání s držením long; graf kapitálu; export CSV.
- Dnešní signál vybrané varianty z poslední uzavřené svíčky (LONG/SHORT/FLAT, velikost, od kdy v pozici, vzdálenost od MA20/MA50). Papírově, nic se neobchoduje.

## 0.8.2 · 2026-10-17

- Oprava srovnání v Pravidlech bez AI: strategie se teď porovnávají s držením long se stejnou stálou pozicí $1000 (dřív s úročeným „kupit a držet“, které při násobných růstech strategie znevýhodňovalo). Úročené držení zůstává v CSV jako další sloupec.

## 0.8.1 · 2026-10-17

- Pravidla bez AI: každý dokončený běh se uloží; tlačítko „Poslat CSV“ (pravidlo × trh, „kupit a držet“ a souhrnné řádky přes trhy). Seznam uložených výsledků s detailem, exportem a mazáním.
- Přehlednější výběr akcií: místo dlouhého seznamu vyhledávání podle tickeru s oblíbenými (★). Ve výběru trhu jsou jen krypto + oblíbené akcie a tlačítko „Akcie…“; v Pravidlech se akcie přidávají přes „Přidat“.

## 0.8.0 · 2026-10-17

- „Pravidla bez AI“ (z Horizontu): backtest všech pravidel na maximální historii Hyperliquid (~5000 svíček na rámec) pro vybrané trhy najednou (krypto i akcie), rámce 1h/4h/1D, volitelně s kontextem. Bez Jev a Clauda, takže zdarma. Souhrn přes trhy: průměr po poplatcích, kolikrát v plusu na 2. polovině a kolikrát porazilo „kupit a držet“; detail pro každý trh.
- Rychlejší výpočet kontextu z vyšších rámců (jen okno posledních svíček místo celé historie).

## 0.7.1 · 2026-10-17

- Při vyčerpaném rozpočtu/kreditech nebo odmítnutém klíči (HTTP 401/402/403) se backtest, živý horizont i smyčka hned zastaví místo stovek zbytečných volání; běh bez jediné odpovědi Jev se neukládá do Historie.
- Srozumitelná hláška pro „Team budget exceeded“; odhad ceny backtestu jasně říká, že je jen za Jev (Claude zvlášť).

## 0.7.0 · 2026-10-16

- Kombinovaná pravidla nad indikátory: odraz od supportu / odmítnutí u rezistence s RSI, průraz (½ ATR od 50svíčkového extrému + sklon MA20), trend MA, RSI návrat, týdenní trend + denní pullback. Vyhodnocení po poplatcích na celém období i druhé polovině, bez Jev volání.
- Příznaky setupů ve stavu pro Jev a Clauda (`setup_support_bounce`, `setup_resistance_rejection`, `setup_breakout_up`, `setup_breakdown`, `setup_ma_trend`, `setup_weekly_pullback`).
- Logistická regrese nad featurami (trénink na první polovině, test na druhé) s porovnáním proti „vždy většinový směr“ a s největšími vahami.
- Karty „Pravidla nad indikátory“ a „Dá se z featur něco naučit?“ v analýze běhu.

## 0.6.1 · 2026-10-16

- Stálé názvy featur: vzdálenost od maxima/minima vždy z 50 svíček a průměr z 10 svíček (dřív se název měnil podle dostupné historie, např. 36bar/42bar). Nižší rámec se stahuje s delší rezervou.
- CSV export obsahuje sloupec `claude_bias`.

## 0.6.0 · 2026-10-16

- Indikátory ve featurách pro Jev i Clauda: MA 20/50/200 (vzdálenost a sklon MA20), RSI 14, ATR 14, vzdálenost od 50svíčkového maxima/minima. Na vyšších rámcích MA 10/20, RSI a ATR.
- Support a rezistence: swing maxima/minima (potvrzená až uzavřenými svíčkami), shlukovaná do úrovní s počtem dotyků; nejbližší support pod cenou a rezistence nad ní, vzdálenost v bps i v ATR. Na obchodním rámci a na vyšších rámcích (týden, měsíc).
- Backtest si stahuje 200 svíček historie navíc, aby indikátory platily od prvního rozhodnutí.
- Karta „Support a rezistence“ v Horizontu.

## 0.5.0 · 2026-10-16

- Claude v Horizontu (backtest i živě): každých N svíček nastaví směr long/short/flat ze stejných relativních čísel, jaká vidí Jev (bez cen, dat a zpráv, aby z historie nepoznal období). Ke každému rozhodnutí se ukládá Jev směr i Claudův bias.
- Srovnání „Jev sám / Jev + Claude / Claude sám“ ze stejného běhu, na celém období i na nových datech (druhá polovina), plus přepínač režimu pro výsledek, sweep prahů a walk-forward.
- Oprava akcií: seznam akciových trhů se načítá z API Hyperliquid (dex xyz) místo pevných názvů; chyby Hyperliquid se zobrazují i se skutečnou odpovědí serveru.

## 0.4.0 · 2026-10-16

- Horizont: nové rámce 4 hodiny a 1 den.
- Kontext z více timeframů: u denního obchodování Jev vidí i 4h (nižší), týdenní a měsíční svíčky; u 4h 1h/1D/1W, u 1h 15m/4h/1D. Featury z kontextu se počítají jen z uzavřených svíček a u tvořící se svíčky jen z její otevírací ceny, takže backtest nikdy nevidí budoucnost. Dá se vypnout pro srovnání.
- Karta „Co Jev viděl“ u posledního rozhodnutí, seskupená podle rámce.
- Delší backtesty (až ~1500 dní u denního, omezeno historií Hyperliquid) a výchozí délka podle horizontu.

## 0.3.0 · 2026-10-16

- Horizont: Jev odhaduje směr na 5 min / 15 min / 1 h ze svíčkových featur. Backtest na historii (až ~5000 svíček, souběžná volání, odhad ceny) a živý režim na zavření svíček.
- US akciové perpy na Hyperliquid (HIP-3, `xyz:NVDA` apod.) ve smyčce i horizontu, s 2× poplatky a ukazatelem otevřené burzy v USA.
- Historie: databáze běhů (JSON v Application Support) s každým rozhodnutím, featurami a výsledkem. Analýza: výsledek po poplatcích pro libovolný práh, kalibrace jistoty, sweep prahů, walk-forward test, porovnání s „kupit a držet“, export CSV.
- Strategie smyčky přesunuta do Nastavení; nové záložky Horizont a Historie.

## 0.2.0 · 2026-10-16

- Claude mozek ve Smyčce: Claude (přes Vercel AI Gateway) každých 5/10/15 min přečte souhrn trhu z Hyperliquid a poslední titulky a nastaví bias long/short/flat. Jev obchoduje jen tím směrem, při změně směru se pozice zavře. Karta s biasem, jistotou, zdůvodněním a tlačítkem „Přečíst teď“.
- Nastavitelný Claude model v Nastavení (výchozí `anthropic/claude-sonnet-5.5`).
- Testy logiky mozku (souhrn trhu podle Python reference, parsování odpovědi, pravidla brány).

## 0.1.2 · 2026-10-16

- Oprava: na iPhonu na výšku se stránka smyčky roztahovala doprava (pruh teček měl pevnou šířku). Pruh se teď kreslí podle dostupné šířky a obsah záložek je ukotvený na šířku displeje.
- Popisek ležící limitní objednávky v grafu nepřetéká mimo graf.
- Nápověda k chybě „request timed out“.

## 0.1.1 · 2026-10-16

- Smyčka i Newsroom teď ukazují skutečnou chybu Jev volání (HTTP kód a text) s nápovědou, co s ní dělat. Dřív se chyby jen tiše počítaly.
- Nový ukazatel „chyby“ ve statistikách smyčky, statistiky se na iPhonu zalamují místo useknutí.
- Konkrétní nápověda pro chyby Vercelu (chybějící karta, Jev jen pro placené kredity); README a Nastavení opravují tvrzení, že Jev funguje na free tieru.
- U titulků v newsroomu je vidět i den („včera 14:07“), aby bylo jasné, že jde o replay.

## 0.1.0 · 2026-10-16

- První verze pro macOS a iPhone podle Jev Starteru.
- Smyčka: živý Hyperliquid feed, Jev volání, papírové limitní/tržní obchody s poplatky, graf, účet a feed.
- Newsroom: replay skutečných titulků, Jev čte coin/směr/dopad, skutečný 60min pohyb ceny, skóre po nákladech.
- Strategie *Přesvědčení* a *Po trendu* s nastavitelnými parametry.
- Jev klíč v Keychainu, kontrola nastavení.
- Jádro `JevLabCore` s testy (referenční hodnoty z původního Python kódu), CI pro iOS i macOS.
