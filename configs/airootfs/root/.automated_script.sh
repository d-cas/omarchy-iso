#!/usr/bin/env bash
set -euo pipefail

use_omarchy_helpers() {
  export OMARCHY_PATH="/root/omarchy"
  export OMARCHY_INSTALL="/root/omarchy/install"
  export OMARCHY_INSTALL_LOG_FILE="/var/log/omarchy-install.log"
  source /root/omarchy/install/helpers/all.sh
}

run_configurator() {
  set_tokyo_night_colors
  ./configurator
  export OMARCHY_USER="$(jq -r '.users[0].username' user_credentials.json)"
}

install_arch() {
  clear_logo
  gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Installing..."
  echo

  touch /var/log/omarchy-install.log

  start_log_output
  # Disable pipefail temporarily for logging pipeline to prevent sed exit from breaking installation
  set +o pipefail
  install_base_system 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>/var/log/omarchy-install.log
  set -o pipefail
  stop_log_output
}

install_omarchy() {
  chroot_bash -lc "sudo pacman -S --noconfirm --needed gum" >/dev/null
  chroot_bash -lc "source /home/$OMARCHY_USER/.local/share/omarchy/install.sh || bash"
}

# Set Tokyo Night color scheme for the terminal
set_tokyo_night_colors() {
  if [[ $(tty) == "/dev/tty"* ]]; then
    # Tokyo Night color palette
    echo -en "\e]P01a1b26" # black (background)
    echo -en "\e]P1f7768e" # red
    echo -en "\e]P29ece6a" # green
    echo -en "\e]P3e0af68" # yellow
    echo -en "\e]P47aa2f7" # blue
    echo -en "\e]P5bb9af7" # magenta
    echo -en "\e]P67dcfff" # cyan
    echo -en "\e]P7a9b1d6" # white
    echo -en "\e]P8414868" # bright black
    echo -en "\e]P9f7768e" # bright red
    echo -en "\e]PA9ece6a" # bright green
    echo -en "\e]PBe0af68" # bright yellow
    echo -en "\e]PC7aa2f7" # bright blue
    echo -en "\e]PDbb9af7" # bright magenta
    echo -en "\e]PE7dcfff" # bright cyan
    echo -en "\e]PFc0caf5" # bright white (foreground)

    # Set default foreground and background
    echo -en "\033[0m"
    clear
  fi
}

