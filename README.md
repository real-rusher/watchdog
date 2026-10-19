# Watchdog

Musterdepot für den Mac, das alle Aktien aus mehreren Depots in einer Tabelle bündelt und für jeden Wert zeigt, ob der Kurs über oder unter seiner 200-Tage-Linie steht. Bricht ein Wert durch die Linie, meldet sich Watchdog auf dem Mac und auf Wunsch auf iPhone und Apple Watch.

Reine Ansicht: kein Handel, keine Nachrichten, keine Verbindung zu Banken. Alles wird von Hand gepflegt oder per Liste importiert.

## Installation

1. Unter [Releases](../../releases/tag/nightly) die Datei `Watchdog.dmg` laden und öffnen.
2. Watchdog in den Ordner „Programme“ ziehen.
3. Watchdog per Doppelklick starten. macOS meldet beim ersten Mal, dass die App nicht geprüft werden kann (sie ist noch nicht bei Apple signiert). Dann:
   **Systemeinstellungen > Datenschutz & Sicherheit**, ganz unten bei „Watchdog wurde blockiert“ auf **Dennoch öffnen** klicken und bestätigen. Das ist nur einmal nötig.
4. Beim ersten Start fragt macOS, ob Watchdog Mitteilungen senden und auf iCloud Drive zugreifen darf. Beides erlauben.

Voraussetzung: macOS 14 Sonoma oder neuer, Apple-Silicon- oder Intel-Mac.

## Erste Schritte

- **Beispieldepot ansehen**: zeigt die App mit echten Kursen, ohne etwas einzutragen.
- **Wertpapier hinzufügen** (⌘N): ISIN, WKN, Name oder Kürzel eintippen, Börse aus der Trefferliste wählen, Käufe mit Datum, Stück und Preis in Euro eintragen. Ohne Kauf wird der Wert nur beobachtet.
- **Importieren** (⌘I): CSV-Datei öffnen oder eine Tabelle aus Excel/Numbers kopieren und einfügen. Spalten wie Name, ISIN, Stück, Kaufkurs, Kaufdatum, Börse, Bank und Thema werden automatisch erkannt.
- Oben links umschalten zwischen **Banken**, **Themen** (z. B. Uran, Öl, Gold) und **Liste**.

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

## Daten und Sicherung

Das Depot ist eine einzige Datei, standardmäßig `iCloud Drive/Watchdog/Watchdog.json`. Jede Stunde entsteht eine Sicherung im Unterordner `Backups`; wiederherstellen unter Einstellungen > Allgemein. API-Schlüssel und Kurse liegen nur lokal auf dem Mac.

## Für die Weiterentwicklung

- `Core/`: Swift-Paket mit Datenmodell, Datenquellen, Berechnung der Linien, Regeln, Import und Mitteilungen. Läuft auf macOS, iOS, watchOS und Linux und ist mit Tests abgedeckt.
- `App/`: SwiftUI-App für macOS (XcodeGen-Projekt `project.yml`).
- `.github/workflows/`: baut die App in der Cloud, prüft alle Datenquellen live, erstellt Screenshots und die DMG.

Geplant: iPhone, iPad und Apple Watch auf demselben Kern (benötigt ein Apple-Entwicklerkonto), danach eine Windows-Version, die dieselbe Depotdatei liest.

Kurse können verzögert sein. Keine Anlageberatung. Schrift: IBM Plex (SIL Open Font License).
