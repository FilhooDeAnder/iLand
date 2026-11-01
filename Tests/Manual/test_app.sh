#!/bin/bash

cd "$(dirname "$0")/../.."

echo "🔨 Building iLand..."
./scripts/build.sh

if [ $? -eq 0 ]; then
    echo "📦 Copying sensors binary..."
    cp Resources/sensors iLand.app/Contents/Resources/
    
    echo "🔄 Restarting app..."
    killall iLand 2>/dev/null
    sleep 0.5
    open iLand.app
    
    echo "✅ App launched! Move mouse to notch area to test."
else
    echo "❌ Build failed!"
    exit 1
fi
