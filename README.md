# Watchdog

Musterdepot für den Mac, das alle Aktien aus mehreren Depots in einer Tabelle bündelt und für jeden Wert zeigt, ob der Kurs über oder unter seiner 200-Tage-Linie steht. Bricht ein Wert durch die Linie, meldet sich Watchdog auf dem Mac und auf Wunsch auf iPhone und Apple Watch.

Reine Ansicht: kein Handel, keine Nachrichten, keine Verbindung zu Banken. Alles wird von Hand gepflegt oder per Liste importiert.

## Installation

1. Unter [Releases](../../releases/latest) die Datei `Watchdog.dmg` laden und öffnen.
2. Watchdog in den Ordner „Programme“ ziehen.
3. Watchdog per Doppelklick starten. macOS meldet beim ersten Mal, dass die App nicht geprüft werden kann (sie ist noch nicht bei Apple signiert). Dann:
   **Systemeinstellungen > Datenschutz & Sicherheit**, ganz unten bei „Watchdog wurde blockiert“ auf **Dennoch öffnen** klicken und bestätigen. Das ist nur einmal nötig.
4. Beim ersten Start fragt macOS, ob Watchdog Mitteilungen senden und auf iCloud Drive zugreifen darf. Beides erlauben.

Voraussetzung: macOS 14 Sonoma oder neuer, Apple-Silicon- oder Intel-Mac.

## Erste Schritte

- **Beispieldepot ansehen**: zeigt die App mit echten Kursen, ohne etwas einzutragen.
- **Wertpapier hinzufügen** (⌘N): ISIN, WKN, Name oder Kürzel eintippen, Börse aus der Trefferliste wählen, Käufe mit Datum, Stück und Preis in Euro eintragen. Ohne Kauf wird der Wert nur beobachtet.
- **Importieren** (⌘I): Datei in das Fenster ziehen oder öffnen, oder eine Tabelle aus Excel/Numbers kopieren und einfügen. Mehr dazu unter „Import“.
- Oben links umschalten zwischen **Banken**, **Themen** (z. B. Uran, Öl, Gold) und **Liste**.

## Import

Watchdog liest Excel-Dateien (.xlsx), LibreOffice-Dateien (.ods), CSV und Text, auch Exporte von Banken (zum Beispiel die Depotumsätze von comdirect). Zeichensätze (UTF-8, UTF-16, Windows, Mac) und Zahlenformate (1.234,56 oder 1,234.56) werden erkannt, ebenso Kopfzeilen, die nicht in der ersten Zeile stehen.

- Spalten wie Name, ISIN, WKN, Kürzel, Stück, Kaufkurs, Kaufwert, Kaufdatum, Kauf/Verkauf, Börse, Bank, Thema und Währung werden automatisch zugeordnet und lassen sich oben im Dialog ändern.
- Mehrere Zeilen desselben Werts werden zu einer Position mit mehreren Käufen; Verkäufe ziehen Stücke von den ältesten Käufen ab. Komplett verkaufte Werte sind abgewählt.
- Kaufpreise in Fremdwährung werden zum EZB-Kurs vom Kaufdatum in Euro umgerechnet.
- Die Suche nach dem Handelsplatz startet sofort. Wird ein Wert an der gewünschten Börse nicht gehandelt, nimmt Watchdog einen deutschen Handelsplatz (bei Kauf in Fremdwährung die Heimatbörse) und schreibt das dazu; je Zeile lässt sich der Handelsplatz wechseln.
- Schon vorhandene Werte werden nicht doppelt angelegt, neue Käufe werden ergänzt.
- Numbers-Dateien und alte Excel-Dateien (.xls) bitte als .xlsx oder CSV speichern oder die Tabelle kopieren und einfügen.

## Die Ampel

| Farbe | Bedeutung |
| --- | --- |
| Grün | Kurs liegt über der 200-Tage-Linie |
| Gelb | Kurs liegt knapp über der Linie (Abstand unter 2 %, einstellbar) |
| Rot | Kurs liegt unter der Linie |
| Gelber Ring | Die Linie wurde in den letzten 5 Handelstagen gekreuzt |

Die Linie ist der einfache gleitende Durchschnitt der letzten 200 Schlusskurse an der gewählten Börse, gerechnet in der Börsenwährung. Angezeigt wird alles in Euro. Unter **Einstellungen > Signale** lassen sich Linie, gelbe Zone und weitere Regeln (z. B. 38er kreuzt 200er) anpassen.

## Mitteilungen

- **Mac**: Banner bei jedem neuen Durchbruch. Watchdog läuft dafür in der Menüleiste weiter, auch wenn das Fenster geschlossen ist. In den Einstellungen „Beim Anmelden am Mac starten“ einschalten.
- **iPhone und Apple Watch**: Einstellungen > Mitteilungen > „Mitteilungen an ntfy senden“ einschalten, auf dem iPhone die kostenlose App **ntfy** installieren und den angezeigten Kanal abonnieren (QR-Code scannen).

