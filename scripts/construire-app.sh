#!/bin/zsh
# Compile Écritoire en mode release et fabrique Ecritoire.app dans le dossier du projet.
# Usage : ./scripts/construire-app.sh [--installer]   (--installer copie l'app dans ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

# Icône : Resources/AppIcon.png (1 024 px, déjà détourée), convertie en .icns quand elle est plus récente.
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns ]]; then
  rm -rf Resources/AppIcon.iconset && mkdir Resources/AppIcon.iconset
  for n in 16 32 128 256 512; do
    sips -z $n $n Resources/AppIcon.png --out Resources/AppIcon.iconset/icon_${n}x${n}.png >/dev/null
    sips -z $((n * 2)) $((n * 2)) Resources/AppIcon.png --out Resources/AppIcon.iconset/icon_${n}x${n}@2x.png >/dev/null
  done
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

swift build -c release --product Ecritoire
BIN="$(swift build -c release --show-bin-path)/Ecritoire"

APP="Ecritoire.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ecritoire"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Polices libres de repli (quand Walbaum n'est pas installée).
cp -R Resources/Polices "$APP/Contents/Resources/Polices"
# Signature locale (ad hoc) : suffisante pour lancer l'app sur ce Mac.
codesign --force --sign - "$APP" >/dev/null

if [[ "${1:-}" == "--installer" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Ecritoire.app
  cp -R "$APP" ~/Applications/
  echo "Installée dans ~/Applications/Ecritoire.app"
fi
echo "Prêt : $(pwd)/$APP"
