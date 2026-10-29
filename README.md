# Watchdog

Musterdepot für den Mac, das alle Aktien aus mehreren Depots in einer Tabelle bündelt und für jeden Wert zeigt, ob der Kurs über oder unter seiner 200-Tage-Linie steht. Bricht ein Wert durch die Linie, meldet sich Watchdog auf dem Mac und auf Wunsch auf iPhone und Apple Watch.

Reine Ansicht: kein Handel, keine Nachrichten, keine Verbindung zu Banken. Alles wird von Hand gepflegt oder per Liste importiert.

## Installation

1. Unter [Releases](../../releases/latest) die Datei `Watchdog.dmg` laden und öffnen.
2. Watchdog in den Ordner „Programme“ ziehen.
3. Watchdog per Doppelklick starten. macOS meldet beim ersten Mal, dass die App nicht geprüft werden kann (sie ist noch nicht bei Apple signiert). Dann:
   **Systemeinstellungen > Datenschutz & Sicherheit**, ganz unten bei „Watchdog wurde blockiert“ auf **Dennoch öffnen** klicken und bestätigen. Das ist nach jeder neuen Version noch einmal nötig, weil jede Version neu signiert ist; der Knopf erscheint nur in der ersten Stunde nach dem Öffnungsversuch.
   Vor dem Ersetzen einer alten Version Watchdog beenden (Menüleiste > Watchdog-Symbol > Ausschalt-Knopf), denn Watchdog läuft auch bei geschlossenem Fenster in der Menüleiste weiter.
4. Beim ersten Start fragt macOS, ob Watchdog Mitteilungen senden und auf iCloud Drive zugreifen darf. Beides erlauben.

Voraussetzung: macOS 14 Sonoma oder neuer, Apple-Silicon- oder Intel-Mac.

## Erste Schritte

- **Beispieldepot ansehen**: zeigt die App mit echten Kursen, ohne etwas einzutragen.
- **Wertpapier hinzufügen** (⌘N): ISIN, WKN, Name oder Kürzel eintippen, Börse aus der Trefferliste wählen, Käufe mit Datum, Stück und Preis in Euro eintragen. Ohne Kauf wird der Wert nur beobachtet.
- **Importieren** (⌘I): Datei in das Fenster ziehen oder öffnen, oder eine Tabelle aus Excel/Numbers kopieren und einfügen. Mehr dazu unter „Import“.
- Oben links umschalten zwischen **Banken**, **Themen** (z. B. Uran, Öl, Gold) und **Liste**.
- **Löschen**: Rechtsklick auf einen Wert > Löschen. Mehrere Werte mit ⌘-Klick oder ⇧-Klick auswählen und die Rückschritttaste drücken; Rechtsklick auf eine Bank oder ein Thema löscht die ganze Gruppe. **Alle Werte entfernen** (Menü Depot oder Einstellungen > Allgemein) leert das Depot, Einstellungen und der iPhone-Kanal bleiben. Jedes Löschen lässt sich direkt danach mit **Rückgängig** zurücknehmen, vorher wird eine Sicherung angelegt.

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
- **iPhone und Apple Watch über ntfy**: Einstellungen > Mitteilungen > „Mitteilungen an ntfy senden“ einschalten, auf dem iPhone die kostenlose App **ntfy** installieren und den angezeigten Kanal abonnieren (QR-Code scannen). Was auf dem iPhone ankommt, zeigt auch die Watch. Der Titel sagt kurz, was passiert ist („Cameco: fällt unter die 200-Tage-Linie“), damit er auf der Watch ganz lesbar ist.
- **Watchdog-Apps für iPhone, iPad und Apple Watch**: vorbereitet, siehe unten. Sie lassen sich erst mit einem Apple-Entwicklerkonto auf echte Geräte bringen.

### Wer prüft und meldet

Mac, iPhone und Watch prüfen jeweils selbst, gemeldet wird aber nur einmal und in dieser Reihenfolge:

1. **Mac**: prüft und meldet, solange er läuft.
2. **iPhone**: meldet erst, wenn der Mac 20 Minuten lang nicht geprüft hat (ausgeschaltet, Ruhezustand, kein Internet) oder kaum noch Kurse bekommt.
3. **Apple Watch**: meldet erst, wenn auch das iPhone 20 Minuten lang nicht geprüft hat.

Dazu liegt neben der Depotdatei in iCloud Drive die kleine Datei `Mitteilungen.json` (das Meldebuch). Jedes Gerät trägt dort ein, wann es zuletzt geprüft hat und welche Durchbrüche es gemeldet hat. Was ein Gerät gemeldet hat, meldet kein anderes noch einmal, auch nicht über ntfy. Ein Durchbruch, den das zuständige Gerät verpasst hat, meldet das nächste innerhalb eines Tages nach. Unter Einstellungen > Mitteilungen steht, welches Gerät gerade meldet.

