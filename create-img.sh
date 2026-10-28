#!/bin/bash

OUTPUTFILE_NAME="pi.img"
TMPDIR=${TMPDIR:-./tmp}
XZ_ENABLE=
VERBOSE=

usage() {
    cat << EOF
Usage: $0 [-hvz] [-o output.img]
    -h      shows this message and exits
    -o      specifies the output image (default: pi.img)
    -v      verbose logging - shows each command that is run in the script
    -x      compresses the image with xz (will automatically append .xz to the
            end of the output filename)

    You can also use the TMPDIR environment variable to change the directory
    used to hold staging files for the output image (default is ./tmp)
EOF
}

_() {
    if (( VERBOSE )); then
        echo $ "$@"
    fi
    eval "$@"
    if [ $? -ne 0 ]; then
        echo "*** The previous command failed! ***"
        exit 1
    fi
}

_check_exists() {
    case $1 in
        /*)
            if [[ ! -e $1 ]]; then
                echo "error: ${2:-$1} is required for this script"
                exit 1
            fi
            ;;
        *)
            if ! which $1 > /dev/null; then
                echo "error: ${2:-$1} is required for this script"
                exit 1
            fi
            ;;
    esac
}

while getopts ":ho:vx" opts; do
    case "$opts" in
        h)
            usage
            exit 0
            ;;
        o)
            OUTPUTFILE_NAME=$OPTARG
            ;;
        v)
            VERBOSE=1
            ;;
        x)
            XZ_ENABLE=1
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

make_base_container() {
    echo "=== building base container ==="
    _ podman build --no-hostname --no-hosts --platform linux/arm64 -f rocky9.Containerfile -t rocky9
}

make_compute_tar() {
    echo "=== building compute node container ==="
    _ podman build --no-hostname --no-hosts --platform linux/arm64 -f compute-node.Containerfile -t base-rocky9-dracut

    echo "=== writing & compressing compute node tarball ==="
    _ podman create --name temp-base-rocky9-dracut base-rocky9-dracut
    _ "podman export temp-base-rocky9-dracut | xz -v > base-rocky9-dracut.tar.xz"
    _ podman rm temp-base-rocky9-dracut
}

build_head_tar() {
    echo "=== building container ==="
    _ podman build --no-hostname --no-hosts --platform linux/arm64 -f head-node.Containerfile -t head-node

    echo "=== writing tarball ==="
    _ podman create --name temp-head-node head-node
    _ podman export temp-head-node -o $TMPDIR/headnode.tar
    _ podman rm temp-head-node
}

create_image() {
    local boot_size=256
    local root_size=$1
    local total_size=$(( boot_size + root_size + 2 ))
    echo "=== allocating output file ($total_size MiB) ==="
    _ dd if=/dev/zero of=$OUTPUTFILE_NAME bs=1M count=$total_size conv=sparse status=progress
    echo "=== creating partitions ==="
    _ sfdisk "$OUTPUTFILE_NAME" <<EOF
label: gpt
unit: sectors
first-lba: 2048
size=${boot_size}MiB type=uefi, name=picboot
size=${root_size}MiB type=linux, name=picroot
EOF
}

write_boot() {
    echo "=== copying boot files ==="
    _ mkdir -p $TMPDIR/picboot
    _ tar -xvf $TMPDIR/headnode.tar -C $TMPDIR/picboot boot/efi
    echo "=== writing boot to image ==="
    _ mformat -i ${OUTPUTFILE_NAME}@@2048S -v picboot -T `sfdisk --json $OUTPUTFILE_NAME | jq -r '.partitiontable.partitions[0].size'` ::
    _ mcopy -vi ${OUTPUTFILE_NAME}@@2048S -s $TMPDIR/picboot/boot/efi/* ::/
}

write_root() {
    echo "=== writing root to image ==="
    _ tar --delete -f $TMPDIR/headnode.tar boot/efi/
    # fix orphan_file flag being unsupported in rocky9
    if grep orphan_file /etc/mke2fs.conf >/dev/null; then
        O="-O ^orphan_file"
    fi
    _ mkfs.ext4 $O -vE offset=$(( `sfdisk --json $OUTPUTFILE_NAME | jq -r '.partitiontable.partitions[1].start'` * 512 )) -L picroot $OUTPUTFILE_NAME -d $TMPDIR/headnode.tar $(( `sfdisk --json $OUTPUTFILE_NAME | jq -r '.partitiontable.partitions[1].size'` / 2 ))k
}

xz_image() {
    echo "=== compressing image ==="
    _ xz -v $OUTPUTFILE_NAME
}

main() {
    echo "=== making temp directory ==="
    _ mkdir -p $TMPDIR

    make_base_container
    if [ ! -f base-rocky9-dracut.tar.xz ]; then
        make_compute_tar
        if [ ! -f base-rocky9-dracut.tar.xz ]; then
            echo "error: base-rocky9-dracut.tar.xz does not exist, did the build fail?"
            exit 1
        fi
    else
        echo "** base-rocky9-dracut.tar.xz already exists, no need to rebuild"
    fi
    build_head_tar
    if [ ! -f $TMPDIR/headnode.tar ]; then
        echo "error: headnode.tar does not exist, did the build fail?"
        exit 1
    fi
    create_image $(( 1024 * 8 ))
    write_boot
    write_root
    if (( XZ_ENABLE )); then
        xz_image
    fi
}



_check_exists podman
_check_exists sfdisk util-linux
_check_exists mcopy mtools
_check_exists mkfs.ext4 e2fsprogs
_check_exists jq
_check_exists /usr/include/archive.h libarchive

main
