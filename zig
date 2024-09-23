#!/bin/bash
set -e

ARCH=$(uname -m)

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
ZIGDIR=$BASEDIR/.cache/zig
VERSION=$(<build.zig.version)

OS=$(uname)

if [ "$OS" == "Linux" ]; then
    OS=linux
elif [ "$OS" == "Darwin" ]; then
    OS=macos
elif [ "$OS" == "FreeBSD" ]; then
    OS=freebsd
    if [ "$ARCH" == "amd64" ]; then
        ARCH=x86_64
    fi
fi

if [ "$ARCH" == "arm64" ]; then
    ARCH=aarch64
fi

ZIGVER="zig-$OS-$ARCH-$VERSION"
ZIG=$ZIGDIR/$ZIGVER/zig

if [ "$1" == "update" ]; then
    curl -L --silent https://ziglang.org/download/index.json | jq -r '.master | .version' >build.zig.version
    NEWVERSION=$(<build.zig.version)

    if [ "$VERSION" != "$NEWVERSION" ]; then
        echo "zig version updated from $VERSION to $NEWVERSION"
        echo "rebuilding to update cdb..."
        $0 cdb
        exit 0
    fi
    echo "zig version $VERSION is up-to-date"
    exit 0
fi

get_zig() {
    (
        mkdir -p "$ZIGDIR"
        cd "$ZIGDIR"
        TARBALL="https://ziglang.org/download/$VERSION/$ZIGVER.tar.xz"

        if [ ! -d "$ZIGVER" ]; then
            curl "$TARBALL" | tar -xJ
        fi
    )
}
get_zig

if [ "$1" == "cdb" ]; then
    rm -rf .zig-cache
    rm -rf .cache/cdb

    $ZIG build

    (
        echo \[
        cat .cache/cdb/*
        echo {}\]
    ) | perl -0777 -pe 's/,\n\{\}//igs' | jq . | grep -v 'no-default-config' >compile_commands.json
    exit 0
fi

exec $ZIG "$@"
