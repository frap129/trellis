ARG BASE_IMAGE="docker.io/library/${BASE_IMAGE_NAME:-archlinux}"
ARG BASE_IMAGE_FLAVOR="${BASE_IMAGE_FLAVOR:-base-devel}"

FROM ${BASE_IMAGE}:${BASE_IMAGE_FLAVOR} AS trellis

# Remove container specific storage optimization in Pacman
RUN sed -i -e "s|^NoExtract.*||g" /etc/pacman.conf && \
    pacman --noconfirm -Syu

# Networking
RUN pacman --noconfirm -S networkmanager && \
    systemctl enable NetworkManager.service && \
    systemctl mask systemd-networkd-wait-online.service

# Prepre OSTree integration (https://wiki.archlinux.org/title/Mkinitcpio#Common_hooks)
RUN mkdir -p /etc/mkinitcpio.conf.d && \
    echo "HOOKS=(base systemd ostree autodetect modconf kms keyboard sd-vconsole block filesystems fsck)" >> /etc/mkinitcpio.conf.d/ostree.conf

# Install kernel, firmware, microcode, filesystem tools, bootloader, depndencies and run hooks once:
RUN pacman --noconfirm -S \
    linux \
    linux-headers \
    linux-firmware \
    intel-ucode \
    amd-ucode \
    \
    dosfstools \
    \
    grub \
    mkinitcpio \
    \
    podman \
    ostree \
    which \
    man \
    vim \
    git

# Create build user
RUN useradd -m --shell=/bin/bash build && usermod -L build && \
    echo "build ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    echo "root ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Install AUR packages
USER build
WORKDIR /home/build
RUN git clone https://aur.archlinux.org/paru-bin.git --single-branch && \
    cd paru-bin && \
    makepkg -si --noconfirm && \
    cd .. && \
    rm -drf paru-bin && \
    paru -S \
        aur/pacdef \
        --noconfirm
USER root
WORKDIR /

# Native march & tune. We do this last because it'll only apply to updates the user makes going forward.
# We don't want to optimize for the build host's environment.
RUN sed -i 's/-march=x86-64 -mtune=generic/-march=native -mtune=native/g' /etc/makepkg.conf

# Cleanup
RUN userdel -r build && \
    rm -drf /home/build && \
    sed -i '/build ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
    sed -i '/root ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
    rm -rf \
        /tmp/* \
        /var/cache/pacman/pkg/*d a user for it

# OSTree: Prepare microcode and initramfs
RUN moduledir=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d) && \
    cat /boot/*-ucode.img \
        /boot/initramfs-linux-fallback.img \
        > ${moduledir}/initramfs.img

# OSTree: Bootloader integration
RUN curl https://raw.githubusercontent.com/ostreedev/ostree/v2023.6/src/boot/grub2/grub2-15_ostree -o /etc/grub.d/15_ostree && \
    chmod +x /etc/grub.d/15_ostree

# Podman: native Overlay Diff for optimal Podman performance
RUN echo "options overlay metacopy=off redirect_dir=off" > /etc/modprobe.d/disable-overlay-redirect-dir.conf
