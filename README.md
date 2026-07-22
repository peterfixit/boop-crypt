# Boop Crypt GUI 1.1.1

Boop Crypt GUI encrypts and decrypts a file or folder using a separate reusable
image, file or generated 'boop-key.bin' carrier. The GUI provides encryption and
compression choices, an optional carrier password, dependency controls,
sample-based size estimates and live console output.

Version 1.1.0 added the polished dark interface shared with Uppy and Mounty:
sidebar navigation, compact workflow cards, a visual dependency dashboard and
a dedicated full-height activity log. Version 1.1.1 adds desktop-native file
choosers with remembered source and carrier locations.

## Run the AppImage

    chmod +x Boop-Crypt-GUI-1.1.1-x86_64.AppImage
    ./Boop-Crypt-GUI-1.1.1-x86_64.AppImage

If FUSE is not available:

    ./Boop-Crypt-GUI-1.1.1-x86_64.AppImage --appimage-extract-and-run

## File chooser

Boop Crypt automatically uses the full KDE file chooser through KDialog when
available. On GTK desktops it uses Zenity, and minimal systems fall back to the
built-in Tk chooser. The native choosers provide desktop places, bookmarks,
recent folders, previews and mounted network locations. KDialog and Zenity are
optional
because the built-in fallback always remains available.

## Encrypt

1. Select **Encrypt a file or folder**.
2. Choose the input file or folder.
3. Select the encryption method.
4. Enable or disable compression and choose XZ, Zstandard or Gzip.
5. Select an existing carrier/image or choose **Create a .bin carrier**.
6. Optionally enter a carrier password.
7. Review the estimated size and select **Encrypt**.

If the .bin carrier path is blank, 'boop-key.bin' is created beside the
encrypted package. The original source is removed only when the encrypted
package, compression stream, SHA-256 checksums, full decryption test and carrier
update have all succeeded.

## Decrypt

1. Select **Decrypt a .boopcrypt package**.
2. Choose the encrypted package.
3. Choose its separate carrier.
4. Enter the carrier password if one was set.
5. Select **Decrypt**.

The encrypted package is removed only after the original payload has been
verified and restored.

## Methods

Encryption choices:

- AES-256 (recommended and the Boop Crypt 1.0.0 default)
- Camellia-256
- Twofish
- AES-192
- AES-128

Compression choices:

- XZ -9e, SHA-256 stream check and automatic threads
- Zstandard level 10 with automatic threads
- Gzip level 9
- No compression

AES-256 with XZ writes the original Boop Crypt beta2 package pipeline and is
compatible with the Boop Crypt 1.0.0 CLI. Other choices use the extended gui1
package pipeline inside the same version-4 carrier format and should be
decrypted with this GUI.

## Carrier and password

The carrier holds the reusable random encryption key and a package list.
Multiple encrypted packages can share one carrier. Keep the carrier separate
from the encrypted package because losing it makes the encrypted package
unrecoverable.

The optional password encrypts the random key stored inside the carrier. It is
separate from the encryption key and is never written to the console. An
unprotected carrier contains the key needed to decrypt its tracked packages, so
store it securely.

## Runtime dependencies

The AppImage includes the GUI and Python runtime. It uses these host commands:

- gpg
- tar
- xz
- gzip
- zstd

Use **Test Dependencies** in the app. **Install Dependencies** supports Arch /
CachyOS, Debian / Ubuntu and Fedora / Nobara through graphical pkexec
authentication.

Manual install commands:

    # Arch / CachyOS
    sudo pacman -S --needed gnupg tar xz gzip zstd

    # Debian / Ubuntu
    sudo apt install gnupg tar xz-utils gzip zstd

    # Fedora / Nobara
    sudo dnf install gnupg2 tar xz gzip zstd

## Run from source

Python 3.11 or newer with Tk 8.6 is required. The launcher creates a private
`.venv`, updates its packaging tools, installs this source tree in editable mode,
checks the five host runtime commands and starts the GUI.

    chmod +x run-from-source.sh
    ./run-from-source.sh

The virtual environment remains inside the extracted source folder, so it does
not modify the system Python installation. To rebuild it from scratch, remove
the `.venv` folder and run the launcher again.

## Test

    PYTHONPATH=src python3 -m unittest discover -s tests -v

The integration tests perform real GnuPG encryption and decryption, verify a
wrong-password failure, round-trip a file through AES-256/XZ and round-trip a
folder through AES-192/Gzip.

## Build the AppImage

Install Python, Tk, venv and curl, then run:

    chmod +x build-appimage.sh
    ./build-appimage.sh

The builder creates the AppImage and its SHA-256 checksum in dist-appimage/.

## Build the source archives

Run the source release builder to create both `.tar.gz` and `.zip` packages,
plus individual and combined SHA-256 checksum files:

    chmod +x build-source-release.sh
    ./build-source-release.sh

The source packages are written to `dist-source/` and exclude virtual
environments, build caches and generated AppImage files.

## Licence

MIT License. Copyright (c) 2026 Peter George Haworth.
