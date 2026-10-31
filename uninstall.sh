#!/bin/bash

echo "🗑️  iLand Uninstaller"
echo ""

# Check if app exists
if [ ! -d "/Applications/iLand.app" ]; then
    echo "ℹ️  iLand is not installed in /Applications"
    echo ""
    echo "Nothing to uninstall. The app may be:"
    echo "  • Running from the local directory (iLand.app)"
    echo "  • Not yet installed"
    echo ""
    echo "To stop the local app: killall iLand"
    exit 0
fi

# Kill if running
echo "1️⃣  Stopping app if running..."
killall iLand 2>/dev/null
if [ $? -eq 0 ]; then
    echo "   ✓ App stopped"
else
    echo "   ℹ️  App was not running"
fi

# Remove app
echo "2️⃣  Removing from /Applications..."
rm -rf /Applications/iLand.app

if [ $? -eq 0 ]; then
    echo "   ✓ App removed"
else
    echo "   ❌ Failed to remove app"
    exit 1
fi

echo ""
echo "✅ iLand uninstalled successfully!"
echo ""
echo "Note: You may want to remove accessibility permissions:"
echo "  System Settings > Privacy & Security > Accessibility"
echo "  Remove 'iLand' from the list"
