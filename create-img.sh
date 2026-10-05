#!/bin/bash

CONTAINERFILE_NAME="Containerfile"
OUTPUTFILE_NAME="pi.img"
TMPDIR=${TMPDIR:-`mktemp -d`}
XZ_ENABLE=
VERBOSE=

usage() {
    cat << EOF
Usage: $0 [-hvz] [-f containerfile] [-o output.img]
    -f      specifies which containerfile to build (default: Containerfile)
    -h      shows this message and exits
    -o      specifies the output image (default: pi.img)
    -v      verbose logging - shows each command that is run in the script
    -x      compresses the image with xz (will automatically append .xz to the end of the output filename)
EOF
}

_() {
    if (( VERBOSE )); then
        echo $ "$@"
    fi
    local cmd="$1"
    shift
    $cmd "$@"
}

_check_exists() {
    if ! which $1 > /dev/null; then
        echo "error: ${2:-$1} is required for this script"
        exit 1
    fi
}

while getopts ":f:ho:vx" opts; do
    case "$opts" in
        f)
            CONTAINERFILE_NAME=$OPTARG
            ;;
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

build_container() {
    echo "=== making temp directory ==="
    # TMPDIR=`mktemp -d`
    # echo $TMPDIR
    _ mkdir -p $TMPDIR

    echo "=== building container ==="
    _ buildah bud --no-hostname --no-hosts --platform linux/arm64 -f $CONTAINERFILE_NAME -o type=tar,dest=$TMPDIR/container.tar
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
size=${boot_size}MiB type=uefi, name=bootfs
size=${root_size}MiB type=linux, name=rootfs
EOF
}

write_boot() {
    echo "=== copying boot files ==="
    _ mkdir -p $TMPDIR/bootfs
    _ tar -xvf $TMPDIR/container.tar -C $TMPDIR/bootfs boot/efi
    echo "=== writing boot to image ==="
    _ mformat -i ${OUTPUTFILE_NAME}@@2048S -T `sfdisk --json $OUTPUTFILE_NAME | jq -r '.partitiontable.partitions[0].size'` ::
    _ mcopy -vi ${OUTPUTFILE_NAME}@@2048S -s $TMPDIR/bootfs/boot/efi/* ::/
}

write_root() {
    echo "=== writing root to image ==="
    _ tar --delete -f $TMPDIR/container.tar boot/efi/
    _ mkfs.ext4 -vE offset=$(( `sfdisk --json $OUTPUTFILE_NAME | jq -r '.partitiontable.partitions[1].start'` * 512 )) -L rootfs $OUTPUTFILE_NAME -d $TMPDIR/container.tar $(( `sfdisk --json $OUTPUTFILE_NAME | jq -r '.partitiontable.partitions[1].size'` / 2 ))k
}

xz_image() {
    echo "=== compressing image ==="
    _ xz -v $OUTPUTFILE_NAME
}

main() {
    build_container
    if [ ! -f $TMPDIR/container.tar ]; then
        echo "error: container.tar does not exist, did the build fail?"
        exit 1
    fi
    create_image $(( 1024 * 8 ))
    write_boot
    write_root
    if (( XZ_ENABLE )); then
        xz_image
    fi
}



_check_exists buildah
_check_exists sfdisk util-linux
_check_exists mcopy mtools
_check_exists mkfs.ext4 e2fsprogs
_check_exists jq

main
