FROM archlinux:latest

ARG USERNAME=builder

RUN pacman -Syu --noconfirm git
RUN useradd -m -s /bin/bash $USERNAME

COPY --from=zig zig-x86_64-linux-0.17.0-dev.2122+3e15e99e6 /usr/local/bin

USER $USERNAME

WORKDIR /src/flow
