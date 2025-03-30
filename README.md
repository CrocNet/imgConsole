## Mount ARM/RISC-V .img files to a BASH console.
### Chroot into image rootfs.



* Scans existing directory, and sub directories for .img files.
* Scans removable block devices /dev/
* Manu driven image selection.

#### Usage

Partitions are mounted at /mnt/
`chroot /mnt/rootfs`
`exit` to quit.


#### Options


Optional post-mount script.

    -v post-mount.sh:/post-mount.sh

#### Create bash alias

    alias imgconsole-arm64='docker run --rm -it --privileged --platform linux/arm64 -v /dev:/dev -v "$PWD":/host:ro ghcr.io/crocnet/imgconsole:latest' >> ~/.bashrc
    alias imgconsole-riscv='docker run --rm -it --privileged --platformlinux/riscv -v /dev:/dev -v "$PWD":/host:ro ghcr.io/crocnet/imgconsole:latest' >> ~/.bashrc
    source ~/.bashrc