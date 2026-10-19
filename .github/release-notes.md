Watchdog 1.0.1 für den Mac (macOS 14 oder neuer, Apple Silicon und Intel).

**Neu in 1.0.1: Überwachung der Daten**
- Jeder Wert wird laufend geprüft: Kommen während der Handelszeit keine Kurse, fehlt ein Schlusskurs, endet der Kursverlauf zu früh oder fehlt ein Wechselkurs, wird die Zeile markiert und die Ampel blass gezeigt (letzter bekannter Stand).
- Hinweis oben im Fenster und Warnzeichen in der Menüleiste; nach 20 Minuten Ausfall eine Mitteilung auf Mac und iPhone, höchstens eine am Tag.
- Plausibilitätsprüfung: Kurssprünge über 20 % werden bei einer zweiten Quelle gegengeprüft. Unbestätigte Sprünge bekommen ein „?“ und lösen keinen Alarm aus.
- Freiwilliges Lebenszeichen an healthchecks.io, damit auch ein ausgeschalteter Mac auffällt.
- In den Einstellungen unter Datenquellen steht je Quelle die Uhrzeit des letzten erfolgreichen Abrufs.

**Installation**
1. `Watchdog.dmg` laden, öffnen und Watchdog in „Programme“ ziehen (die alte Version ersetzen).
2. Watchdog starten. Erscheint der Hinweis, dass die App nicht geprüft werden kann: Systemeinstellungen > Datenschutz & Sicherheit > bei „Watchdog wurde blockiert“ auf **Dennoch öffnen** klicken. Nur beim ersten Mal nötig.
3. Mitteilungen und Zugriff auf iCloud Drive erlauben.

Depot, Einstellungen und Regeln bleiben beim Update erhalten.

**Enthalten**
- Alle Werte aus mehreren Depots in einer Tabelle, gruppiert nach Bank oder Thema, dazu Beobachtungswerte.
- Kurs in Euro mit Uhrzeit, heute, seit Kauf, seit Jahresbeginn, 30 Tage.
- Ampel zur 200-Tage-Linie mit Abstandsanzeige und Markierung frischer Durchbrüche.
- Chart mit 38- und 200-Tage-Linie, Kaufkurs und Kaufdaten, 3 Monate bis 5 Jahre.
- Regel-Baukasten, Mitteilungen auf dem Mac und über ntfy auf iPhone und Apple Watch.
- Import aus CSV oder direkt aus Excel/Numbers.
- 19 Börsen vorbelegt, weitere zuschaltbar, Datenquelle per Klick wechselbar.
