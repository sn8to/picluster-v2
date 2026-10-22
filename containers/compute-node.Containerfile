FROM rocky9

######################
## offline packages ##
######################

RUN mkdir -p /apps/pkgs

RUN dnf install -y --downloadonly --downloaddir=/apps/pkgs/chrony chrony
RUN dnf install -y --downloadonly --downloaddir=/apps/pkgs/slurm-compute slurm-slurmd munge
RUN dnf install -y --downloadonly --downloaddir=/apps/pkgs/ipa-client ipa-client
RUN dnf install -y --downloadonly --downloaddir=/apps/pkgs/glusterfs-client glusterfs-fuse
