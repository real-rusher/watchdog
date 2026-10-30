#!/bin/bash
# Bringt die Watchdog-App auf das angeschlossene iPhone und die gekoppelte Apple Watch.
# Mit einer kostenlosen Apple-ID laufen selbst installierte Apps 7 Tage; danach dieses Skript einfach noch einmal starten.
# Holt jedes Mal den neuesten Stand von GitHub, baut ihn mit Xcode und installiert ihn. Ändert nichts außerhalb von
# ~/Library/Caches/Watchdog-iPhone.

REPO="real-rusher/watchdog"
WORK="$HOME/Library/Caches/Watchdog-iPhone"
CI_MODE="${WATCHDOG_CI:-0}"   # nur für den Test in der Cloud: ohne iPhone, ohne Signatur

say()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
fail() {
    printf "\n\033[1;31mAbgebrochen:\033[0m %s\n" "$*"
    [ -f "$WORK/build.log" ] && printf "\nDie letzten Zeilen des Bauprotokolls (%s):\n" "$WORK/build.log" && grep -E "error:|warning: .*provision|Signing" "$WORK/build.log" | tail -15
    [ "$CI_MODE" = "1" ] || { printf "\nZum Schließen eine Taste drücken."; read -r -n 1; }
    exit 1
}
json() { # json DATEI JS-AUSDRUCK(d)  wertet JSON ohne Zusatzprogramme mit JavaScript von macOS aus
    /usr/bin/osascript -l JavaScript -e "
        ObjC.import('Foundation');
        var t = $.NSString.stringWithContentsOfFileEncodingError('$1', $.NSUTF8StringEncoding, null).js;
        var d = JSON.parse(t); var r = ($2); (r === undefined || r === null) ? '' : String(r);" 2>/dev/null
}

