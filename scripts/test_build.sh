#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "🧪 Testing iLand build..."
echo ""

# Clean previous builds
echo "🧹 Cleaning..."
rm -rf .build
rm -rf iLand.app

# Build
echo "🔨 Building..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

echo "✅ Build successful!"
echo ""

# Create app bundle
echo "📦 Creating app bundle..."
./scripts/build.sh

if [ -d "iLand.app" ]; then
    echo "✅ App bundle created successfully!"
    echo ""
    echo "📊 App info:"
    ls -lh iLand.app/Contents/MacOS/iLand
    echo ""
    echo "🎯 Ready to test! Run:"
    echo "   open iLand.app"
else
    echo "❌ Failed to create app bundle"
    exit 1
fi
