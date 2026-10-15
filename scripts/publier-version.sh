#!/bin/zsh
# Publie une version d'Écritoire sur GitHub (releases de brunmul/ecritoire) pour les mises à jour automatiques (Sparkle).
#
# Usage : ./scripts/publier-version.sh 0.2            numéro de version, enregistré dans le dépôt (commit + tag v0.2)
#         ./scripts/publier-version.sh 0.2.1 --essai   version d'essai : construite à part, publiée sans commit
#                                                       (à supprimer ensuite : gh release delete v0.2.1 --cleanup-tag)
#
# Étapes : numéro de version (Info.plist), construction, zip, signature EdDSA (clé privée dans le trousseau,
# compte « ecritoire », jamais dans le dépôt), appcast.xml, release GitHub avec le zip et l'appcast.
# L'app cherche le flux à https://github.com/brunmul/ecritoire/releases/latest/download/appcast.xml :
# la dernière release porte donc toujours l'appcast de sa propre version.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?numéro de version attendu, par exemple 0.2}"
ESSAI=false
[[ "${2:-}" == "--essai" ]] && ESSAI=true
REPO="brunmul/ecritoire"
TAG="v$VERSION"
PLIST=Resources/Info.plist

[[ -z "$(git status --porcelain)" ]] || { echo "Le dépôt a des modifications non enregistrées."; exit 1; }
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "La release $TAG existe déjà."; exit 1; }

# Numéro de construction : +1 à chaque version (Sparkle compare CFBundleVersion).
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" $PLIST) + 1 ))

if $ESSAI; then
  # Version d'essai : construite dans une copie temporaire, le dépôt n'est pas modifié.
  WORK=$(mktemp -d /tmp/ecritoire-essai.XXXXXX)
  git archive HEAD | tar -x -C "$WORK"
  cp -R .build "$WORK/.build" 2>/dev/null || true
  cd "$WORK"
else
  WORK=""
fi

/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" $PLIST
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" $PLIST

if ! $ESSAI; then
  git add $PLIST
  git commit -q -m "Version $VERSION"
  git tag "$TAG"
  git push -q origin HEAD:main "$TAG"
fi

./scripts/construire-app.sh >/dev/null

# Aucune donnée de ce Mac dans ce qui est distribué.
if grep -rl "$HOME" Ecritoire.app >/dev/null 2>&1; then echo "Chemin personnel trouvé dans l'app : publication annulée."; exit 1; fi

DIST=dist/$TAG
rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="Ecritoire-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent Ecritoire.app "$DIST/$ZIP"

SPARKLE_BIN=$(dirname "$(find .build/artifacts -name sign_update -type f | head -1)")
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account ecritoire "$DIST/$ZIP")   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Écritoire</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Écritoire $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

NOTES="Écritoire $VERSION pour macOS 14 ou plus récent.

Téléchargez $ZIP, décompressez-le et placez Écritoire dans le dossier Applications. L'app n'est pas signée par Apple : au premier lancement, ouvrez-la par clic droit → Ouvrir, puis confirmez (sur macOS 15 et plus récent : Réglages Système → Confidentialité et sécurité → « Ouvrir quand même »). Les versions suivantes s'installent ensuite automatiquement."
if $ESSAI; then
  gh release create "$TAG" "$DIST/$ZIP" "$DIST/appcast.xml" --repo "$REPO" --target main --title "Écritoire $VERSION (essai)" --notes "$NOTES"
else
  gh release create "$TAG" "$DIST/$ZIP" "$DIST/appcast.xml" --repo "$REPO" --title "Écritoire $VERSION" --notes "$NOTES"
fi
echo "Publié : https://github.com/$REPO/releases/tag/$TAG"
[[ -n "$WORK" ]] && echo "(copie d'essai : $WORK)"
