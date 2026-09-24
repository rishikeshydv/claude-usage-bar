#!/bin/bash
# Build ClaudeUsageBar, install it to ~/Applications, and start it at login.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsageBar"
LABEL="com.rishikesh.claudeusagebar"
BUILD_APP="build/$APP_NAME.app"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

rm -rf build
mkdir -p "$BUILD_APP/Contents/MacOS"

swiftc -O -swift-version 5 Sources/main.swift -o "$BUILD_APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$BUILD_APP/Contents/Info.plist"
codesign --force --sign - "$BUILD_APP"

# Stop the running copy (if any) before replacing it.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" || true

mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED_APP"
cp -R "$BUILD_APP" "$INSTALLED_APP"

# launchd needs an absolute path, so the plist is written here instead of shipped as a file.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
echo "Installed $INSTALLED_APP and started it (also starts at login)."
