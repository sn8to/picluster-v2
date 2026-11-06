FROM docker.io/rockylinux/rockylinux:9 AS rocky9
# can't use rocky 10 yet, pdsh isn't available until 10.3, currently we're on 10.2


#######################
## base rocky config ##
#######################

# update
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
RUN dnf config-manager --set-enabled crb
RUN dnf update -y

# install dracut
RUN dnf install -y dracut dracut-tools dracut-network ignition gdisk e2fsprogs
RUN dnf install -y https://github.com/warewulf/warewulf/releases/download/v4.7.1/warewulf-dracut-4.7.1-1.el9.noarch.rpm
RUN echo -e 'hostonly="no"\nadd_dracutmodules+=" wwinit ignition "' > /etc/dracut.conf.d/wwinit.conf
# fix: raspi doesn't have NUMA so interleaving makes the mount fail
RUN sed -i -e 's/-o mpol=interleave //' /usr/lib/dracut/modules.d/90wwinit/load-wwinit.sh
# fix: ignition tries to force-enable modules that don't exist on raspi
RUN sed -i 's/instmods -c/instmods/g' /usr/lib/dracut/modules.d/30ignition/module-setup.sh

# install raspi firmware & boot files
RUN dnf install -y rocky-release-rpi
RUN dnf install -y rocky-sbc-utils
RUN mkdir -p /boot/efi
RUN dnf install -y kernel-rpi-4k-core kernel-rpi-firmware rpi-firmware-bluez rpi-firmware-nonfree

# system utils
RUN dnf install -y vim nano openssh-server pdsh pdsh-rcmd-ssh pdsh-mod-genders python3-distutils-extra python3-devel git tar jq yq pigz sudo less bash-completion

# set ssh as default for pdsh
RUN echo 'export PDSH_RCMD_DEFAULT=ssh' > /etc/profile.d/pdsh.sh

# copy cmdline.txt
COPY configs/cmdline.txt /boot/efi/

# copy /etc files
COPY configs/fstab configs/hosts configs/genders /etc/
COPY configs/sudoers-pdsh /etc/sudoers.d/pdsh

# create admin and user
RUN useradd -m -g wheel -p '$5$cOTJhkxlC4$kEFPIJaKPriv16lcwNBsS4dVMT1sC/a9vFPNlZDHug1' -s /bin/bash -u 1000 admin
RUN useradd -m -g users -p '$5$cOTJhkxlC4$kEFPIJaKPriv16lcwNBsS4dVMT1sC/a9vFPNlZDHug1' -s /bin/bash -u 1001 user

# remove dnf cache
RUN dnf clean all