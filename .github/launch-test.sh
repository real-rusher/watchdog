#!/bin/bash
# Installs released versions like a user would and checks whether macOS starts them.
APP=/Applications/Watchdog.app
install() {
  rm -rf dl && mkdir dl
  gh release download "$1" -p Watchdog.dmg -D dl || { echo "download failed"; return 1; }
  MNT=$(hdiutil attach -nobrowse -readonly dl/Watchdog.dmg | tail -1 | awk -F'\t' '{print $NF}')
  sudo rm -rf "$APP"
  cp -R "$MNT/Watchdog.app" /Applications/
  hdiutil detach "$MNT" -quiet
}
alive() { sleep "$1"; if pgrep -x Watchdog >/dev/null; then echo "   => LÄUFT"; else echo "   => LÄUFT NICHT"; fi; }
stopall() { pkill -x Watchdog; sleep 2; pkill -9 -x Watchdog 2>/dev/null; sleep 1; }
reports() {
  ls -la ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i watchdog
  for f in ~/Library/Logs/DiagnosticReports/*Watchdog* /Library/Logs/DiagnosticReports/*Watchdog*; do
    [ -f "$f" ] || continue
    echo "--- $f"; head -c 6000 "$f"; echo; mv "$f" "$f.seen"
  done
}
syslog() {
  log show --last "$1" --style compact --predicate 'process == "Watchdog" OR ((process == "launchservicesd" OR process == "syspolicyd" OR process == "kernel" OR process == "amfid" OR process == "runningboardd" OR process == "Finder" OR process == "lsd") AND eventMessage CONTAINS[c] "watchdog")' 2>/dev/null | tail -60
}

sw_vers
for V in "$@"; do
  echo; echo "=================== $V"
  install "$V" || continue
  codesign -dvvv "$APP" 2>&1 | grep -E "Identifier|Format|CodeDirectory|Signature|TeamIdentifier|Runtime|flags"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
  spctl -a -vvv "$APP" 2>&1
  file "$APP/Contents/MacOS/Watchdog"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist"

  echo "-- 1) open (LaunchServices, wie Doppelklick im Finder), ohne Quarantäne"
  open "$APP"; echo "   open exit $?"; alive 15
  syslog 1m
  stopall; reports

  echo "-- 2) direkt gestartet, Fehlerausgabe sichtbar"
  "$APP/Contents/MacOS/Watchdog" > run.log 2>&1 &
  PID=$!; alive 15
  kill -0 $PID 2>/dev/null || { wait $PID; echo "   Exit-Code $?"; }
  head -60 run.log
  stopall; reports

done

echo; echo "=================== Update-Fall: $1 gestartet und beendet, dann $2 darüber"
install "$1"
open "$APP"; alive 12; stopall
install "$2"
open "$APP"; echo "   open exit $?"; alive 15
syslog 2m
stopall; reports
