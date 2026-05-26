FROM archlinux:latest

ARG USERNAME=builder

RUN pacman -Syu --noconfirm git zig
RUN useradd -m -s /bin/bash $USERNAME
USER $USERNAME

WORKDIR /src/flow
