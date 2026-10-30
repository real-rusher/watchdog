Watchdog 1.0.9 für den Mac (macOS 14 oder neuer, Apple Silicon und Intel).

**Neu in 1.0.9**
- Mac und iPhone bearbeiten dasselbe Depot. Vor dem Speichern liest Watchdog die Depotdatei neu und übernimmt nur die eigenen Änderungen. Speichern Mac und iPhone kurz nacheinander, bleiben die Änderungen beider erhalten.
- Bank und Thema für mehrere Werte auf einmal: Werte mit ⌘-Klick oder ⇧-Klick auswählen, dann in der Auswahlleiste „Bank …“ oder „Thema …“ wählen, oder per Rechtsklick „Bank zuweisen“ und „Thema zuweisen“. Rückgängig ist möglich.
- Rückgängig nach dem Löschen setzt nur die gelöschten Werte zurück, Änderungen vom iPhone in derselben Zeit bleiben.
- Diese Version vor dem Bearbeiten auf dem iPhone installieren. Ältere Versionen kennen das Zusammenführen noch nicht.

**Aus 1.0.8**
- Wird bei einem Wert die ISIN, die WKN oder der Name nachgetragen oder geändert, sucht Watchdog sofort neu nach dem richtigen Kürzel. Bisher geschah das nur beim Wechsel der Börse, und eine Quelle, die vorher eine andere Firma geliefert hatte, wurde sechs Stunden lang nicht mehr gefragt (Fall Metalla mit dem Kürzel FCA.UN).
- Fehlt einem Wert die ISIN, sagt der Hinweis „Kürzel prüfen“ das jetzt ausdrücklich und nennt die Abhilfe.
- Kleine Verbesserungen für die Einrichtung der Mitteilungen auf iPhone und Apple Watch.

**Aus 1.0.7: Mitteilungen auf Mac, iPhone und Apple Watch, abgestimmt**
- Neben der Depotdatei in iCloud Drive liegt jetzt die kleine Datei „Mitteilungen.json“, das Meldebuch. Darin steht, welches Gerät zuletzt geprüft und was es gemeldet hat.
- Gemeldet wird in fester Reihenfolge: zuerst der Mac. Prüft er 20 Minuten lang nicht oder bekommt kaum Kurse, übernimmt das iPhone, danach die Apple Watch. Kein Durchbruch wird doppelt gemeldet, auch nicht über ntfy.
- Einstellungen > Mitteilungen zeigt, welches Gerät gerade meldet und wann jedes zuletzt geprüft hat.
- Kürzere Meldungen, die auch auf der Apple Watch ganz lesbar sind, zum Beispiel „Cameco: fällt unter die 200-Tage-Linie“ mit Kurs, Linie und Abstand darunter.
- Neue Einstellung für ntfy: Tippen auf die Meldung öffnet den Wert in der Watchdog-App auf dem iPhone. Erst einschalten, wenn die App installiert ist.

**Vorbereitet: Watchdog für iPhone, iPad und Apple Watch**
- Die Apps sind gebaut und im Simulator getestet: Depot mit Ampel, Chart und Kennzahlen auf iPhone und iPad, Liste und Komplikation auf der Watch.
- Auf echte Geräte kommen sie erst mit einem Apple-Entwicklerkonto. Bis dahin laufen die Meldungen auf iPhone und Watch über ntfy.

**Aus 1.0.6**
- Immer der neueste verfügbare Kurs, auch wenn eine Quelle nur einen alten Stand liefert.
- Falsche Kürzel werden über die ISIN korrigiert, Daten einer anderen Firma werden nie verwendet.

**Installation**
1. `Watchdog.dmg` direkt auf dem Mac in Safari von GitHub laden. Kommt die Datei über WhatsApp, iPhone oder AirDrop, meldet macOS sie als beschädigt.
2. Die laufende Version über das Symbol in der Menüleiste beenden.
3. Die DMG öffnen und Watchdog in „Programme“ ziehen (die alte Version ersetzen).
4. Watchdog starten. Erscheint der Hinweis, dass die App nicht geprüft werden kann: Systemeinstellungen > Datenschutz & Sicherheit > bei „Watchdog wurde blockiert“ auf **Dennoch öffnen** klicken. Das ist nach **jeder** neuen Version nötig, nicht nur beim ersten Mal.

Depot, Einstellungen und Regeln bleiben beim Update erhalten.
