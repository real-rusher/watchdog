#!/bin/bash
# Screenshots of the iPhone, iPad and Watch apps in the simulators. The apps run with --demo:
# example depot, live prices, no iCloud and no notifications.
set -u
mkdir -p out/ios out/ipad out/watch
P=build/m/Build/Products
IOS_APP="$P/Debug-iphonesimulator/Watchdog.app"
WATCH_APP="$P/Debug-watchsimulator/Watchdog.app"
ID=de.realrusher.watchdog
WID=de.realrusher.watchdog.watchkitapp

pick() { # newest available device whose name starts with $1
  xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
best=None
for rt,devs in d.items():
    for x in devs:
        if x['name'].startswith('$1'): best=(rt,x['udid'],x['name'])
print(best[1] if best else '')
"
}

shot() { xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1 && echo "shot $2" || echo "no shot $2"; }

run() { # udid bundle wait args...
  local u=$1 b=$2 w=$3; shift 3
  xcrun simctl terminate "$u" "$b" >/dev/null 2>&1
  xcrun simctl launch "$u" "$b" "$@" && sleep "$w"
}

IPHONE=$(pick "iPhone 16 Pro")
[ -z "$IPHONE" ] && IPHONE=$(pick "iPhone")
echo "iPhone $IPHONE"
xcrun simctl boot "$IPHONE"; xcrun simctl bootstatus "$IPHONE" -b >/dev/null
xcrun simctl status_bar "$IPHONE" override --time "9:41" --batteryState charged --batteryLevel 100 >/dev/null 2>&1
xcrun simctl install "$IPHONE" "$IOS_APP" && echo installed
xcrun simctl ui "$IPHONE" appearance light
run "$IPHONE" $ID 75 --demo
shot "$IPHONE" out/ios/1-list-light.png
xcrun simctl ui "$IPHONE" appearance dark; sleep 3
shot "$IPHONE" out/ios/2-list-dark.png
run "$IPHONE" $ID 25 --demo --open-first
shot "$IPHONE" out/ios/3-detail-dark.png
xcrun simctl ui "$IPHONE" appearance light; sleep 3
shot "$IPHONE" out/ios/4-detail-light.png
run "$IPHONE" $ID 25 --demo --grouping Themen
shot "$IPHONE" out/ios/5-themes-light.png
xcrun simctl ui "$IPHONE" content_size accessibility-extra-large; sleep 2
run "$IPHONE" $ID 25 --demo
shot "$IPHONE" out/ios/6-list-largetext.png
xcrun simctl ui "$IPHONE" content_size large
xcrun simctl shutdown "$IPHONE"

IPAD=$(pick "iPad Pro 13")
[ -z "$IPAD" ] && IPAD=$(pick "iPad")
echo "iPad $IPAD"
xcrun simctl boot "$IPAD"; xcrun simctl bootstatus "$IPAD" -b >/dev/null
xcrun simctl install "$IPAD" "$IOS_APP"
xcrun simctl ui "$IPAD" appearance light
run "$IPAD" $ID 75 --demo --open-first
shot "$IPAD" out/ipad/1-split-light.png
xcrun simctl ui "$IPAD" appearance dark; sleep 3
shot "$IPAD" out/ipad/2-split-dark.png
xcrun simctl shutdown "$IPAD"

WATCH=$(pick "Apple Watch Series 10 (46mm)")
[ -z "$WATCH" ] && WATCH=$(pick "Apple Watch")
echo "Watch $WATCH"
xcrun simctl boot "$WATCH"; xcrun simctl bootstatus "$WATCH" -b >/dev/null
xcrun simctl install "$WATCH" "$WATCH_APP" && echo installed
run "$WATCH" $WID 90 --demo
shot "$WATCH" out/watch/1-list.png
xcrun simctl shutdown "$WATCH"
ls -la out/ios out/ipad out/watch
