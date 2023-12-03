ARG BASE_IMAGE="docker.io/library/${BASE_IMAGE_NAME:-archlinux}"
ARG BASE_IMAGE_FLAVOR="${BASE_IMAGE_FLAVOR:-base}"

FROM ${BASE_IMAGE}:${BASE_IMAGE_FLAVOR} AS trellis

# Prepre OSTree integration (https://wiki.archlinux.org/title/Mkinitcpio#Common_hooks)
RUN mkdir -p /etc/mkinitcpio.conf.d && \
    echo "HOOKS=(base systemd ostree plymouth autodetect modconf kms keyboard sd-vconsole block filesystems fsck)" >> /etc/mkinitcpio.conf.d/trellis.conf

# Create build user
RUN useradd -m --shell=/bin/bash build && usermod -L build && \
    echo "build ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    echo "root ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Install temporary depndencies
RUN pacman -Syyu --noconfirm && \
    pacman -S \
    git \
    base-devel \
    clang \
    llvm \
    lld \
    --noconfirm

# Install AUR packages
USER build
WORKDIR /home/build
RUN git clone https://aur.archlinux.org/paru-bin.git --single-branch && \
    cd paru-bin && \
    makepkg -si --noconfirm && \
    cd .. && \
    rm -drf paru-bin && \
    paru -S \
        aur/alhp-keyring \
        aur/alhp-mirrorlist \
        aur/ananicy-cpp \
        aur/cachyos-ananicy-rules-git \
        aur/uksmd \
        --noconfirm --removemake=yes

# Build Kernel
RUN env _NUMAdisable=y _use_llvm_lto=thin _use_lto_suffix= _nr_cpus=$(nproc) _use_kcfi=y paru -S \
        aur/linux-cachyos \
        aur/linux-cachyos-headers \
        --noconfirm

# Cleanup AUR builder
USER root
WORKDIR /

RUN userdel -r build && \
    rm -drf /home/build && \
    sed -i '/build ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
    sed -i '/root ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
    rm -rf \
        /tmp/* \
        /var/cache/pacman/pkg/*d a user for it

# Setup ALHP Repos
RUN pacman-key --init && \
    pacman-key --populate && \
    sed -i '/\#\[core-testing\]/i \
[core-x86-64-v3]\nInclude = /etc/pacman.d/alhp-mirrorlist\n\n[extra-x86-64-v3]\nInclude = /etc/pacman.d/alhp-mirrorlist\n' /etc/pacman.conf

# Install kernel, firmware, microcode, filesystem tools, bootloader, depndencies and run hooks once:
RUN pacman -Syyu --noconfirm && \
    pacman -S \
    linux-firmware \
    linux-firmware-whence \
    intel-ucode \
    amd-ucode \
    dosfstools \
    grub \
    mkinitcpio \
    podman \
    ostree \
    distrobox \
    plymouth \
    networkmanager \
    dbus-broker \
    zram-generator \
    --noconfirm

# Enable default services
RUN systemctl enable ananicy-cpp && \
    systemctl enable uksmd && \
    systemctl enable dbus-broker && \
    systemctl enable systemd-oomd && \
    systemctl enable NetworkManager.service && \
    systemctl mask systemd-networkd-wait-online.service

# Native march & tune. We do this last because it'll only apply to updates the user makes going forward.
# We don't want to optimize for the build host's environment.
RUN sed -i 's/-march=x86-64 -mtune=generic/-march=native -mtune=native/g' /etc/makepkg.conf

# Podman: native Overlay Diff for optimal Podman performance
RUN echo "options overlay metacopy=off redirect_dir=off" > /etc/modprobe.d/disable-overlay-redirect-dir.conf

# OSTree: Prepare microcode and initramfs
RUN moduledir=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d) && \
    cat /boot/*-ucode.img \
        /boot/initramfs-*-fallback.img \
        > ${moduledir}/initramfs.img

# OSTree: Bootloader integration
RUN curl https://raw.githubusercontent.com/ostreedev/ostree/main/src/boot/grub2/grub2-15_ostree -o /etc/grub.d/15_ostree && \
    chmod +x /etc/grub.d/15_ostree

ADD rootfs/etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf

# Cleanup packages
RUN pacman -Rcns \
    base-devel \
    git \
    clang \
    llvm \
    lld \
    --noconfirm && \
    pacman -Rcns $(pacman -Qtdq) --noconfirm