# Team-ID der in Xcode angemeldeten Apple-ID, auf mehreren Wegen, weil Xcode-Versionen sie unterschiedlich ablegen.
find_team() {
    local t=""
    # a) Schon einmal eingegeben oder gefunden.
    [ -f "$WORK/team" ] && t=$(cat "$WORK/team")
    # b) Xcode-Einstellungen: jedes Objekt mit einer Team-ID, egal unter welchem Schlüssel; das persönliche Team zuerst.
    if [ -z "$t" ]; then
        t=$(/usr/bin/osascript -l JavaScript -e "
            ObjC.import('Foundation');
            var found = [];
            function walk(o, depth) {
                if (!o || typeof o !== 'object' || depth > 12) return;
                if (Array.isArray(o)) { o.forEach(function (x) { walk(x, depth + 1); }); return; }
                var id = o.teamID || o.TeamID || o.teamIdentifier;
                if (typeof id === 'string' && /^[A-Z0-9]{10}$/.test(id)) found.push(o);
                Object.keys(o).forEach(function (k) { try { walk(o[k], depth + 1); } catch (e) {} });
            }
            ['com.apple.dt.Xcode', 'com.apple.dt.xcodebuild'].forEach(function (s) {
                try { walk(ObjC.deepUnwrap($.NSUserDefaults.standardUserDefaults.persistentDomainForName(s)), 0); } catch (e) {}
            });
            var personal = found.filter(function (x) {
                return x.isFreeProvisioningTeam || x.teamType === 'Personal' || /personal/i.test(String(x.teamName || x.name || ''));
            });
            var pick = personal[0] || found[0] || {};
            pick.teamID || pick.TeamID || pick.teamIdentifier || '';" 2>/dev/null)
    fi
    # c) Entwicklerzertifikat im Schlüsselbund: die Team-ID steht im Feld OU.
    if [ -z "$t" ]; then
        rm -rf "$WORK/certs" && mkdir -p "$WORK/certs"
        security find-certificate -a -c "Apple Development" -p 2>/dev/null \
            | awk -v dir="$WORK/certs" '/BEGIN CERTIFICATE/{n++} n{print > (dir "/c" n ".pem")}'
        for f in "$WORK/certs/"c*.pem; do
            [ -f "$f" ] || continue
            t=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')
            [ -n "$t" ] && break
        done
    fi
    # d) Vorhandene Bereitstellungsprofile.
    if [ -z "$t" ]; then
        for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
                 "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision; do
            [ -f "$f" ] || continue
            t=$(security cms -D -i "$f" 2>/dev/null | plutil -extract TeamIdentifier.0 raw - 2>/dev/null)
            [ -n "$t" ] && break
        done
    fi
    [[ "$t" =~ ^[A-Z0-9]{10}$ ]] && { printf "%s" "$t" > "$WORK/team"; printf "%s" "$t"; }
}

clear
say "Watchdog auf iPhone und Apple Watch bringen"
mkdir -p "$WORK" || fail "Ordner $WORK lässt sich nicht anlegen."

# 1. Xcode
if [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
xcodebuild -version >/dev/null 2>&1 || fail "Xcode wurde nicht gefunden oder noch nie gestartet. Bitte Xcode einmal öffnen, die Lizenz bestätigen und die Zusatzkomponenten installieren lassen."
echo "$(xcodebuild -version | head -1) gefunden."

TEAM="" ; DEVICE="" ; UDID="" ; NAME="" ; WATCHDEV=""
if [ "$CI_MODE" != "1" ]; then
    # 2. Persönliches Team der in Xcode angemeldeten Apple-ID
    say "Apple-ID in Xcode suchen"
    TEAM=$(find_team)
    if [ -z "$TEAM" ]; then
        echo "Die Team-ID ließ sich nicht von selbst finden (je nach Xcode-Version liegt sie an anderer Stelle)."
        echo "Sie steht unter https://developer.apple.com/account > Mitgliedschaft (Membership details) > Team-ID,"
        echo "nach der Anmeldung mit derselben Apple-ID wie in Xcode. Sie hat 10 Zeichen, zum Beispiel A1B2C3D4E5."
        printf "Team-ID eingeben und Return drücken: "
        read -r TEAM
        TEAM=$(printf "%s" "$TEAM" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
        [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail "Das ist keine gültige Team-ID (10 Buchstaben und Ziffern)."
        printf "%s" "$TEAM" > "$WORK/team"
    fi
    echo "Team $TEAM."

    # 3. Angeschlossenes iPhone
    say "iPhone suchen"
    xcrun devicectl list devices --json-output "$WORK/devices.json" >/dev/null 2>&1
    PICK="(function () {
        var l = ((d.result || {}).devices || []).filter(function (x) {
            var h = x.hardwareProperties || {}, c = x.connectionProperties || {};
            return h.platform === 'iOS' && h.deviceType === 'iPhone' && c.pairingState === 'paired' && c.tunnelState !== 'unavailable';
        });
        return l[0];
    })()"
    DEVICE=$(json "$WORK/devices.json" "($PICK || {}).identifier")
    UDID=$(json "$WORK/devices.json" "(($PICK || {}).hardwareProperties || {}).udid")
    NAME=$(json "$WORK/devices.json" "(($PICK || {}).deviceProperties || {}).name")
    DEVMODE=$(json "$WORK/devices.json" "(($PICK || {}).deviceProperties || {}).developerModeStatus")
    [ -n "$DEVICE" ] || fail "Kein iPhone gefunden. iPhone per Kabel anschließen, entsperren und bei \"Diesem Computer vertrauen?\" auf Vertrauen tippen. Dann erneut starten."
    echo "$NAME gefunden."
    if [ "$DEVMODE" = "disabled" ]; then
        fail "Auf dem iPhone ist der Entwicklermodus aus. Einstellungen > Datenschutz & Sicherheit > Entwicklermodus einschalten, iPhone neu starten, nach dem Neustart \"Einschalten\" bestätigen. Dann erneut starten."
    fi

    # Sieht Xcode die gekoppelte Watch, und ist ihr Entwicklermodus an? Ohne beides lässt sich die Watch-App nicht signieren.
    say "Apple Watch prüfen"
    WSTATE=$(json "$WORK/devices.json" "(function () {
        var w = ((d.result || {}).devices || []).filter(function (x) { return (x.hardwareProperties || {}).platform === 'watchOS'; })[0];
        if (!w) return 'none';
        var c = w.connectionProperties || {}, p = w.deviceProperties || {};
        return [p.name || 'Apple Watch', c.pairingState || '?', c.tunnelState || '?', p.developerModeStatus || '?'].join('|');
    })()")
    if [ "$WSTATE" = "none" ] || [ -z "$WSTATE" ]; then
        echo "Xcode sieht keine Apple Watch. Die iPhone-App wird trotzdem installiert; für die Watch einmalig:"
        echo "  Mac, iPhone und Watch im selben WLAN, Bluetooth an, kein VPN. Watch entsperrt am Handgelenk."
        echo "  Xcode > Window > Devices and Simulators (Umschalt+Befehl+2) > Devices, iPhone links anklicken"
        echo "  und warten, bis die Watch erscheint und vorbereitet ist. Auf der Watch \"Vertrauen\" bestätigen."
    else
        IFS='|' read -r WN WPAIR WTUN WDEV <<< "$WSTATE"
        echo "$WN: Kopplung $WPAIR, Verbindung $WTUN, Entwicklermodus $WDEV."
        if [ "$WDEV" = "disabled" ]; then
            echo "Auf der Watch: Einstellungen > Datenschutz & Sicherheit > ganz unten Entwicklermodus einschalten, Neustart, bestätigen."
        elif [ "$WPAIR" != "paired" ]; then
            echo "Xcode kennt die Watch, ist aber noch nicht mit ihr verbunden: in Xcode > Window > Devices and Simulators die Watch anklicken"
            echo "und auf der Watch \"Vertrauen\" bestätigen; dann ist sie vorbereitet und der Entwicklermodus erscheint."
        fi
    fi
fi

# 4. Neuesten Stand holen
say "Neuesten Stand von GitHub laden"
rm -rf "$WORK/src" && mkdir -p "$WORK/src"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar xz -C "$WORK/src" --strip-components 1 \
    || fail "Download von GitHub fehlgeschlagen. Internetverbindung prüfen."
VERSION=$(grep -m1 MARKETING_VERSION "$WORK/src/App/project.yml" | tr -dc '0-9.')
echo "Watchdog $VERSION."

if [ ! -x "$WORK/tools/xcodegen/bin/xcodegen" ]; then
    say "XcodeGen laden (einmalig)"
    rm -rf "$WORK/tools" && mkdir -p "$WORK/tools"
    curl -fsSL -o "$WORK/tools/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip" \
        && (cd "$WORK/tools" && unzip -q xcodegen.zip) || fail "XcodeGen ließ sich nicht laden."
fi

# 5. Projekt für diese Apple-ID erzeugen. Eine kostenlose Apple-ID braucht eigene App-Kennungen; die Kennungen
#    der späteren Veröffentlichung (de.realrusher.watchdog) bleiben so für das Konto des Kunden frei.
say "Projekt vorbereiten"
SUFFIX=$(printf "%s" "${TEAM:-ci}" | tr '[:upper:]' '[:lower:]')
sed -i '' "s/de\.realrusher\.watchdog/de.realrusher.wd-$SUFFIX/g" "$WORK/src/App/project.yml"
(cd "$WORK/src/App" && "$WORK/tools/xcodegen/bin/xcodegen" generate --quiet) || fail "Das Projekt ließ sich nicht erzeugen."

# 6. Bauen und signieren
say "App bauen (beim ersten Mal einige Minuten)"
if [ "$CI_MODE" = "1" ]; then
    xcodebuild -project "$WORK/src/App/Watchdog.xcodeproj" -scheme WatchdogMobile -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$WORK/build" CODE_SIGNING_ALLOWED=NO build > "$WORK/build.log" 2>&1 \
        || fail "Der Bau ist fehlgeschlagen."
    ls -d "$WORK"/build/Build/Products/Release-iphoneos/Watchdog.app "$WORK"/build/Build/Products/Release-iphoneos/Watchdog.app/Watch/*.app
    say "Fertig (Test ohne iPhone)."
    exit 0
fi
echo "Fragt der Mac nach dem Schlüsselbund-Passwort für \"codesign\": Anmeldepasswort des Macs eingeben und \"Immer erlauben\" wählen."
build_app() {
    xcodebuild -project "$WORK/src/App/Watchdog.xcodeproj" -scheme WatchdogMobile -configuration Release \
        -destination "id=$UDID" -derivedDataPath "$WORK/build" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
        build > "$WORK/build.log" 2>&1
}
WITHOUT_WATCH=0
if ! build_app; then
    # Die Watch-App lässt sich erst signieren, wenn die Watch für die Entwicklung freigegeben ist. Dann wenigstens das iPhone.
    if grep -E "error:" "$WORK/build.log" | grep -qiE "watch|WatchdogWatch|WatchdogComplication"; then
        say "Die Watch-App ließ sich noch nicht signieren, ich baue ohne Watch weiter"
        echo "Grund laut Xcode:"
        grep -E "error:" "$WORK/build.log" | grep -iE "watch|provision|device|signing" | sed 's/^.*error: /  /' | sort -u | head -4
        sed -i '' '/^  WatchdogMobile:/,/^  WatchdogWatch:/{/      - target: WatchdogWatch/d;}' "$WORK/src/App/project.yml"
        (cd "$WORK/src/App" && "$WORK/tools/xcodegen/bin/xcodegen" generate --quiet) || fail "Das Projekt ließ sich nicht erzeugen."
        build_app || fail "Der Bau ist fehlgeschlagen."
        WITHOUT_WATCH=1
    else
        fail "Der Bau ist fehlgeschlagen."
    fi
fi
APP="$WORK/build/Build/Products/Release-iphoneos/Watchdog.app"
[ -d "$APP" ] || fail "Die gebaute App wurde nicht gefunden."

# 7. Installieren
say "Auf $NAME installieren"
xcrun devicectl device install app --device "$DEVICE" "$APP" > "$WORK/install.log" 2>&1 \
    || { cat "$WORK/install.log" | tail -5; fail "Die Installation ist fehlgeschlagen. iPhone entsperrt lassen und erneut versuchen."; }
BUNDLE="de.realrusher.wd-$SUFFIX"
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" > "$WORK/launch.log" 2>&1; then
    say "Einmal noch auf dem iPhone bestätigen"
    echo "Einstellungen > Allgemein > VPN & Geräteverwaltung > Entwickler-App ($TEAM) > \"Vertrauen\"."
    echo "Danach Watchdog auf dem iPhone öffnen. Das ist nur beim ersten Mal nötig."
fi

# 8. Watch-App direkt auf die Uhr (zuverlässiger als auf "Verfügbare Apps" in der Watch-App zu warten)
WATCH_DONE=0
if [ "$WITHOUT_WATCH" = "0" ] && [ -d "$APP/Watch/Watchdog.app" ]; then
    say "Apple Watch suchen"
    xcrun devicectl list devices --json-output "$WORK/devices.json" >/dev/null 2>&1
    WPICK="(function () {
        var l = ((d.result || {}).devices || []).filter(function (x) {
            var h = x.hardwareProperties || {}, c = x.connectionProperties || {};
            return h.platform === 'watchOS' && c.pairingState === 'paired';
        });
        return l[0];
    })()"
    WATCHDEV=$(json "$WORK/devices.json" "($WPICK || {}).identifier")
    WNAME=$(json "$WORK/devices.json" "(($WPICK || {}).deviceProperties || {}).name")
    if [ -n "$WATCHDEV" ]; then
        echo "$WNAME gefunden, Watch-App wird installiert (Watch entsperrt am Handgelenk lassen, das dauert etwas)."
        if xcrun devicectl device install app --device "$WATCHDEV" "$APP/Watch/Watchdog.app" > "$WORK/install-watch.log" 2>&1; then
            WATCH_DONE=1
        else
            tail -3 "$WORK/install-watch.log"
        fi
    fi
fi

say "Fertig: Watchdog $VERSION ist auf $NAME."
if [ "$WATCH_DONE" = "1" ]; then
    echo "Die Watch-App ist auf $WNAME."
elif [ "$WITHOUT_WATCH" = "1" ] || [ -z "$WATCHDEV" ]; then
    echo "Diesmal ohne Watch-App: Xcode kennt die Watch noch nicht als Entwicklungsgerät. So geht es einmalig:"
    echo "  1. Xcode nach vorne holen, im Menü Window > Devices and Simulators (Umschalt+Befehl+2), oben \"Devices\"."
    echo "  2. iPhone am Kabel und entsperrt, Watch entsperrt am Handgelenk. Warten, bis die Watch links erscheint und fertig vorbereitet ist."
    echo "  3. Auf der Watch: Einstellungen > Datenschutz & Sicherheit > Entwicklermodus einschalten, Neustart, bestätigen."
    echo "  4. Dieses Skript noch einmal starten."
else
echo "Die Watch-App kommt von selbst auf die gekoppelte Apple Watch, wenn in der Watch-App des iPhones"
echo "\"Apps automatisch installieren\" an ist (sonst dort unter \"Verfügbare Apps\" Watchdog installieren)."
echo "Auf der Watch beim ersten Mal: Einstellungen > Datenschutz & Sicherheit > Entwicklermodus einschalten."
fi
echo
echo "Gültig bis etwa $(date -v+7d '+%d.%m.%Y'). Dann dieses Skript wieder starten; Depot und Einstellungen bleiben erhalten."
printf "\nZum Schließen eine Taste drücken."
read -r -n 1
