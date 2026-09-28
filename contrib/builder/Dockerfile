FROM archlinux:latest

ARG USERNAME=builder
ARG ZIG_VERSION

RUN pacman -Syu --noconfirm git
RUN useradd -m -s /bin/bash $USERNAME

COPY --from=zig zig-x86_64-linux-${ZIG_VERSION} /usr/local/bin

USER $USERNAME

WORKDIR /src/flow
