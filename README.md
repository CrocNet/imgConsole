## Mount ARM/RISC-V .img files to a BASH console.
### Chroot into image rootfs.



#### ARM
    IMAGE="myimage.img"
    docker run --rm -it --privileged --platform linux/arm64 -v /dev:/dev -v $IMAGE:/image.img ghcr.io/CrocNet/imgConsole:latest

#### RISC-V
    IMAGE="myimage.img"
    docker run --rm -it --privileged --platform linux/riscv -v /dev:/dev -v $IMAGE:/image.img ghcr.io/CrocNet/imgConsole:latest

#### Usage

Partitions are mounted at /mnt/
`chroot /mnt/rootfs`
`exit` to quit.


#### Options


Add option to exchange bash console for your own script.

    -v post-mount.sh:/post-mount.sh

#### Create bash alias

    alias imgconsole-arm64='docker run --rm -it --privileged --platform linux/arm64 -v /dev:/dev -v "$1":/image.img imgconsole:latest' >> ~/.bashrc
    alias imgconsole-riscv64='docker run --rm -it --privileged --platform linux/arm64 -v /dev:/dev -v "$1":/image.img imgconsole:latest' >> ~/.bashrc
    source ~/.bashrc