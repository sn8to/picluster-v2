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
RUN sed -i -e 's/-o mpol=interleave //' /usr/lib/dracut/modules.d/90wwinit/load-wwinit.sh

# install raspi firmware & boot files
RUN dnf install -y rocky-release-rpi
RUN dnf install -y rocky-sbc-utils
RUN dnf install -y --setopt=install_weak_deps=False kernel-rpi-4k-core kernel-rpi-firmware rpi-firmware-bluez rpi-firmware-nonfree

# system utils
RUN dnf install -y vim nano pdsh pdsh-rcmd-ssh pdsh-mod-genders python3-distutils-extra python3-devel git tar jq yq pigz sudo less

# set ssh as default for pdsh
RUN echo 'export PDSH_RCMD_DEFAULT=ssh' > /etc/profile.d/pdsh.sh

# copy cmdline.txt
COPY configs/cmdline.txt /boot/efi

# remove dnf cache
RUN dnf clean all