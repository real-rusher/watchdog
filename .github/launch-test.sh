#!/bin/bash
# What does macOS show for a downloaded (quarantined) Watchdog? Screenshots of the dialogs plus the system log.
APP=/Applications/Watchdog.app
mkdir -p out
install() {
  rm -rf dl && mkdir dl
  gh release download "$1" -p Watchdog.dmg -D dl || return 1
  xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" dl/Watchdog.dmg
  MNT=$(hdiutil attach -nobrowse -readonly dl/Watchdog.dmg | tail -1 | awk -F'\t' '{print $NF}')
  sudo rm -rf "$APP"
  cp -R "$MNT/Watchdog.app" /Applications/
  hdiutil detach "$MNT" -quiet
  xattr -l "$APP" | head -3
}
sw_vers
echo "== 1) heruntergeladene v1.0.5 öffnen (Quarantäne von der DMG geerbt)"
install v1.0.5
( open "$APP" > out/open1.txt 2>&1 & )
sleep 8; screencapture -x out/dialog-1.png
pgrep -x Watchdog >/dev/null && echo "   => LÄUFT" || echo "   => LÄUFT NICHT"
cat out/open1.txt
osascript -e 'tell application "System Events" to get name of every process whose visible is true' 2>&1 | head -3
osascript -e 'tell application "System Events" to tell process "CoreServicesUIAgent" to get value of static texts of window 1' 2>&1 | head -5
log show --last 1m --style compact --predicate 'process == "syspolicyd" OR process == "CoreServicesUIAgent" OR (process == "launchservicesd" AND eventMessage CONTAINS[c] "watchdog")' 2>/dev/null | grep -iE "watchdog|assess|gatekeeper|deny|reject|prompt|malware|notar|adhoc|ad-hoc" | tail -40
osascript -e 'tell application "System Events" to tell process "CoreServicesUIAgent" to click button 1 of window 1' 2>&1 | head -2
sleep 2; pkill -x Watchdog

echo "== 2) Freigabe wie über Datenschutz & Sicherheit simulieren, dann öffnen"
sudo xattr -d com.apple.quarantine "$APP"
( open "$APP" & ); sleep 10
pgrep -x Watchdog >/dev/null && echo "   => LÄUFT" || echo "   => LÄUFT NICHT"
screencapture -x out/dialog-2.png
pkill -x Watchdog; sleep 2

echo "== 3) v1.0.5 noch einmal heruntergeladen über die freigegebene Kopie gelegt"
install v1.0.5
( open "$APP" > out/open3.txt 2>&1 & )
sleep 8; screencapture -x out/dialog-3.png
pgrep -x Watchdog >/dev/null && echo "   => LÄUFT" || echo "   => LÄUFT NICHT"
osascript -e 'tell application "System Events" to tell process "CoreServicesUIAgent" to get value of static texts of window 1' 2>&1 | head -5
log show --last 1m --style compact --predicate 'process == "syspolicyd" OR process == "CoreServicesUIAgent"' 2>/dev/null | grep -iE "watchdog|assess|deny|reject|prompt|malware|notar" | tail -30
