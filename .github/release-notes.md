Watchdog 1.0.6 für den Mac (macOS 14 oder neuer, Apple Silicon und Intel).

**Neu in 1.0.6: immer der neueste verfügbare Kurs**
- Liefert eine Quelle keinen oder nur einen alten Kurs, fragt Watchdog die weiteren Quellen und nimmt den neuesten Kurs, den irgendeine Quelle hat. Nach Handelsschluss der Nasdaq ist das der Schlusskurs von 16:00 Uhr New York, nicht mehr der Stand vom letzten erfolgreichen Abruf.
- Dasselbe gilt für den Kursverlauf. Damit ist „Verlauf endet 16.10.“ bei Alico und ImmuCell behoben, und die 200-Tage-Linie ist wieder aktuell.
- Ein schon angezeigter neuerer Kurs wird nie durch einen älteren ersetzt.

**Neu in 1.0.6: richtiges Kürzel, richtige Firma**
- Watchdog prüft bei Yahoo, OnVista und der Financial Times, ob die Daten zur richtigen Firma gehören. Unter dem Kürzel FCA.UN lieferte Yahoo zum Beispiel Kurse von Firm Capital Apartment REIT statt von Metalla, unter AXL1 in Frankfurt kamen Kurse von Axfood für DGH International. Solche Daten werden verworfen.
- Das richtige Kürzel wird über die ISIN gesucht und ins Depot übernommen, Kurs und Verlauf werden neu geladen. In der Zeile steht dann eine Woche lang „Kürzel korrigiert“.
- Werte an ausländischen Börsen bekommen das Kürzel dieser Börse, zum Beispiel ALCO statt AOE und ICCC statt IUL an der Nasdaq. Käufe, Gruppen und Notizen bleiben unverändert.
- Findet Watchdog kein passendes Kürzel, steht „Kürzel prüfen“ in der Zeile, und der Wert hat bis zu echten Kursen keinen Kurs. Bei DGH International, das derzeit vom Handel ausgesetzt ist, ist das so gewollt.
- Nennt eine Quelle einen anderen Namen, obwohl die ISIN passt (zum Beispiel „Google“ und „Alphabet Inc.“), steht „Name prüfen“ in der Zeile. Ein Klick auf „Ist dieselbe Firma“ in der Detailansicht gibt die Daten frei, dauerhaft.
- Der Import übernimmt keinen Treffer mehr, dessen Name nicht zum Namen in der Datei passt.

**Installation**
1. `Watchdog.dmg` direkt auf dem Mac in Safari von GitHub laden. Kommt die Datei über WhatsApp, iPhone oder AirDrop, meldet macOS sie als beschädigt.
2. Die laufende Version über das Symbol in der Menüleiste beenden.
3. Die DMG öffnen und Watchdog in „Programme“ ziehen (die alte Version ersetzen).
4. Watchdog starten. Erscheint der Hinweis, dass die App nicht geprüft werden kann: Systemeinstellungen > Datenschutz & Sicherheit > bei „Watchdog wurde blockiert“ auf **Dennoch öffnen** klicken. Das ist nach **jeder** neuen Version nötig, nicht nur beim ersten Mal.

Depot, Einstellungen und Regeln bleiben beim Update erhalten.
