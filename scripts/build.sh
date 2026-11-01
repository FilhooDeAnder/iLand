#!/bin/bash
# Gera o iLand.app. Com --dmg, gera também dist/iLand.dmg (é o que o GitHub Actions publica).
# Versão: ILAND_VERSION, senão a última tag git (v1.2.3 -> 1.2.3), senão 0.0.0.
# Assinatura: o certificado "iLand Loop Signing" num chaveiro próprio. Local: ~/.iland-signing/iland.keychain-db.
# CI: ILAND_KEYCHAIN e ILAND_KEYCHAIN_PASSWORD. Sem o certificado, a assinatura é ad-hoc e o macOS trata
# cada build como um app novo (pede as permissões de novo). Use só a versão do GitHub no dia a dia.
set -euo pipefail
cd "$(dirname "$0")/.."

ID="br.com.loop4.iland"
VERSION="${ILAND_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="${ILAND_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "🏗️  iLand $VERSION ($BUILD)"
swift build -c release --arch arm64

rm -rf iLand.app
mkdir -p iLand.app/Contents/MacOS iLand.app/Contents/Resources
cp .build/arm64-apple-macosx/release/iLand iLand.app/Contents/MacOS/
cp Resources/sensors iLand.app/Contents/Resources/
cp LICENSE THIRD_PARTY_NOTICES.md iLand.app/Contents/Resources/
cp Resources/Info.plist iLand.app/Contents/
chmod +x iLand.app/Contents/MacOS/iLand
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" iLand.app/Contents/Info.plist
if [ -n "${ILAND_REPO:-}" ]; then $PB -c "Set :ILandRepo $ILAND_REPO" iLand.app/Contents/Info.plist; fi

KC="${ILAND_KEYCHAIN:-$HOME/.iland-signing/iland.keychain-db}"
KCPASS="${ILAND_KEYCHAIN_PASSWORD:-$(cat "$HOME/.iland-signing/p12-password.txt" 2>/dev/null || true)}"
if [ -f "$KC" ] && [ -n "$KCPASS" ]; then
    security unlock-keychain -p "$KCPASS" "$KC"
    codesign --force --keychain "$KC" --sign "iLand Loop Signing" --identifier "$ID" iLand.app/Contents/Resources/sensors iLand.app
    echo "🔏 Assinado com iLand Loop Signing"
else
    codesign --force --sign - --identifier "$ID" iLand.app/Contents/Resources/sensors iLand.app
    echo "⚠️  Sem o certificado: assinatura ad-hoc. Esta cópia perde as permissões do macOS a cada build."
fi
codesign --verify --strict iLand.app

if [ "${1:-}" = "--dmg" ]; then
    rm -rf dist && mkdir -p dist/stage
    cp -R iLand.app dist/stage/
    ln -s /Applications dist/stage/Applications
    hdiutil create -volname iLand -srcfolder dist/stage -ov -format UDZO dist/iLand.dmg >/dev/null
    rm -rf dist/stage
    echo "📦 dist/iLand.dmg"
fi
echo "✅ iLand.app pronto"
