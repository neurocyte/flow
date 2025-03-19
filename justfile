build-debug:
    zig build -fincremental -Doptimize=Debug --verbose --summary all

test:
    zig build test

lint:
    zig build lint

release-android:
    zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
