#!/bin/bash

# SD2Snes Commander - Finder Sync Extension Installer
echo "🚀 Installing SD2Snes Commander with Finder Sync Extension..."

# Build the project
echo "📦 Building SD2Snes Commander..."
xcodebuild -project SD2SnesCommander.xcodeproj -scheme SD2SnesCommander -configuration Release build > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
else
    echo "❌ Build failed. Please check Xcode project."
    exit 1
fi

# Find the built app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/SD2SnesCommander-*/Build/Products/Release -name "SD2SnesCommander.app" | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Could not find built app"
    exit 1
fi

# Copy to Applications
echo "📱 Installing SD2Snes Commander to Applications..."
cp -R "$APP_PATH" /Applications/

echo "✅ SD2Snes Commander installed to Applications!"

# Instructions for user
echo ""
echo "🔧 Next Steps:"
echo "1. Open System Settings → Privacy & Security → Extensions"
echo "2. Click 'Finder Extensions'"
echo "3. Enable 'SD2SnesFileSync'"
echo ""
echo "📁 Usage:"
echo "• Open Finder"
echo "• Navigate to Documents/SD2Snes Device (or it may appear in sidebar)"
echo "• Click to connect to your SD2Snes device"
echo "• Drag ROM files to upload (automatic IPS patching!)"
echo "• Right-click ROM files to boot them"
echo ""
echo "🎮 Enjoy your SD2Snes Finder integration!"