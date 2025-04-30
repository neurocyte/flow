#!/bin/bash
set -e

if [ "$1" == "--build" ]; then
    shift
    echo "building..."
    zig build -freference-trace --prominent-compile-errors
fi

for i in {1..60}; do
    echo "running $i ..."
    flow --exec quit "$@" || exit 1
done
