#!/bin/bash
# Creates a proper .app bundle for Stock4Ticker

set -e

APPNAME="Stock4Ticker"
BUNDLE_ID="cz.stock4ticker.app"
BUILD_DIR=".build/release"
APP_DIR="$APPNAME.app"
CONTENTS="$APP_DIR/Contents"
# Verze bundlu lze přebít přes prostředí (make-release.sh ji nastaví dle tagu).
APP_VERSION="${APP_VERSION:-1.0.0}"

echo "🔨 Building release..."
swift build -c release

echo "📦 Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Copy binary
cp "$BUILD_DIR/$APPNAME" "$CONTENTS/MacOS/$APPNAME"
chmod +x "$CONTENTS/MacOS/$APPNAME"

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# Create Info.plist
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APPNAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APPNAME</string>
    <key>CFBundleDisplayName</key>
    <string>Stock4Ticker</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo ""
echo "✅ Created: $APP_DIR"
echo ""
echo "Spustit:"
echo "  open $APP_DIR"
echo ""
echo "Přesunout do Applications:"
echo "  mv $APP_DIR /Applications/$APP_DIR"