## Kursdaten

Standard ist Yahoo Finance. Fällt Yahoo aus oder drosselt, nimmt Watchdog automatisch die nächste Quelle: OnVista (Tradegate, gettex, LS Exchange und weitere), Financial Times (Tokio, Australien, Kanada, Skandinavien und weitere), Lang & Schwarz, Tradegate, Bitfinex. Mit eigenem API-Schlüssel zusätzlich EODHD, Twelve Data, Alpha Vantage und Finnhub. Reihenfolge und erste Quelle lassen sich in der Symbolleiste und unter Einstellungen > Datenquellen ändern.

Die Kurse sind echte Börsenkurse, aber keine Echtzeitkurse: je nach Börse und Quelle 15 bis 20 Minuten verzögert, bei der Financial Times nur Schlusskurse. Umgerechnet wird mit dem Referenzkurs der EZB vom jeweiligen Tag; die eigene Bank rechnet mit ihrem Kurs und Aufschlag, daher weichen Euro-Werte leicht ab.

### Wenn Daten ausbleiben

Watchdog prüft bei jeder Aktualisierung, ob die Daten jedes Werts aktuell sind, und richtet sich dabei nach den Handelszeiten der jeweiligen Börse:

| Fall | Anzeige |
|---|---|
| Börse offen, aber seit 45 Minuten kein Kurs angekommen | Warnzeichen und „seit 14:05 keine Kurse“ in der Zeile, Uhrzeit orange |
| Börse geschlossen, Schlusskurs nicht angekommen | „Schlusskurs 14.10. fehlt“ |
| Kursverlauf endet mehrere Handelstage zu früh | „Verlauf endet 08.10.“, die 200-Tage-Linie ist dann nicht aktuell |
| Wechselkurs fehlt oder ist älter als 5 Tage | „Wechselkurs JPY fehlt“ |
| Quelle antwortet, der Wert wurde aber nicht gehandelt | dezenter Hinweis „kein Kurs von heute“, keine Warnung |

Betroffene Werte zeigen Ampel und Abstand blass mit gestricheltem Rand: Das ist der letzte bekannte Stand, kein aktuelles Signal. Oben im Fenster erscheint ein Hinweis mit den Namen, in der Menüleiste ein Warnzeichen. Hält der Ausfall 20 Minuten an, kommt eine Mitteilung auf Mac und iPhone (höchstens eine am Tag, abschaltbar unter Einstellungen > Mitteilungen).

Springt ein Kurs um mehr als 20 % (Krypto 25 %), fragt Watchdog eine zweite Quelle. Bestätigt sie den Kurs, gilt er. Zeigt sie keinen Sprung, wird ihr Kurs verwendet. Kann keine zweite Quelle bestätigen, steht ein „?“ am Kurs und Durchbrüche werden erst mit dem Schlusskurs gemeldet. So löst ein einzelner Fehlkurs keinen Alarm aus.

Watchdog kann nur prüfen, solange er läuft. Damit auch ein ausgeschalteter oder schlafender Mac auffällt, lässt sich unter Einstellungen > Mitteilungen > Lebenszeichen eine Adresse von [healthchecks.io](https://healthchecks.io) (kostenlos) eintragen. Watchdog ruft sie alle 5 Minuten auf; bleibt das aus, schickt healthchecks.io eine Nachricht über ntfy oder E-Mail. Durchbrüche, die in die Zeit fallen, in der der Mac aus war, werden beim nächsten Start nachgemeldet.

## Daten und Sicherung

Das Depot ist eine einzige Datei, standardmäßig `iCloud Drive/Watchdog/Watchdog.json`. Jede Stunde entsteht eine Sicherung im Unterordner `Backups`; wiederherstellen unter Einstellungen > Allgemein. API-Schlüssel und Kurse liegen nur lokal auf dem Mac.

## Für die Weiterentwicklung

- `Core/`: Swift-Paket mit Datenmodell, Datenquellen, Berechnung der Linien, Regeln, Import und Mitteilungen. Läuft auf macOS, iOS, watchOS und Linux und ist mit Tests abgedeckt.
- `App/`: SwiftUI-App für macOS (XcodeGen-Projekt `project.yml`).
- `.github/workflows/`: baut die App in der Cloud, prüft alle Datenquellen live, erstellt Screenshots und die DMG.

Geplant: iPhone, iPad und Apple Watch auf demselben Kern (benötigt ein Apple-Entwicklerkonto), danach eine Windows-Version, die dieselbe Depotdatei liest.

Kurse können verzögert sein. Keine Anlageberatung. Schrift: IBM Plex (SIL Open Font License).
