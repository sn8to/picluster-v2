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
RUN go clean -modcache

# modify ww conf for ip range
RUN yq -i '.netmask = "255.255.254.0"' /opt/warewulf/etc/warewulf/warewulf.conf

# fix ipxe path in ww conf
RUN yq -i '.paths.ipxesource = "/usr/share/ipxe"' /opt/warewulf/etc/warewulf/warewulf.conf

# add ww to path
RUN echo 'export PATH=$PATH:/opt/warewulf/bin' > /etc/profile.d/warewulf.sh
RUN sed -i 's/secure_path = /secure_path = \/opt\/warewulf\/bin:/' /etc/sudoers

# dnsmasq
RUN yq -i '.dhcp.["systemd name"] = "dnsmasq" | .tftp.["systemd name"] = "dnsmasq"' /opt/warewulf/etc/warewulf/warewulf.conf
# todo: RUN wwctl overlay import host $BASEDIR/configs/templates/ww4-listen.conf.ww /etc/dnsmasq.d

RUN systemctl enable warewulfd dnsmasq

#################
## setup nodes ##
#################

# todo