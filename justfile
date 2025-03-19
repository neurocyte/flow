# available tasks
default:
    @just --list

# Just zig, please
zig *cmd:
    ./zigpy {{cmd}}

# Raw build command
build *cmd:
    ./zigpy build {{cmd}}

# zig build test
test:
    ./zigpy build -fincremental test

# zig build test
lint:
    ./zigpy build -fincremental lint

# zig build run
run:
    ./zigpy build -fincremental run

# build Debug verbose
build-debug:
    ./zigpy build -fincremental -Doptimize=Debug --verbose --summary all

# aarch64-linux-musl
release-android:
    ./zigpy build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
    
# Zig tool update
do-update:
    ./zigpy update

# Compile cdb
do-cdb:
    ./zigpy cdb