Grenzen: Im Hintergrund dürfen iPhone und Watch nur prüfen, wenn iOS bzw. watchOS sie weckt, mal alle 15 Minuten, mal seltener. Die Watch erfährt vom iPhone, ob Mac und iPhone prüfen; ist das iPhone lange nicht erreichbar, prüft die Watch vorsichtshalber selbst, dann kann eine Meldung doppelt kommen.

## iPhone, iPad und Apple Watch

Die Apps sind gebaut und im Simulator getestet. Auf echte Geräte kommen sie erst mit einem Apple-Entwicklerkonto (99 € im Jahr, über TestFlight oder den App Store).

- **iPhone und iPad**: zeigen dasselbe Depot wie der Mac, mit Gruppen (Banken, Themen, Liste), Ampel, Abstand zur Linie, Kurs, Heute, Wert, Seit Kauf, Seit 1.1. und 30 Tage (auf schmalen iPhones nur die wichtigsten Spalten), Detail mit Chart, 38- und 200-Tage-Linie und Käufen. Angelegt und bearbeitet wird am Mac. Beim ersten Start einmal den Ordner „Watchdog“ in iCloud Drive auswählen. Die Schrift folgt der Einstellung „Größerer Text“.
- **Apple Watch**: Liste der Werte, die Werte unter der Linie und die frisch gekreuzten zuerst, mit Abstand und Kurs. Dazu eine Komplikation für das Zifferblatt mit der Zahl der Werte unter der Linie. Die Watch bekommt die Daten vom iPhone. Prüft sie selbst, holt sie nur den aktuellen Kurs der Werte nahe an der Linie und vergleicht ihn mit der Linie vom iPhone; das schont den Akku.
- **Vorab ohne Entwicklerkonto auf das eigene iPhone**: `tools/Watchdog-auf-iPhone.zip` laden, entpacken, iPhone per Kabel anschließen und `Watchdog-auf-iPhone.command` per Doppelklick starten (beim ersten Mal unter Systemeinstellungen > Datenschutz & Sicherheit auf „Dennoch öffnen“ klicken). Voraussetzung: Xcode ist installiert und in Xcode > Einstellungen > Accounts eine Apple-ID angemeldet. Das Skript holt den neuesten Stand, baut ihn und installiert iPhone- und Watch-App. Mit einer kostenlosen Apple-ID laufen die Apps 7 Tage; danach das Skript erneut starten, Depot und Einstellungen bleiben erhalten. Beim ersten Mal auf iPhone und Watch den Entwicklermodus einschalten und auf dem iPhone unter Allgemein > VPN & Geräteverwaltung dem Entwickler vertrauen; das Skript sagt jeweils, was fehlt.
- **ntfy und die App**: Ist die iPhone-App installiert, kann unter Einstellungen > Mitteilungen eingeschaltet werden, dass ein Tippen auf die ntfy-Meldung den Wert in der App öffnet.

## Kursdaten

Standard ist Yahoo Finance. Fällt Yahoo aus, drosselt oder liefert nur einen alten Stand, nimmt Watchdog automatisch die nächste Quelle: OnVista (Tradegate, gettex, LS Exchange und weitere), Financial Times (Tokio, Australien, Kanada, Skandinavien und weitere), Lang & Schwarz, Tradegate, Bitfinex. Mit eigenem API-Schlüssel zusätzlich EODHD, Twelve Data, Alpha Vantage und Finnhub. Reihenfolge und erste Quelle lassen sich in der Symbolleiste und unter Einstellungen > Datenquellen ändern.

Die Kurse sind echte Börsenkurse, aber keine Echtzeitkurse: je nach Börse und Quelle 15 bis 20 Minuten verzögert, bei der Financial Times nur Schlusskurse.

### Immer der neueste verfügbare Kurs

- Eine Antwort gilt nur dann als aktuell, wenn sie zur Handelszeit der Börse passt: während des Handels höchstens 45 Minuten alt, nach Handelsschluss der Schlusskurs des letzten Handelstags. Beim Kursverlauf muss der letzte abgeschlossene Handelstag enthalten sein.
- Liefert eine Quelle nur einen älteren Stand, fragt Watchdog die weiteren Quellen und nimmt den neuesten Kurs, den irgendeine Quelle hat. Ist die Nasdaq zum Beispiel geschlossen, ist das der Schlusskurs von 16:00 Uhr New York, auch wenn die erste Quelle noch einen Kurs von vor einer Woche meldet.
- Ein schon angezeigter neuerer Kurs wird nie durch einen älteren ersetzt.
- Hat nach Handelsschluss keine Quelle etwas Neueres, fragt Watchdog bis zum nächsten Handelstag nicht ständig nach.

