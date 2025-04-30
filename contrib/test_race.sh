#!/bin/bash
set -e

if [ "$1" == "--build" ]; then
    shift
    echo "building..."
    zig build -freference-trace --prominent-compile-errors
fi

for i in {1..60}; do
    echo "running $i ..."
    # flow --exec quit "$@" || exit 1
    strace -f -t \
        -e trace=open,openat,close,socket,pipe,pipe2,dup,dup2,dup3,fcntl,accept,accept4,epoll_create,epoll_create1,eventfd,timerfd_create,signalfd,execve,fork \
        -o trace.log \
        flow --exec quit --trace-level 9 "$@"
done
