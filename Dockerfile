# Use Ubuntu 22.04 as the base image
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    util-linux gawk e2fsprogs ntfs-3g dosfstools fdisk file \
    joe tree less whiptail\
    && rm -rf /var/lib/apt/lists/*
  

# Copy the script into the container
COPY mount.sh /
RUN chmod +x /mount.sh

ENTRYPOINT  ["/mount.sh"]

