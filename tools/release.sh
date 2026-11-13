#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: tools/release.sh VERSION, e.g. 0.2.0}"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" Resources/Info.plist
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" Casks/clipsie.rb

ZIPS=()
for ARCH in arm64 x86_64; do
    ARCH="$ARCH" ./build.sh
    BUILT="$(lipo -archs build/Clipsie.app/Contents/MacOS/Clipsie)"
    if [[ "$BUILT" != "$ARCH" ]]; then
        echo "Expected a $ARCH app, got: $BUILT" >&2
        exit 1
    fi
    ZIP="build/Clipsie-$VERSION-$ARCH.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent build/Clipsie.app "$ZIP"
    SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    KEY="$([[ "$ARCH" == arm64 ]] && echo arm || echo intel)"
    sed -i '' -e "s/^\( *\(sha256 \)\{0,1\}$KEY: *\)\"[0-9a-f]*\"/\1\"$SHA\"/" Casks/clipsie.rb
    ZIPS+=("$ZIP")
    echo "Built $ZIP ($SHA)"
done

echo "Casks/clipsie.rb now points at version $VERSION: ${ZIPS[*]}"
