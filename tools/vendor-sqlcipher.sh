#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-4.19.0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/src.tar.gz" "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v$VERSION.tar.gz"
echo "SHA-256 of the source archive: $(shasum -a 256 "$WORK/src.tar.gz" | cut -d' ' -f1)"
tar -xzf "$WORK/src.tar.gz" -C "$WORK"
mkdir "$WORK/build"
(
    cd "$WORK/build"
    "../sqlcipher-$VERSION/configure" --with-tempstore=yes --enable-fts5 \
        CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown" \
        > configure.log
    make sqlite3.c > make.log
)

mkdir -p Sources/CSQLCipher/include
cp "$WORK/build/sqlite3.c" Sources/CSQLCipher/sqlite3.c
cp "$WORK/build/sqlite3.h" Sources/CSQLCipher/include/sqlite3.h
cp "$WORK/sqlcipher-$VERSION/LICENSE.md" Sources/CSQLCipher/LICENSE.md
echo "$VERSION" > Sources/CSQLCipher/VERSION
echo "Vendored SQLCipher $VERSION (SQLite $(grep -m1 '#define SQLITE_VERSION ' Sources/CSQLCipher/sqlite3.c | cut -d'"' -f2))"
