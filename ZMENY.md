# Změny

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
