# Token Extraction Guide

OpenPlaudit authenticates with the PLAUD Note over BLE using a 32-character hex binding token. This token is **not** the device serial number — it is set during initial device pairing through the PLAUD cloud API and stored by the PLAUD mobile app.

There are two paths to obtain this token: extracting it from an existing iPhone backup, or factory-resetting the device and capturing the token during a fresh bind.

## Option A: Extract from iPhone Backup

This is the non-destructive approach. It preserves all existing recordings and cloud data.

### Prerequisites

- macOS with Finder or Apple Configurator 2
- An iPhone with the PLAUD app installed and paired to your device
- Enough disk space for a full iPhone backup (~20–60 GB)

### Steps

1. **Connect your iPhone to your Mac** via USB cable.

2. **Create an unencrypted backup.**
   - In Finder, select your iPhone, go to the General tab.
   - Uncheck "Encrypt local backup" (if checked, you'll need to enter your backup password to disable it).
   - Click "Back Up Now" and wait for it to complete.

3. **Locate the backup directory.**

   ```bash
   ls ~/Library/Application\ Support/MobileSync/Backup/
   ```

   The most recently modified directory is your backup.

4. **Search for the PLAUD app's stored token.**

   The PLAUD Flutter app stores its binding data in its app container. The token is typically found in a plist or SQLite database within the app's data. Search for it:

   ```bash
   BACKUP_DIR=~/Library/Application\ Support/MobileSync/Backup/<your-backup-id>

   # Search for the token in plist files
   find "$BACKUP_DIR" -name "*.plist" -exec sh -c '
     if plutil -p "$1" 2>/dev/null | grep -qi "token\|plaud\|ble"; then
       echo "=== $1 ==="
       plutil -p "$1" | grep -i "token\|plaud\|ble"
     fi
   ' _ {} \;

   # Search in SQLite databases
   find "$BACKUP_DIR" -name "*.sqlite*" -exec sh -c '
     tables=$(sqlite3 "$1" ".tables" 2>/dev/null)
     if echo "$tables" | grep -qi "plaud\|device\|token\|ble"; then
       echo "=== $1 ==="
       echo "$tables"
     fi
   ' _ {} \;
   ```

5. **Identify the 32-character hex token.**

   The token is a 32-character lowercase hexadecimal string (e.g., `00112233445566778899aabbccddeeff`). It will typically be stored alongside the device serial number or BLE address in the PLAUD app's local database.

   Common locations:
   - A SharedPreferences-style plist (Flutter stores these as plists on iOS)
   - A local SQLite database used by the PLAUD SDK

6. **Configure OpenPlaudit with the token.**

   ```bash
   plaude config set device.token "your_extracted_token"
   ```

### Backup Cleanup

After extracting the token, you can delete the backup to reclaim disk space:
- In Finder, go to your iPhone's General tab and click "Manage Backups"
- Right-click the backup and select "Delete Backup"

If you re-enable encrypted backups, the token extraction approach will not work on future backups unless you decrypt them first.

## Option B: Factory Reset and Fresh Bind

This is the destructive approach. It erases all recordings on the device and unbinds it from the PLAUD cloud account. Use this only if Option A fails or if you don't need existing data.

### Steps

1. **Factory reset the PLAUD Note.**
   - Hold the power button for 10+ seconds until the LED blinks rapidly.
   - The device is now unbound and in pairing mode.

2. **Capture the binding token during pairing.**

   When an unbound device is paired, the PLAUD app obtains a token from the cloud API and sends it to the device over BLE. To capture this:

   **Method 1: Use the demo SDK token (simplest)**

   For an unbound device, the Android demo SDK uses the device serial number as the token. If the device has just been factory-reset:

   ```bash
   # The serial number is printed on the device or visible in BLE Device Info service
   plaude config set device.token "$(printf '%-32s' 'YOUR_SERIAL_NUMBER' | tr ' ' '0')"
   ```

   Note: This only works for unbound devices. Once you pair with the official PLAUD app, the token changes to a cloud-issued one.

   **Method 2: Intercept the binding API call**

   Set up a VPN-level proxy (e.g., Charles Proxy with iOS VPN profile) before pairing:

   - Configure Charles Proxy with SSL proxying enabled for `api.plaud.ai`
   - Install the Charles root certificate on your iPhone
   - Enable the Charles VPN profile on iPhone
   - Open the PLAUD app and pair the device
   - In Charles, look for `POST /api/devices/bind` — the response contains the binding token
   - Note: Standard HTTP proxy settings won't work because the Flutter app bypasses iOS system proxy

3. **Configure OpenPlaudit with the captured token.**

   ```bash
   plaude config set device.token "captured_token_here"
   ```

## Finding Your Device Address

The device address is a macOS CoreBluetooth UUID, not a standard MAC address. Use OpenPlaudit to find it:

```bash
plaude scan
```

This returns the UUID for each discovered PLAUD device. Copy the address into your config:

```bash
plaude config set device.address "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
```

## Verifying the Token

After configuring both address and token, verify they work:

```bash
plaude list
```

If authentication succeeds, you'll see a list of recordings on the device. If you see "Handshake failed", the token is incorrect.

## Troubleshooting

**"TOKEN_NOT_MATCH" error**: The token you extracted is not the current binding token. This can happen if the device was re-paired after the backup was created. Create a fresh backup and extract again.

**Encrypted backup**: If your iPhone backup is encrypted, you'll need to either disable encryption and create a new backup, or use a tool like `iphone-backup-decrypt` to decrypt it first.

**Device in use by PLAUD app**: The PLAUD Note can only maintain one BLE connection at a time. Close the PLAUD app completely (force-quit) before using OpenPlaudit.

**Serial number as token doesn't work**: The device has been cloud-bound. You need the cloud-issued token, not the serial number. Use Option A or the proxy interception method in Option B.
