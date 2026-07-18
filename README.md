# boop-crypt
 boop-crypt - compress and encrypt, or decrypt and decompress, a file or folder using a reusable image or binary carrier


BOOP CRYPT 1.0.0
================

Install or update:
  chmod +x boop-crypt-1.0.0.sh
  ./boop-crypt-1.0.0.sh --install -verbose
  hash -r

Check version:
  boop-crypt --version

Expected output:
  boop-crypt 1.0.0

Normal use:
  1. Put one file or folder in /mnt/crypt.
  2. Optionally add an image carrier. If none is present, boop-key.bin is made.
  3. Run boop-crypt, optionally with -v, -verbose, or --verbose.

Help:
  boop-crypt -h
  man boop-crypt

Licence:
  MIT License. Copyright (c) 2026 Peter George Haworth.
  The full licence is included at the top of the script and in LICENSE.