install_base_system() {
  # Initialize and populate the keyring
  pacman-key --init
  pacman-key --populate archlinux

  # Sync the offline database so pacman can find packages
  pacman -Sy --noconfirm

  # Ensure that no mounts exist from past install attempts
  findmnt -R /mnt >/dev/null && umount -R /mnt

  # Patch archinstall to handle missing mkinitcpio.conf (for dracut coexistence)
  # archinstall crashes when it tries to open /mnt/etc/mkinitcpio.conf before packages are installed
  PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  INSTALLER_PY="/usr/lib/python${PYTHON_VER}/site-packages/archinstall/lib/installer.py"

  if [ -f "$INSTALLER_PY" ]; then
    # Backup original
    cp "$INSTALLER_PY" "$INSTALLER_PY.original"

    # Patch using Python
    python3 << EOFPATCH_ARCHINSTALL
import sys

installer_py = "$INSTALLER_PY"

try:
    with open(installer_py, "r") as f:
        lines = f.readlines()

    patched = False
    new_lines = []

    for line in lines:
        # Detect the line that opens mkinitcpio.conf
        if "mkinitcpio.conf" in line and "open(" in line and ("'r+'" in line or '"r+"' in line):
            # Get the actual indentation (preserve tabs/spaces exactly)
            indent_str = line[:len(line) - len(line.lstrip())]
            # Insert file creation code before this line
            new_lines.append(indent_str + "# Dracut coexistence: create mkinitcpio.conf if missing\n")
            new_lines.append(indent_str + "import os\n")
            new_lines.append(indent_str + "_mkinit_path = f'{self.target}/etc/mkinitcpio.conf'\n")
            new_lines.append(indent_str + "if not os.path.exists(_mkinit_path):\n")
            new_lines.append(indent_str + "    os.makedirs(os.path.dirname(_mkinit_path), exist_ok=True)\n")
            new_lines.append(indent_str + "    with open(_mkinit_path, 'w') as _f:\n")
            new_lines.append(indent_str + "        _f.write('''# mkinitcpio configuration\\nMODULES=()\\nBINARIES=()\\nFILES=()\\nHOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)\\nCOMPRESSION=\"zstd\"\\n''')\n")
            patched = True

        new_lines.append(line)

    if patched:
        with open(installer_py, "w") as f:
            f.writelines(new_lines)
        print("Successfully patched archinstall for dracut coexistence", file=sys.stderr)
    else:
        print("WARNING: Could not patch archinstall - mkinitcpio.conf pattern not found", file=sys.stderr)

except Exception as e:
    print(f"ERROR: Failed to patch archinstall: {e}", file=sys.stderr)
    sys.exit(1)
EOFPATCH_ARCHINSTALL

    if [ $? -ne 0 ]; then
        echo "ERROR: archinstall patching failed, aborting installation" >&2
        exit 1
    fi
  fi

  # LUKS DETECTION: Must happen BEFORE archinstall creates the chroot
  # This detects LUKS devices from the live ISO environment and saves the UUID
  # for use by setup-dracut.sh (which runs post-chroot where detection fails)
  echo "BREADCRUMB: Pre-archinstall LUKS detection starting..." >&2

  # Look for LUKS devices by checking user_configuration.json
  # archinstall stores disk encryption config here
  LUKS_UUID=""
  if [ -f "user_configuration.json" ]; then
    # Check if encryption is enabled in the config
    ENCRYPTION_ENABLED=$(jq -r '.disk_config.disk_encryption.encryption_type // empty' user_configuration.json 2>/dev/null || echo "")

    if [ -n "$ENCRYPTION_ENABLED" ] && [ "$ENCRYPTION_ENABLED" != "null" ]; then
      echo "BREADCRUMB: Disk encryption detected in configuration" >&2

      # Get the target disk from config
      TARGET_DISK=$(jq -r '.disk_config.config_type as $type |
        if $type == "manual_partitioning" then
          .disk_config.partitions[0].dev_path
        else
          .disk_config.device_path
        end' user_configuration.json 2>/dev/null || echo "")

      echo "BREADCRUMB: Target disk from config: ${TARGET_DISK}" >&2

      # After archinstall runs, it will create encrypted partitions
      # But we need to detect them NOW by looking at what devices will be encrypted
      # For now, save a marker that encryption is enabled
      echo "encryption_enabled" > /tmp/.luks_marker
      echo "BREADCRUMB: Created encryption marker in /tmp/.luks_marker" >&2
    else
      echo "BREADCRUMB: No disk encryption configured" >&2
    fi
  fi

  # Install using files generated by the ./configurator
  # Skip NTP and WKD sync since we're offline (keyring is pre-populated in ISO)
  archinstall \
    --config user_configuration.json \
    --creds user_credentials.json \
    --silent \
    --skip-ntp \
    --skip-wkd

  # POST-ARCHINSTALL LUKS DETECTION: Now that archinstall created the encrypted device,
  # we can detect the actual LUKS UUID
  echo "BREADCRUMB: Post-archinstall LUKS detection starting..." >&2

  # Always try to detect LUKS, even if marker wasn't created (defense in depth)
  # Check both the marker file AND if /mnt is actually on a /dev/mapper device
  ROOT_DEVICE_CHECK=$(findmnt -n -o SOURCE /mnt 2>/dev/null || echo "")
  if [ -f /tmp/.luks_marker ] || [[ "$ROOT_DEVICE_CHECK" == /dev/mapper/* ]]; then
    echo "BREADCRUMB: Encryption detected (marker or /dev/mapper device), detecting LUKS UUID..." >&2

    # Find the encrypted root device that archinstall just created
    # It should be mounted at /mnt
    ROOT_DEVICE=$(findmnt -n -o SOURCE /mnt 2>/dev/null || echo "")
    echo "BREADCRUMB: Root device mounted at /mnt: ${ROOT_DEVICE}" >&2

    if [[ "$ROOT_DEVICE" == /dev/mapper/* ]]; then
      # This is a mapped device, find its backing LUKS device
      # Strip btrfs subvolume notation (e.g., /dev/mapper/root[/@] -> root)
      MAPPER_NAME=$(basename "$ROOT_DEVICE" | sed 's/\[.*\]//')
      LUKS_DEVICE=$(cryptsetup status "$MAPPER_NAME" 2>/dev/null | grep "device:" | awk '{print $2}')
      echo "BREADCRUMB: LUKS backing device: ${LUKS_DEVICE}" >&2

      if [ -n "$LUKS_DEVICE" ]; then
        LUKS_UUID=$(cryptsetup luksUUID "$LUKS_DEVICE" 2>/dev/null || echo "")

        if [ -n "$LUKS_UUID" ]; then
          echo "$LUKS_UUID" > /tmp/.luks_uuid
          echo "BREADCRUMB: ✓ LUKS UUID detected and saved: ${LUKS_UUID}" >&2

          # Copy to /mnt so it's available in chroot
          cp /tmp/.luks_uuid /mnt/.luks_uuid
          echo "BREADCRUMB: ✓ Copied LUKS UUID to /mnt/.luks_uuid for chroot access" >&2
        else
          echo "BREADCRUMB: WARNING - Failed to get LUKS UUID from ${LUKS_DEVICE}" >&2
        fi
      else
        echo "BREADCRUMB: WARNING - Failed to find LUKS backing device for ${MAPPER_NAME}" >&2
      fi
    else
      echo "BREADCRUMB: Root device is not encrypted (not /dev/mapper/*)" >&2
    fi

    rm /tmp/.luks_marker
  else
    echo "BREADCRUMB: No encryption marker found, skipping LUKS detection" >&2
  fi

  # After archinstall sets up the base system but before our installer runs,
  # we need to ensure the offline pacman.conf is in place
  cp /etc/pacman.conf /mnt/etc/pacman.conf

  # Mount the offline mirror so it's accessible in the chroot
  mkdir -p /mnt/var/cache/omarchy/mirror/offline
  mount --bind /var/cache/omarchy/mirror/offline /mnt/var/cache/omarchy/mirror/offline

  # No need to ask for sudo during the installation (omarchy itself responsible for removing after install)
  mkdir -p /mnt/etc/sudoers.d
  cat >/mnt/etc/sudoers.d/99-omarchy-installer <<EOF
root ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$OMARCHY_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 440 /mnt/etc/sudoers.d/99-omarchy-installer

  # Copy the local omarchy repo to the user's home directory
  mkdir -p /mnt/home/$OMARCHY_USER/.local/share/
  cp -r /root/omarchy /mnt/home/$OMARCHY_USER/.local/share/

  chown -R 1000:1000 /mnt/home/$OMARCHY_USER/.local/

  # Ensure all necessary scripts are executable
  find /mnt/home/$OMARCHY_USER/.local/share/omarchy -type f -path "*/bin/*" -exec chmod +x {} \;
  chmod +x /mnt/home/$OMARCHY_USER/.local/share/omarchy/boot.sh 2>/dev/null || true
  chmod +x /mnt/home/$OMARCHY_USER/.local/share/omarchy/default/waybar/indicators/screen-recording.sh 2>/dev/null || true
}

chroot_bash() {
  HOME=/home/$OMARCHY_USER \
    arch-chroot -u $OMARCHY_USER /mnt/ \
    env OMARCHY_CHROOT_INSTALL=1 \
    OMARCHY_USER_NAME="$(<user_full_name.txt)" \
    OMARCHY_USER_EMAIL="$(<user_email_address.txt)" \
    USER="$OMARCHY_USER" \
    HOME="/home/$OMARCHY_USER" \
    /bin/bash "$@"
}

if [[ $(tty) == "/dev/tty1" ]]; then
  use_omarchy_helpers
  run_configurator
  install_arch
  install_omarchy

  # Copy installation log to the installed system for debugging
  if [ -f /var/log/omarchy-install.log ]; then
    mkdir -p /mnt/var/log
    cp /var/log/omarchy-install.log /mnt/var/log/omarchy-install.log
    echo "Installation log copied to /mnt/var/log/omarchy-install.log"
  fi
fi
