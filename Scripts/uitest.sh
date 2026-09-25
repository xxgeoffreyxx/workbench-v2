#!/bin/sh
# Runs Workbench UI tests against the real app. Usage: Scripts/uitest.sh [TestClass/testName]
cd "$(dirname "$0")/.." || exit 1
pkill -f "Debug/Workbench.app/Contents/MacOS"
F=build/uitest-project; mkdir -p $F/.claude/skills/wb-echo
ONLY=${1:+-only-testing:WardenUITests/$1}
xcodebuild test -project Warden.xcodeproj -scheme WorkbenchUI -derivedDataPath build \
  -packageAuthorizationProvider netrc -destination 'platform=macOS' $ONLY \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=45CY38F39L > build/uitest.log 2>&1
grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" build/uitest.log | tail -20
