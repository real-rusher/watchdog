#!/bin/bash
# Which situations make macOS show the plain "The application can't be opened." (no choice, Finder icon)?
APP=/Applications/Watchdog.app
mkdir -p out
fresh() {
  sudo rm -rf "$APP"
  [ -d src ] || { gh release download v1.0.8 -p Watchdog.dmg -D dl >/dev/null; MNT=$(hdiutil attach -nobrowse -readonly dl/Watchdog.dmg | tail -1 | awk -F'\t' '{print $NF}'); cp -R "$MNT/Watchdog.app" src.app; hdiutil detach "$MNT" -quiet; mkdir src; }
  cp -R src.app "$APP"
}
quarantine() { xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" "$APP"; }
try() {
  local name="$1"
  echo; echo "================ $name"
  ( osascript -e "tell application \"Finder\" to open POSIX file \"$APP\"" > /dev/null 2>&1 & )
  sleep 7
  screencapture -x "out/$name.png"
  pgrep -x Watchdog >/dev/null && echo "   Prozess vorhanden" || echo "   kein Prozess"
  for p in CoreServicesUIAgent Finder UserNotificationCenter; do
    osascript -e "tell application \"System Events\" to tell process \"$p\" to get value of static texts of every window" 2>/dev/null | grep -v "^$" | head -3 | sed "s/^/   [$p] /"
  done
  log show --last 20s --style compact --predicate 'eventMessage CONTAINS[c] "watchdog" OR process == "syspolicyd"' 2>/dev/null | grep -iE "error|fail|reject|denied|deny|-10[0-9]{3}|-6[0-9]{2}|kill|invalid|launch" | tail -12 | sed 's/^/   log: /'
  # Close whatever dialog is open so the next case starts clean.
  pkill -9 -x Watchdog 2>/dev/null; killall CoreServicesUIAgent 2>/dev/null; killall Finder 2>/dev/null; sleep 3
}
sw_vers | head -2

fresh; try "a-normal-ohne-quarantaene"
fresh; quarantine; try "b-normal-mit-quarantaene"
fresh; chmod -x "$APP/Contents/MacOS/Watchdog"; try "c-nicht-ausfuehrbar"
fresh; chmod -x "$APP/Contents/MacOS/Watchdog"; quarantine; try "d-nicht-ausfuehrbar-quarantaene"
fresh; /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.5x" "$APP/Contents/Info.plist"; try "e-signatur-kaputt"
fresh; /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.5x" "$APP/Contents/Info.plist"; quarantine; try "f-signatur-kaputt-quarantaene"
fresh; printf '\x00' | dd of="$APP/Contents/MacOS/Watchdog" bs=1 seek=50000 conv=notrunc 2>/dev/null; try "g-programmdatei-veraendert"
fresh; sudo chown -R root:wheel "$APP"; sudo chmod -R go-rwx "$APP"; try "h-keine-leserechte"
fresh; quarantine; ( open "$APP" & ); sleep 5; try "i-zweiter-start-waehrend-abfrage"
fresh; xattr -w com.apple.provenance "$(printf '\x01\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00')" "$APP" 2>/dev/null; try "j-provenance"