### Richtiges Kürzel und richtige Firma

- Yahoo, OnVista und die Financial Times melden zu jedem Kurs den Firmennamen. Watchdog vergleicht ihn mit dem Namen des Werts. Gehört die Antwort zu einer anderen Firma, werden Kurs und Verlauf nicht verwendet, und schon gespeicherte Daten dieser Quelle werden verworfen.
- Watchdog sucht dann über die ISIN das richtige Kürzel an der gewählten Börse, übernimmt es ins Depot und lädt Kurs und Verlauf neu. In der Zeile steht eine Woche lang „Kürzel korrigiert“, in der Detailansicht und im Tooltip, was gefunden wurde.
- Ohne ISIN lässt sich das richtige Kürzel nicht von selbst finden; der Hinweis sagt das dann. Wird die ISIN (oder WKN oder der Name) beim Bearbeiten nachgetragen, sucht Watchdog sofort neu. Alternativ die Börse neu auswählen.
- Lässt sich kein passendes Kürzel finden, steht in der Zeile „Kürzel prüfen“. Der Wert hat dann keinen Kurs und zählt nicht zum Depotwert, bis echte Kurse kommen; die Käufe bleiben erhalten. So geschieht es zum Beispiel bei einem vom Handel ausgesetzten Wert, dessen Kürzel inzwischen zu einer anderen Firma gehört.
- Weichen nur die Namen ab und führt die ISIN genau zu diesem Kürzel (zum Beispiel „Google“ und „Alphabet Inc.“), steht „Name prüfen“ in der Zeile. Erst nach einem Klick auf **Ist dieselbe Firma** in der Detailansicht werden die Daten verwendet. Die Bestätigung wird im Depot gespeichert und gilt dauerhaft.
- Werte an ausländischen Börsen bekommen das Kürzel dieser Börse, zum Beispiel ALCO für Alico an der Nasdaq statt des deutschen Kürzels AOE. Das geschieht beim ersten Abruf nach dem Import oder nach dem Update von selbst; Käufe, Gruppen und Notizen bleiben unverändert.
- Der Import übernimmt keinen Treffer, dessen Firmenname nicht zum Namen in der Datei passt. Die Zeile zeigt dann „Name passt nicht zum Treffer“ und den gefundenen Namen; der Wert lässt sich von Hand hinzufügen.

### Umrechnung in Euro

- **Heutige Werte** (Kurs, Wert, Depotwert) werden mit dem aktuellen Devisenkurs umgerechnet, so wie Google oder Yahoo. Ist er nicht abrufbar, gilt der EZB-Referenzkurs; welcher Kurs verwendet wurde, steht in der Detailansicht und im Tooltip der Tabelle.
- **Vergangene Tage** (Chart, „Seit 1.1.“, „30 Tage“, Kaufpreise in Fremdwährung) werden mit dem EZB-Referenzkurs genau dieses Tages umgerechnet.
- **Chart**: Umschalter „in Euro“ und „in Yen“ (bzw. der jeweiligen Börsenwährung). In Börsenwährung sieht der Chart genau so aus wie an der Börse. Die 200-Tage-Linie wird in der Börsenwährung berechnet; in der Euro-Ansicht wird sie mit demselben Tageskurs umgerechnet wie der Kurs, damit Durchbrüche genau dort liegen, wo sie an der Börse passieren.
- Die eigene Bank rechnet mit ihrem Kurs und Aufschlag; Euro-Werte können deshalb um wenige Zehntelprozent von der Bank abweichen.

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
- `App/`: SwiftUI-Apps (XcodeGen-Projekt `project.yml`): `Watchdog` für den Mac, `Mobile` für iPhone und iPad, `WatchApp` und `WatchComplication` für die Apple Watch, `Shared` mit Farben, Schrift, Chart und Ampel für alle.
- `.github/workflows/`: baut die Apps in der Cloud, prüft alle Datenquellen live, erstellt Screenshots (Mac, iPhone, iPad, Watch im Simulator) und die DMG.
- **Versteckter Test für Mitteilungen**: Wahltaste ⌥ gedrückt halten und dabei das Menü „Depot“ öffnen. Ganz unten erscheint „Beispielmitteilung an Mac, iPhone und Watch senden“. Die Mitteilung sieht aus wie ein echter Alarm mit einem Wert aus dem Depot, beginnt aber mit „TEST“, geht als Banner auf den Mac und über ntfy an iPhone und Watch und wird nicht ins Meldebuch eingetragen.

Geplant: Installation der iPhone-, iPad- und Watch-Apps, sobald es ein Apple-Entwicklerkonto gibt, danach eine Windows-Version, die dieselbe Depotdatei liest.

Kurse können verzögert sein. Keine Anlageberatung. Schrift: IBM Plex (SIL Open Font License).
