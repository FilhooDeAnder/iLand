#!/bin/bash
# Instala a partir do código (para quem desenvolve o iLand). Para usar no dia a dia, baixe o .dmg do GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."
killall iLand 2>/dev/null || true
./scripts/build.sh
rm -rf /Applications/iLand.app
cp -R iLand.app /Applications/
open /Applications/iLand.app
echo "✅ Instalado em /Applications/iLand.app"
