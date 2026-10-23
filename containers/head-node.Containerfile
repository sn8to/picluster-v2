FROM rocky9
# can't use rocky 10 yet, pdsh isn't available until 10.3, currently we're on 10.2


#######################
## base rocky config ##
#######################

# create /apps dirs
RUN mkdir -p /apps/{pkgs,other}
RUN chmod g+w /apps

# create admin and user
RUN useradd -m -g wheel -p '$5$cOTJhkxlC4$kEFPIJaKPriv16lcwNBsS4dVMT1sC/a9vFPNlZDHug1' -s /bin/bash -u 1000 admin
RUN useradd -m -g users -p '$5$cOTJhkxlC4$kEFPIJaKPriv16lcwNBsS4dVMT1sC/a9vFPNlZDHug1' -s /bin/bash -u 1001 user

# set static ip
COPY configs/head-node.nmconnection /etc/NetworkManager/system-connections

# set hostname
RUN echo pi-hpc-head01.pi.local > /etc/hostname

######################
## warewulf install ##
######################

RUN dnf install -y dnsmasq nfs-utils golang unzip ipxe-bootimgs-aarch64
RUN mkdir /opt/warewulf

# clone warewulf and checkout v4.7.1
RUN git clone https://github.com/warewulf/warewulf.git /opt/warewulf/src
WORKDIR /opt/warewulf/src
RUN git checkout v4.7.1

# build warewulf
RUN make clean defaults config PREFIX=/opt/warewulf
RUN make all PREFIX=/opt/warewulf
RUN make install

# clean unnecessary files
RUN go clean -modcache && go clean -cache

# modify ww conf for ip range
RUN yq -i '.netmask = "255.255.254.0"' /opt/warewulf/etc/warewulf/warewulf.conf

# fix ipxe path in ww conf
RUN yq -i '.paths.ipxesource = "/usr/share/ipxe"' /opt/warewulf/etc/warewulf/warewulf.conf

# add ww to path
RUN echo 'export PATH=$PATH:/opt/warewulf/bin' > /etc/profile.d/warewulf.sh
RUN sed -i 's/secure_path = /secure_path = \/opt\/warewulf\/bin:/' /etc/sudoers

# add raspi tftpboot files
COPY configs/tftpboot/*.ww /opt/warewulf/share/warewulf/overlays/host/rootfs/var/lib/tftpboot

# dnsmasq
RUN yq -i '.dhcp.["systemd name"] = "dnsmasq" | .tftp.["systemd name"] = "dnsmasq"' /opt/warewulf/etc/warewulf/warewulf.conf
# todo: RUN wwctl overlay import host $BASEDIR/configs/templates/ww4-listen.conf.ww /etc/dnsmasq.d
RUN echo 'pxe-service=0,"Raspberry Pi Boot"' > /etc/dnsmasq.d/piboot.conf

RUN systemctl enable warewulfd dnsmasq

# reset workdir back to root
WORKDIR /

#################
## setup nodes ##
#################

# install podman (just for building the compute node image)
RUN dnf install -y podman
RUN dnf clean all

# build the rocky9 base image and the compute image
RUN --mount=type=bind,source=rocky9.Containerfile,target=rocky9.Containerfile \
    podman build -f rocky9.Containerfile -t rocky9
RUN --mount=type=bind,source=compute-node.Containerfile,target=compute-node.Containerfile \
    podman build -f compute-node.Containerfile -t base-rocky9-dracut

# import compute image into warewulf
RUN podman save base-rocky9-dracut -o oci.tar
RUN wwctl container import oci.tar base-rocky9-dracut
RUN rm oci.tar

# configure warewulf for all services
RUN wwctl configure -a

# profile setup
RUN wwctl profile set --container base-rocky9-dracut --ipxe dracut --netdev eth0 default --yes

# add nodes
RUN wwctl node add pi-hpc-compute[01-04] -I 10.0.0.11 --discoverable

# build containers and overlays
RUN wwctl image build base-rocky9-dracut
RUN wwctl overlay build

# fix selinux for tftpboot dir
#RUN restorecon -Rv /var/lib/tftpboot

# clean up podman stuff
RUN podman system prune -af
RUN rm -r /root/.cache