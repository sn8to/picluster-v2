#!/bin/bash
#
# Assembles the cross-arch emulation payload in qemu/ used by
# tools/qemu-cross-runtime (see create-img.sh) on x86_64 hosts that have no
# qemu-aarch64 binfmt_misc entry (which requires root to register).
#
# The payload is a qemu-user build patched to intercept guest execve()
# ("qemu-execve" from conda-forge; stock qemu-user cannot run nested guest
# binaries without binfmt_misc). It is bind-mounted into each build
# container at /.qemu-cross -- nothing lands in the images.
#
# qemu/ layout:
#   ld.so                        host x86_64 dynamic loader (renamed); the
#                                qemu binary below is patched to use exactly
#                                /mnt/ld.so as its ELF interpreter (/mnt is
#                                where the runtime wrapper mounts this
#                                payload), so the kernel inside an arm64
#                                root can exec it without any x86 files in
#                                the container
#   bin/qemu-execve-aarch64      PT_INTERP patched in-place to /mnt/ld.so
#                                (fits the original string slot; RPATH
#                                $ORIGIN/../lib untouched, it resolves
#                                correctly both on the host and inside the
#                                container)
#   lib/                         conda libraries qemu needs + the host's
#                                glibc libraries (ld.so finds all of these
#                                through RPATH before ld.so.cache, which in
#                                an arm64 root would point at arm64 libs)
#
# Pinned builds (the qemu-execve build must include the native-passthrough
# execve patch; this one is known-good):

set -e
cd "$(dirname "$0")/.."

if [ "$(uname -m)" != x86_64 ]; then
    echo "setup-qemu-execve: host is $(uname -m), no emulation payload needed"
    exit 0
fi

BASE=https://conda.anaconda.org/conda-forge/linux-64
PKGS="
qemu-execve-aarch64-11.0.3-h546fcaf_12.conda
libcapstone-5.0.9-h7cc23a3_2.conda
libglib-2.90.0-h569388d_0.conda
libzlib-1.3.2-h25fd6f3_2.conda
libiconv-1.18-h0cb94f2_3.conda
pcre2-10.47-h8b3dc9c_1.conda
"
# from the extracted conda packages
CONDA_LIBS="libcapstone.so.5 libglib-2.0.so.0 libgmodule-2.0.so.0 \
libiconv.so.2 libpcre2-8.so.0 libz.so.1"
# from the running host (glibc stub libraries may be empty, that's fine)
GLIBC_LIBS="libc.so.6 libm.so.6 librt.so.1 libpthread.so.0 libdl.so.2 \
libutil.so.1 libresolv.so.2 libgcc_s.so.1"

for f in $PKGS; do
    [ -s qemu/.cache/$f ] && continue
    mkdir -p qemu/.cache
    echo "downloading $f"
    curl -fL --retry 3 --max-time 600 -o qemu/.cache/$f.part $BASE/$f
    mv qemu/.cache/$f.part qemu/.cache/$f
done

rm -rf qemu/bin qemu/lib qemu/ld.so tmp/.qemu-extract
mkdir -p qemu/bin qemu/lib tmp/.qemu-extract
for f in $PKGS; do
    member="pkg-${f%.conda}.tar.zst"
    ( cd tmp/.qemu-extract && unzip -qo ../../qemu/.cache/$f "$member" \
      && tar -xf "$member" --zstd && rm -f "$member" )
done
BIN=$(find tmp/.qemu-extract -name qemu-execve-aarch64 -type f | head -1)
[ -n "$BIN" ] || { echo "setup-qemu-execve: qemu-execve-aarch64 not in packages" >&2; exit 1; }
mv "$BIN" qemu/bin/
for l in $CONDA_LIBS; do
    src=$(find tmp/.qemu-extract -name "$l" | head -1)
    [ -n "$src" ] || { echo "setup-qemu-execve: $l not in packages" >&2; exit 1; }
    cp -Lp "$src" qemu/lib/$l
done
rm -rf tmp/.qemu-extract

# host loader + host glibc libraries so the patched qemu binary is entirely
# self-contained inside the container
cp -Lp /lib64/ld-linux-x86-64.so.2 qemu/ld.so
for l in $GLIBC_LIBS; do
    [ -e /usr/lib64/$l ] && cp -Lp /usr/lib64/$l qemu/lib/$l
done

strip qemu/bin/qemu-execve-aarch64 2>/dev/null || true

# rewrite PT_INTERP in place: "/lib64/ld-linux-x86-64.so.2" (27 chars) ->
# "/mnt/ld.so" (10 chars, the payload mountpoint chosen by
# tools/qemu-cross-runtime), short enough to reuse the existing string
# slot; no section relocation needed
python3 - qemu/bin/qemu-execve-aarch64 <<'PYEOF'
import struct, sys
p = sys.argv[1]
data = bytearray(open(p, 'rb').read())
old = b'/lib64/ld-linux-x86-64.so.2\x00'
new = b'/mnt/ld.so\x00'
if data.count(new) == 1:
    sys.exit(0)  # already patched
assert data.count(old) == 1, 'interp string not found (new qemu build?)'
soff = data.find(old)
e_phoff, = struct.unpack_from('<Q', data, 32)
e_phentsize, e_phnum = struct.unpack_from('<HH', data, 54)
hdr = None
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type, = struct.unpack_from('<I', data, off)
    if p_type == 3:  # PT_INTERP
        p_offset, = struct.unpack_from('<Q', data, off + 8)
        p_filesz, = struct.unpack_from('<Q', data, off + 32)
        assert (p_offset, p_filesz) == (soff, len(old)), \
            'unexpected PT_INTERP phdr'
        hdr = off
assert hdr is not None, 'no PT_INTERP phdr'
data[soff:soff + len(old)] = new + b'\x00' * (len(old) - len(new))
struct.pack_into('<Q', data, hdr + 32, len(new))
open(p, 'wb').write(bytes(data))
PYEOF

# the patched binary only starts via /.qemu-cross/ld.so (i.e. inside the
# container); on the host invoke the loader directly to verify
qemu/ld.so --library-path qemu/lib qemu/bin/qemu-execve-aarch64 --version | head -1
echo "setup-qemu-execve: payload ready in qemu/"
