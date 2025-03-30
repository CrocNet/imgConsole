#!/bin/bash

# --- Configuration & Setup ---
export LS_COLORS='di=34:fi=0:ln=31:pi=5:so=5:bd=5:cd=5:or=31:mi=0:ex=32:*.rpm=90'
echo "export PS1='\[\e[32m\]imgConsole@\[\e[0m\]:\w\$ '" >> ~/.bashrc

STARTOK=false
TARGET_PATH=""
IS_BLOCK_DEVICE=false
LOOP_DEV=""

declare -a MOUNTED_PATHS # Keep track of successful primary mounts for cleanup
declare -a PROC_MOUNTS # Keep track of successful /proc mounts


# --- Cleanup Function ---
cleanup() {
    local exit_code=$? # Capture exit code

    if [ "$STARTOK" = false ]; then
      # Only enter interactive shell if the script didn't complete successfully or exited with error
      if [[ "$DEBUG" == "true" && $$ -eq $BASHPID ]]; then # Avoid starting nested shells if trap is called multiple times
          echo "Type 'exit' to end docker DEBUG session" >&2
          export PS1='\[\e[32m\]imgConsole \e[31mERROR@\[\e[0m\]:\w\$ '
          bash # Start interactive shell for debugging
      fi
      # Ensure we exit with a non-zero code if we entered cleanup due to failure
      [ $exit_code -eq 0 ] && exit_code=1
      exit $exit_code
    fi

    echo "Cleaning up mounts..." >&2

    # --- Unmount /proc bind mounts FIRST ---
    echo "Unmounting procfs mounts..." >&2
    for proc_mount_point in "${PROC_MOUNTS[@]}"; do
        if mountpoint -q "$proc_mount_point"; then
            umount "$proc_mount_point" &>/dev/null && echo "Unmounted $proc_mount_point" >&2 || echo "Warn: Failed to unmount procfs at $proc_mount_point" >&2
        # No need to rmdir /proc usually, it should exist on the target fs
        fi
    done

    # --- Unmount primary partition mounts in reverse order ---
    echo "Unmounting primary partitions..." >&2
    for (( idx=${#MOUNTED_PATHS[@]}-1 ; idx>=0 ; idx-- )) ; do
        mount_point="${MOUNTED_PATHS[idx]}"
        if mountpoint -q "$mount_point"; then
            umount "$mount_point" &>/dev/null && echo "Unmounted $mount_point" >&2 || echo "Warn: Failed to unmount $mount_point" >&2
        fi
        # Attempt removal only if it looks like one of our dynamic mounts and exists
        if [[ "$mount_point" == /mnt/* ]] && [ -d "$mount_point" ]; then
             rmdir "$mount_point" &>/dev/null || echo "Warn: Failed to remove directory $mount_point (maybe not empty?)" >&2
        fi
    done

    # Detach the loop device if it exists
    if [ -n "$LOOP_DEV" ] && losetup "$LOOP_DEV" &>/dev/null; then
        echo "Detaching loop device $LOOP_DEV..." >&2
        losetup -d "$LOOP_DEV" &>/dev/null && echo "Detached $LOOP_DEV" >&2 || echo "Warn: Failed to detach $LOOP_DEV" >&2
    fi

    # Exit with the original exit code if cleanup was triggered by an error
    if [ $exit_code -ne 0 ] && [ "$STARTOK" = false ]; then
        exit $exit_code
    fi
}
# Set trap to call cleanup on script exit (EXIT signal covers normal exit and interruptions)
# Use ERR trap as well to catch failures after 'set -e' is active (though mount failures are handled)
trap cleanup EXIT INT TERM ERR

# --- Discovery and Selection Function ---
discover_and_select() {
    local options=()
    local choice

    # --- Discover .img files in /host ---
    echo "Scanning /host for .img files..." >&2
    local img_count=0
    # Temporarily remove 2>/dev/null from find to see errors if any occur
    while IFS= read -r img_file; do
        if [ -f "$img_file" ]; then # Double-check it's a file we can access
             echo "DEBUG: Found image file: $img_file" >&2
             options+=("$img_file" "Image File")
             ((img_count++))
        else
             echo "DEBUG: find listed '$img_file', but it's not a regular file or not accessible?" >&2
        fi
    done < <(find /host -maxdepth 3 -name '*.img' -type f 2>/dev/null) # Put 2>/dev/null back for production if desired
    # Check find exit status (less reliable with process substitution, but worth a try)
    local find_status=${PIPESTATUS[0]}
    if [ $find_status -ne 0 ]; then
        echo "Warning: 'find' command for .img files may have failed (exit status: $find_status)." >&2
    fi
    echo "Found $img_count image file(s) in /host." >&2
    # --- End Image File Discovery ---

    # --- Discover removable block devices ---
    echo "Scanning for removable block devices..." >&2
    local dev_count=0
    # Temporarily remove 2>/dev/null from lsblk to see errors if any occur
    while IFS= read -r line; do
        # Using awk more robustly to handle potential extra spaces
        local kname size device
        kname=$(echo "$line" | awk '{print $1}') # KNAME is always first
        size=$(echo "$line" | awk '{print $NF}')  # SIZE is specified last in -no
        device="/dev/$kname"

        # Basic check if it's a valid block device AND not empty
        if [ -n "$kname" ] && [ -b "$device" ]; then
             echo "DEBUG: Found block device: $device ($size)" >&2
             if [[ ! "$size" = "0B" ]]; then
               options+=("$device" "Removable Drive ($size)")
             fi  
             ((dev_count++))
        else
             echo "DEBUG: lsblk line '$line' parsed, but '/dev/$kname' is not a block device?" >&2
        fi
    # Use lsblk arguments that are less likely to vary with locale/version, redirect stderr
    # Outputting KNAME,RM,TYPE,SIZE ensures we get what we need.
    # Grepping for " 1 disk" assumes RM is the second field (1) and TYPE is the third (disk)
    done < <(lsblk -dno KNAME,RM,TYPE,SIZE 2>/dev/null | grep '[[:space:]]1[[:space:]]\+disk[[:space:]]\+') # More robust grep
    # Check lsblk/grep exit status
    local lsblk_status=${PIPESTATUS[0]}
    local grep_status=${PIPESTATUS[1]}
    if [ $lsblk_status -ne 0 ]; then
        echo "Warning: 'lsblk' command may have failed (exit status: $lsblk_status)." >&2
    fi
    # grep failing (exit 1) is normal if no devices are found, so we don't warn on that specifically.
    echo "Found $dev_count removable block device(s)." >&2
    # --- End Block Device Discovery ---

    if [ ${#options[@]} -eq 0 ]; then
        # Provide more specific feedback
        if [ $img_count -eq 0 ] && [ $dev_count -eq 0 ]; then
             whiptail --msgbox "No .img files found in /host AND no removable drives detected. Ensure /host is mounted correctly if expecting image files." 10 78
        elif [ $img_count -eq 0 ]; then
             whiptail --msgbox "No .img files found in /host. Only removable drives were detected." 9 78
        else # dev_count must be 0
             whiptail --msgbox "No removable drives detected. Only .img files in /host were found." 9 78
        fi
        return 1 # Indicate failure
    fi

    # Debug: Print the final list before whiptail
    echo "DEBUG: Options being passed to whiptail:" >&2
    printf "  '%s' '%s'\n" "${options[@]}" >&2

    # Whiptail sends the choice to stderr, capture it correctly
    choice=$(whiptail --title "Select Target" --menu "Choose an image file or drive to mount:" 20 78 12 \
        "${options[@]}" \
        3>&1 1>&2 2>&3) # stderr(3) -> stdout(1), stdout(1) -> stderr(2), stderr(2) -> stderr(3) == capture stderr(2)

    local exit_status=$? # Capture whiptail exit status

    if [ $exit_status -ne 0 ] || [ -z "$choice" ]; then
        echo "No selection made or cancelled. Exiting." >&2
        return 1 # Indicate failure (user cancelled)
    else
        echo "$choice" # Return the selected path via STDOUT
        return 0 # Indicate success
    fi
}
# --- Argument Handling & Target Determination ---
if [ $# -gt 0 ]; then
    # Argument provided
    TARGET_PATH="$1"
    if [ -b "$TARGET_PATH" ]; then
        echo "Input is a block device: $TARGET_PATH"
        IS_BLOCK_DEVICE=true
    elif [ -f "$TARGET_PATH" ]; then
        echo "Input is a file: $TARGET_PATH"
        IS_BLOCK_DEVICE=false
    else
        echo "Error: Input '$TARGET_PATH' is not a valid block device or file." >&2
        exit 1
    fi
else
    # No argument provided, run discovery
    SELECTED_TARGET=$(discover_and_select)
    select_exit_status=$?
    if [ $select_exit_status -ne 0 ]; then
        exit $select_exit_status # Exit if discovery failed or user cancelled
    fi
    TARGET_PATH="$SELECTED_TARGET"

    # Determine if selected target is block device or file
    if [ -b "$TARGET_PATH" ]; then
        IS_BLOCK_DEVICE=true
        echo "Selected block device: $TARGET_PATH"
    elif [ -f "$TARGET_PATH" ]; then
        IS_BLOCK_DEVICE=false
        echo "Selected image file: $TARGET_PATH"
    else
        # This shouldn't happen if discovery worked correctly, but check anyway
        echo "Error: Selected target '$TARGET_PATH' is not valid." >&2
        exit 1
    fi
fi

# Check if the target exists (redundant for discovery, but good practice)
if [ ! -e "$TARGET_PATH" ]; then
    echo "Error: Target '$TARGET_PATH' does not exist." >&2
    if [ "$IS_BLOCK_DEVICE" = false ]; then
        echo "Usage hint: docker run --rm -it -v <image file path on host>:/host/<image file name> <docker image>" >&2
    else
        echo "Usage hint: Ensure the block device is correctly passed through to the container (e.g., --device=$TARGET_PATH)" >&2
    fi
    exit 1
fi


# --- Device Setup (Loop or Direct) ---
if [ "$IS_BLOCK_DEVICE" = true ]; then
    BASE_DEV="$TARGET_PATH"      # e.g., /dev/sde
    MOUNT_PREFIX="$TARGET_PATH"  # e.g., /dev/sde (partitions are /dev/sde1, /dev/sde2)
    echo "Using direct block device: $BASE_DEV"
else
    IMAGE_FILE="$TARGET_PATH"
    echo "Setting up loop device for: $IMAGE_FILE"
    # Ensure loop module is loaded (might be needed in minimal environments)
    modprobe loop &>/dev/null || echo "Warning: Could not ensure loop module is loaded." >&2
    LOOP_DEV=$(losetup -fP "$IMAGE_FILE" --show)
    if [ -z "$LOOP_DEV" ] || [ ! -b "$LOOP_DEV" ]; then
        echo "Error: Failed to set up loop device for $IMAGE_FILE" >&2
        losetup -a # Show current loop devices for debugging
        exit 1
    fi
    BASE_DEV="$LOOP_DEV"         # e.g., /dev/loop0
    MOUNT_PREFIX="${LOOP_DEV}p" # e.g., /dev/loop0p (partitions are /dev/loop0p1, /dev/loop0p2)
    echo "Loop device set up as: $LOOP_DEV"
fi


# --- Partition Processing ---
# (Wait and initial lsblk remain unchanged)
echo "Waiting for device nodes..." >&2
sleep 2

echo "Checking partitions on $BASE_DEV..."
lsblk "$BASE_DEV" || { echo "Warning: lsblk failed for $BASE_DEV"; }

# (Partition number extraction remains unchanged)
echo "Attempting to extract partitions using fdisk..." >&2
PARTITIONS_RAW=$(LANG=C fdisk -l "$BASE_DEV" 2>/dev/null | grep "^${BASE_DEV}[p0-9]" || true)
echo "Raw fdisk lines matching partitions:" >&2
echo "${PARTITIONS_RAW}" >&2
echo "--- End Raw fdisk lines ---" >&2
PARTITIONS=$(echo "${PARTITIONS_RAW}" | awk -v base_dev_pattern="^${BASE_DEV}p?" '
    $0 ~ base_dev_pattern {
        device = $1; sub(base_dev_pattern, "", device);
        if (device ~ /^[0-9]+$/) { print device; }
    }
')
awk_exit_status=$?
if [ $awk_exit_status -ne 0 ]; then echo "ERROR: awk command failed." >&2; fi
PARTITIONS=$(echo "$PARTITIONS" | tr '\n' ' ' | sed 's/^[ \t]*//;s/[ \t]*$//')
echo "Extracted partition numbers: [${PARTITIONS}]" >&2

# (Handling for no partitions found remains unchanged)
if [ -z "$PARTITIONS" ]; then
    echo "Warning: Could not find any valid partitions on $BASE_DEV using fdisk/awk." >&2
    fstype=$(lsblk -fno FSTYPE "$BASE_DEV" | head -n1)
    if [ -n "$fstype" ]; then
        echo "Attempting to mount $BASE_DEV directly (assuming single filesystem: $fstype)..." >&2
        mount_point="/mnt/fs"
        mkdir -p "$mount_point"
        if mount "$BASE_DEV" "$mount_point"; then
             actual_mount_options=$(mount | grep " on ${mount_point} type ")
             echo "Mounted: ${actual_mount_options}"
             MOUNTED_PATHS+=("$mount_point")
        elif mount -o ro "$BASE_DEV" "$mount_point"; then
             actual_mount_options=$(mount | grep " on ${mount_point} type ")
             echo "Mounted read-only: ${actual_mount_options}" >&2
             MOUNTED_PATHS+=("$mount_point")
        else
             echo "Error: Failed to mount $BASE_DEV directly (tried rw and ro)." >&2
             dmesg | tail -n 10
             rmdir "$mount_point" 2>/dev/null || true
        fi
    fi
else
    # --- Process Found Partitions ---
    echo "Found partition numbers: $PARTITIONS"
    TOTAL_PARTS=$(echo "$PARTITIONS" | wc -w)
    echo "Total partitions found: $TOTAL_PARTS" >&2
    CURRENT_PART_INDEX=0

    for part_num in $PARTITIONS; do
        CURRENT_PART_INDEX=$((CURRENT_PART_INDEX + 1))
        partition_device="${MOUNT_PREFIX}${part_num}"
        echo "Processing Partition $part_num ($partition_device)..."

        # (Device node check remains unchanged)
        if [ ! -b "$partition_device" ]; then
             echo "Warning: Partition device node $partition_device not found. Checking again..." >&2; sleep 1
             if [ ! -b "$partition_device" ]; then echo "Error: Partition node $partition_device still not found. Skipping." >&2; lsblk "$BASE_DEV"; continue; fi
        fi

        # (Filesystem type detection remains unchanged)
        fstype=$(lsblk -fno FSTYPE "$partition_device" | head -n1)
        echo "Detected filesystem type: ${fstype:-'Unknown/Unformatted'}"

        # (Determining final_mount based on content check remains unchanged)
        final_mount=""
        arch="unknown"
        temp_check_mount="/mnt/check_p$part_num"; mkdir -p "$temp_check_mount"
        if mount -o ro "$partition_device" "$temp_check_mount" &>/dev/null; then
            if [ "$CURRENT_PART_INDEX" -eq 1 ]; then
                if ls "$temp_check_mount" | grep -q -E -i 'efi|boot.sd|vmlinuz|initrd|grub|bootloader|kernel|u-boot|extlinux'; then
                    final_mount="/mnt/boot"; echo "Identified Partition $part_num as potential boot partition"
                fi
            fi
            if [ "$CURRENT_PART_INDEX" -eq "$TOTAL_PARTS" ] && [ -z "$final_mount" ]; then
                if [ -d "$temp_check_mount/etc" ] && [ -d "$temp_check_mount/bin" ] && ls "$temp_check_mount/bin"/*sh "$temp_check_mount/sbin"/*sh "$temp_check_mount/bin/busybox" &>/dev/null; then
                    for bin_path in "$temp_check_mount/bin/sh" "$temp_check_mount/bin/bash" "$temp_check_mount/usr/bin/coreutils" "$temp_check_mount/bin/ls" "$temp_check_mount/bin/cp"; do
                       if [ -f "$bin_path" ] && [ -x "$bin_path" ]; then
                           arch_output=$(file "$bin_path"); if echo "$arch_output" | grep -q -E 'ARM|aarch64'; then arch="arm64"; break; fi
                           if echo "$arch_output" | grep -q -E 'RISC-V'; then arch="riscv64"; break; fi; if echo "$arch_output" | grep -q -E 'x86-64'; then arch="x86_64"; break; fi
                           if echo "$arch_output" | grep -q -E '80386|IA-32'; then arch="x86"; break; fi
                       fi
                    done
                    final_mount="/mnt/root-${arch}"; echo "Identified Partition $part_num as potential rootfs ($arch)"
                fi
            fi
            umount "$temp_check_mount" &>/dev/null
        else echo "Warning: Could not mount $partition_device read-only for content check." >&2; fi
        rmdir "$temp_check_mount" 2>/dev/null || true

        if [ -z "$final_mount" ]; then final_mount="/mnt/p$part_num"; echo "No specific type identified for Partition $part_num, using default mount point."; fi

        # --- Final Mount Logic ---
        mkdir -p "$final_mount"
        mount_options=""; mount_mode="read-write"
        if [ "$final_mount" == "/mnt/boot" ]; then
            echo "Requesting read-only mount for boot partition $partition_device to $final_mount..."; mount_options="-o ro"; mount_mode="read-only"
        else echo "Requesting read-write mount for partition $partition_device to $final_mount..."; fi

        if mount $mount_options "$partition_device" "$final_mount"; then
            actual_mount_options=$(mount | grep " on ${final_mount} type ")
            echo "Successfully mounted: ${actual_mount_options}"
            MOUNTED_PATHS+=("$final_mount") # Record successful primary mount

            if [[ "$mount_mode" == "read-write" && "$actual_mount_options" == *"(ro"* ]]; then
                echo "Warning: Filesystem on $partition_device mounted read-only by system." >&2; echo "Check fs status or dmesg." >&2
            fi

            # --- >>> Mount /proc if this is a rootfs <<< ---
            if [[ "$final_mount" == /mnt/root-* ]]; then
                proc_target="${final_mount}/proc"
                echo "Attempting to bind mount /proc to $proc_target (read-only)..."
                # Ensure target directory exists inside the mounted rootfs
                mkdir -p "$proc_target"
                # Perform the bind mount
                if mount --bind /proc "$proc_target"; then
                    # Remount the bind mount as read-only
                    if mount -o remount,ro,bind "$proc_target"; then
                        echo "Successfully mounted /proc read-only to $proc_target"
                        PROC_MOUNTS+=("$proc_target") # Record successful proc mount
                    else
                        echo "Warning: Failed to remount $proc_target as read-only. Unmounting..." >&2
                        umount "$proc_target" &>/dev/null
                    fi
                else
                    echo "Warning: Failed to bind mount /proc to $proc_target." >&2
                    # Cleanup the directory if we created it and mount failed
                    # Check if it's empty before removing - defensive programming
                    [ -d "$proc_target" ] && find "$proc_target" -maxdepth 0 -empty -exec rmdir {} \;
                fi
            fi
            # --- >>> End /proc mount <<< ---

        else
            # Handle primary mount failure
            mount_exit_status=$?; echo "Error: Failed to mount $partition_device to $final_mount (Exit: $mount_exit_status)." >&2
            echo "Checking dmesg..."; dmesg | tail -n 15; rmdir "$final_mount" 2>/dev/null || true
            echo "Skipping partition $part_num due to mount failure."; continue
        fi

    done # End partition loop
fi # End check for partitions found


# --- Final Steps ---
# (This section remains unchanged)
echo ""; echo "Mounting process complete. Final structure:"; echo ""
cd /mnt || echo "Warning: Could not cd into /mnt" >&2
if command -v tree > /dev/null; then tree /mnt -L 2; else ls -lR /mnt; fi

STARTOK=true # Signal success

if [ -f "/post-mount.sh" ]; then
   echo "Executing /post-mount.sh..."; ( source /post-mount.sh ); post_mount_exit_status=$?
   echo "/post-mount.sh finished with exit status $post_mount_exit_status"
else
   bash
   echo "Interactive shell finished." >&2
fi

exit 0 # Cleanup called via EXIT trap