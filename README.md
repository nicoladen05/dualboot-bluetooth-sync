# dualboot-bluetooth-sync

When Linux and Windows are both paired with the same Bluetooth device, they usually store different pairing keys. That often means your headphones, keyboard, mouse, or controller work in one OS but need to be re-paired in the other.

This script copies the Bluetooth keys from a Windows installation into the local BlueZ device data on Linux, so dual-boot setups are less annoying.

Background and manual approach:

- Arch Wiki: <https://wiki.archlinux.org/title/Bluetooth#Dual_boot_pairing>

Usage:

```bash
# Without nix
chmod +x ./sync-bluetooth-keys.sh
sudo ./sync-bluetooth-keys.sh

# With nix
sudo nix run
```

Disclaimer:

- This project was fully vibecoded.
- It modifies local Bluetooth pairing data as root. Check the script before running it, and keep backups if you care about the current state.
