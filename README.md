# dualboot-bluetooth-sync

When Linux and Windows are both paired with the same Bluetooth device, they usually store different pairing keys. That often means your headphones, keyboard, mouse, or controller work in one OS but need to be re-paired in the other.

This script syncs Bluetooth pairing keys between a Windows installation and the local BlueZ device data on Linux, so dual-boot setups are less annoying.

Background and manual approach:

- Arch Wiki: <https://wiki.archlinux.org/title/Bluetooth#Dual_boot_pairing>

Usage:

```bash
# Without nix
chmod +x ./sync-bluetooth-keys.sh
sudo ./sync-bluetooth-keys.sh

# Recommended for BLE keyboards that already work in Linux:
# copy Linux BlueZ keys into the Windows registry
sudo ./sync-bluetooth-keys.sh --to-windows

# With nix
sudo nix run
```

Modes:

- `--to-linux` copies keys from Windows into Linux BlueZ data. This is the default.
- For BLE devices, `--to-linux` updates the standard BlueZ `LongTermKey` fields and leaves extra device-specific sections intact.
- `--to-windows` copies keys from Linux BlueZ data into the Windows registry. This is often the better direction for BLE keyboards and devices with device-specific BlueZ key layouts.

Disclaimer:

- This project was fully vibecoded.
- It modifies local Bluetooth pairing data as root. Check the script before running it, and keep backups if you care about the current state.
