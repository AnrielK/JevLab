# Změny

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
