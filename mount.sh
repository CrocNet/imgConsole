#!/bin/bash

export LS_COLORS='di=34:fi=0:ln=31:pi=5:so=5:bd=5:cd=5:or=31:mi=0:ex=32:*.rpm=90'
echo "export PS1='\[\e[32m\]imgConsole@\[\e[0m\]:\w\$ '" >> ~/.bashrc

STARTOK=false

# Set default value for IMAGE_FILE
IMAGE_FILE="/image.img"

# Check if an argument was provided
if [ $# -gt 0 ]; then
    # Set IMAGE_FILE to the provided argument
    IMAGE_FILE="$1"
fi

# Check if the file exists
if [ ! -f "$IMAGE_FILE" ]; then
    echo "Error: File '$IMAGE_FILE' does not exist"
    echo "docker run --rm -it -v <image file>:/image.img"
    exit 1
fi

set -e

# Function to clean up mounts and loop device
cleanup() {
    if [ "$STARTOK" = false ]; then
      echo "Failed to start. Type 'exit' to end docker session"
      export PS1='\[\e[32m\]imgConsole \e[31mERROR@\[\e[0m\]:\w\$ '
      bash
    fi 
    
    echo "Cleaning up mounts and loop device..."
    
    # Unmount all partitions under /mnt
    for mount_point in /mnt/part*; do
        if [ -d "$mount_point" ]; then
            umount "$mount_point" 2>/dev/null && echo "Unmounted $mount_point"
            rmdir "$mount_point" 2>/dev/null
        fi
    done
    
    # Detach the loop device if it exists
    if [ -n "$LOOP_DEV" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null && echo "Detached $LOOP_DEV"
    fi
}


# Set up the loop device
LOOP_DEV=$(losetup -fP "$IMAGE_FILE" --show)
echo "Loop device set up as: $LOOP_DEV"

# Set trap to call cleanup on script exit (EXIT signal covers normal exit and interruptions)
trap cleanup EXIT INT TERM

# Force partition table rescan
#partprobe "$LOOP_DEV" 2>/dev/null || blockdev --rereadpt "$LOOP_DEV" 2>/dev/null

# Check if partitions are visible
echo "Checking partitions..."
lsblk "$LOOP_DEV"


# Extract partition info
PARTITIONS=$(fdisk -l "$IMAGE_FILE" | grep "^$IMAGE_FILE" | awk '
{
    size = $3;  # Size in sectors
    size_gb = size * 512 / 1024 / 1024 / 1024;  # Convert to GB
    part_num = substr($1, length($1), 1);  # Get partition number
    fstype = $5;  # Filesystem type
    printf "Partition %s %.2f %s\n", part_num, size_gb, fstype
}')

# Store the total number of partitions for "last partition" check
TOTAL_PARTS=$(echo "$PARTITIONS" | wc -l)

# Process each partition
echo "$PARTITIONS" | while read -r line; do
    part_num=$(echo "$line" | awk '{print $2}')
    fstype=$(echo "$line" | awk '{print $4}')
    temp_mount="/mnt/temp_p$part_num"
    final_mount=""

    # Create temporary mount point
    mkdir -p "$temp_mount"
    
    # Mount the partition temporarily
    mount "${LOOP_DEV}p${part_num}" "$temp_mount" 2>/dev/null || continue

    # Check if it's the first partition and looks like a boot partition
    if [ "$part_num" -eq 1 ]; then
        if ls "$temp_mount" | grep -q -E 'boot.sd|vmlinuz|initrd|grub|bootloader|kernel'; then
            final_mount="/mnt/boot"
            echo "Identified Partition $part_num as boot partition"
        fi
    fi

    # Check if it's the last partition and looks like a root filesystem
    if [ "$part_num" -eq "$TOTAL_PARTS" ] && [ -z "$final_mount" ]; then
        if [ -d "$temp_mount/bin" ] && ls "$temp_mount/bin" | grep -q -E 'sh|bash|busybox'; then
            # Check CPU architecture using file command on a binary
            if [ -f "$temp_mount/bin/cp" ]; then
                arch=$(file "$temp_mount/bin/cp" | grep -o -E 'ARM|aarch64|RISC-V|x86-64' | head -n1)
                case "$arch" in
                    "ARM"|"aarch64") final_mount="/mnt/root-arm64" ;;
                    "RISC-V") final_mount="/mnt/root-riscv64" ;;
                    "x86-64") final_mount="/mnt/root-x86_64" ;;
                    *) final_mount="/mnt/root-unknown" ;;
                esac
            else
                final_mount="/mnt/root-unknown"
            fi
            echo "Identified Partition $part_num as rootfs ($arch)"
        fi
    fi

    # Default to partition number if no specific type identified
    if [ -z "$final_mount" ]; then
        final_mount="/mnt/p$part_num"
        echo "No specific type identified for Partition $part_num"
    fi

    # Unmount from temp and remount to final location
    umount "$temp_mount"
    mkdir -p "$final_mount"
    mount "${LOOP_DEV}p${part_num}" "$final_mount"
    echo "Mounted Partition $part_num ($fstype) to $final_mount"

    # Clean up temporary mount point
    rmdir "$temp_mount"
done


echo ""
echo ""
cd /mnt
tree /mnt -L 2
STARTOK=true

if [ -f "/post-mount.sh" ]; then
   source /post-mount.sh
else
   bash
fi
