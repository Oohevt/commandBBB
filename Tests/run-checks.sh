#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="${COMMAND_B_CHECK_DIR:-$ROOT_DIR/build/checks}"
BUNDLE="$CHECK_DIR/CommandBChecks.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.oohevt.commandb.regression</string>
<key>CFBundleExecutable</key><string>CommandBChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
SOURCES=("$ROOT_DIR/Tests/RegressionChecks.swift" "$ROOT_DIR/Sources/CommandB/LauncherPanel.swift" "$ROOT_DIR/Sources/CommandB/RoundedVisualEffectView.swift" "$ROOT_DIR/Sources/CommandB/DesktopClick.swift")
for source in "$ROOT_DIR/Sources/CommandB/Models/"*.swift "$ROOT_DIR/Sources/CommandB/Views/"*.swift; do
  SOURCES+=("$source")
done
xcrun swiftc -O -D COMMAND_B_TESTING -target "$(uname -m)-apple-macosx13.0" -parse-as-library "${SOURCES[@]}" -o "$BUNDLE/Contents/MacOS/CommandBChecks"
codesign --force --sign - "$BUNDLE"
REPORT="$CHECK_DIR/results-$(date +%Y%m%d-%H%M%S).json"
/usr/bin/open -n -W "$BUNDLE" --args "$REPORT"
python3 - "$REPORT" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    results = json.load(stream)
for result in results:
    print(('PASS' if result['passed'] else 'FAIL') + ': ' + result['name'] + ' ' + result['detail'])
print(f"{sum(r['passed'] for r in results)}/{len(results)} passed")
sys.exit(0 if all(r['passed'] for r in results) else 1)
PY
