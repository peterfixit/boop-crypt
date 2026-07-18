#!/usr/bin/env bash
#
# MIT License
#
# Copyright (c) 2026 Peter George Haworth
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# boop-crypt.sh
# Version: 1.0.0
#
# Self-installing file/folder encryption utility for Linux.
# Final command after installation: boop-crypt

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly PROGRAM="boop-crypt"
readonly PROGRAM_VERSION="1.0.0"
readonly SYSTEM_BIN="${BOOP_CRYPT_SYSTEM_BIN:-/usr/local/bin/boop-crypt}"
readonly SYSTEM_MAN="${BOOP_CRYPT_SYSTEM_MAN:-/usr/local/share/man/man1/boop-crypt.1}"
readonly CRYPT_DIR="${BOOP_CRYPT_DIR:-/mnt/crypt}"
readonly LOCK_FILE="${CRYPT_DIR}/.boop-crypt.lock"
readonly AUTO_CARRIER_NAME="boop-key.bin"
readonly PACKAGE_S2K_COUNT="1048576"
readonly PASSWORD_WRAP_S2K_COUNT="65011712"

CURRENT_STEP="starting"
TEMP_DIR=""
MAN_TEMP=""
PACKAGE_MANAGER=""
MODE=""
PAYLOAD_PATH=""
CARRIER_FILE=""
AUTO_CREATE_CARRIER=0
CARRIER_HAS_RECORD=0
CARRIER_IS_IMAGE=0
RECORD_JSON=""
META_JSON=""
PACKAGES_JSON=""
ENCRYPTED_ENTRIES=()
VERBOSE=0

if [[ -t 1 ]]; then
    readonly C_GREEN=$'\033[1;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_RED=$'\033[1;31m'
    readonly C_BLUE=$'\033[1;34m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_RED=""
    readonly C_BLUE=""
    readonly C_RESET=""
fi

info()    { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
success() { printf '%s[SUCCESS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
verbose() {
    (( VERBOSE == 1 )) || return 0
    printf '%s[VERBOSE]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}
die()     { trap - ERR; printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

cleanup() {
    local rc=$?
    if [[ -n "$MAN_TEMP" && -e "$MAN_TEMP" ]]; then
        rm -f -- "$MAN_TEMP"
    fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
    return "$rc"
}

unexpected_error() {
    local line="$1"
    local rc="$2"
    trap - ERR
    printf '%s[FAIL]%s %s failed (exit %s, script line %s).\n' \
        "$C_RED" "$C_RESET" "$CURRENT_STEP" "$rc" "$line" >&2
    exit "$rc"
}

trap cleanup EXIT
trap 'unexpected_error "$LINENO" "$?"' ERR
trap 'die "Interrupted during: ${CURRENT_STEP}. No successful completion was recorded."' INT TERM HUP

show_help() {
    cat <<'HELP'
boop-crypt 1.0.0

Usage:
  boop-crypt [-v | -verbose | --verbose]
  boop-crypt --install [-v | -verbose | --verbose]
  boop-crypt -h | --help
  boop-crypt --version

Normal operation:
  1. Put one file or folder to encrypt in /mnt/crypt.
  2. Optionally put a carrier image in /mnt/crypt.
  3. Run: boop-crypt

Encryption:
  - TAR archives the payload.
  - XZ -9e compresses it before encryption and uses all available threads.
  - GnuPG encrypts the compressed archive with a random key.
  - You are asked to create an optional carrier password.
  - If a password is entered, it wraps the random key. The password itself is
    not stored as readable text.
  - If no image is available, boop-key.bin is generated with random printable
    junk and the carrier record appended to it.

Carrier reuse:
  - An image or boop-key.bin containing an existing Boop Crypt record is reused.
  - Its random encryption key and password policy are reused.
  - Multiple encrypted packages may be tracked by one carrier.

Decryption:
  - If the carrier is password-protected, the password is requested.
  - The package is decrypted, XZ-decompressed and restored.
  - The reusable carrier and its remaining package records are retained.

Options:
  -v, -verbose, --verbose
              Display detailed scan, carrier-selection, compression,
              encryption, verification and commit progress. Passwords and
              encryption keys are never printed.
  --install   Install/update the command, dependencies, man page and /mnt/crypt.
  --version   Display the version.
  -h, --help  Display this help.

Documentation:
  man boop-crypt
HELP
}

show_version() {
    printf '%s %s\n' "$PROGRAM" "$PROGRAM_VERSION"
}

as_root() {
    if (( EUID == 0 )); then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -- "$@"
    else
        die "Administrator access is required, but sudo is not installed."
    fi
}

script_path() {
    local source_path="${BASH_SOURCE[0]}"
    if command -v readlink >/dev/null 2>&1; then
        readlink -f -- "$source_path" 2>/dev/null || printf '%s\n' "$source_path"
    else
        printf '%s\n' "$source_path"
    fi
}

write_man_page() {
    local destination="$1"
    cat > "$destination" <<'MANPAGE'
.TH BOOP-CRYPT 1 "July 2026" "boop-crypt 1.0.0" "User Commands"
.SH NAME
boop-crypt \- compress and encrypt, or decrypt and decompress, a file or folder using a reusable image or binary carrier
.SH SYNOPSIS
.B boop-crypt
.RB [ -v | -verbose | --verbose ]
.br
.B boop-crypt --install
.RB [ -v | -verbose | --verbose ]
.br
.B boop-crypt -h
.br
.B boop-crypt --version
.SH DESCRIPTION
.B boop-crypt
archives one payload with tar, compresses the archive with multithreaded XZ preset -9e, then encrypts it with GnuPG AES-256 using a randomly generated encryption key.
.PP
The random encryption key is stored in a reusable carrier record appended to an image or to an automatically generated
.IR boop-key.bin .
At encryption time, the user is asked to create an optional password. When supplied, that password encrypts the separate random encryption key. The password is not stored as readable plaintext. A protected carrier requests the password before it can encrypt another payload or decrypt an existing package.
.PP
One carrier may track multiple encrypted packages. Existing Alpha 1, Beta 1 and earlier Beta 2 carrier records are accepted and migrated when practical.
.SH WORKING DIRECTORY
The default working directory is
.IR /mnt/crypt .
It is created with mode 0700 and owned by the invoking user.
.PP
For encryption, place exactly one unencrypted payload in the directory. Existing encrypted packages may remain there when the selected carrier already tracks them.
.PP
For decryption, leave no unencrypted payload in the directory. If more than one tracked package is present, boop-crypt displays a numbered selection prompt.
.SH CARRIER SELECTION
An existing file containing a valid Boop Crypt carrier record is preferred and reused. Only one recorded carrier may be present.
.PP
For a new carrier, an image named
.I boop-key.jpg
(or PNG, GIF, BMP, WebP or TIFF equivalent) is preferred. Otherwise the only suitable image is used when another item is clearly the payload.
.PP
If no separate image is available, boop-crypt creates
.I /mnt/crypt/boop-key.bin
with random printable junk followed by the carrier record. This file is created with mode 0600.
.SH PASSWORDS
At initial encryption, boop-crypt asks:
.PP
.RS
Create optional carrier password (leave blank for none):
.RE
.PP
A non-empty password must be entered twice. The password wraps the separate random encryption key using GnuPG symmetric AES-256 protection. The carrier stores the wrapped key and an indicator that password protection is enabled; it does not store the readable password.
.PP
When a protected carrier is reused, the current carrier password is required. Decryption permits three password attempts before failing without modifying the package or carrier.
.PP
When an unprotected carrier is reused for another encryption, the user is again offered the option to add password protection. Adding a password wraps the existing random key, so previously tracked packages remain decryptable through the same carrier.
.SH ENCRYPTION PIPELINE
.IP 1. 3
Validate the workspace and carrier.
.IP 2.
Create and validate a tar archive of the payload.
.IP 3.
Compress it with XZ -9e, SHA-256 stream checking and automatic multithreading.
.IP 4.
Generate or unlock the reusable random encryption key.
.IP 5.
Encrypt the compressed archive with GnuPG AES-256 and disabled internal compression.
.IP 6.
Decrypt and decompress temporary verification copies and compare them byte-for-byte.
.IP 7.
Update the carrier package list and commit the encrypted package.
.IP 8.
Remove the original payload only after successful end-to-end verification.
.SH DECRYPTION PIPELINE
.IP 1. 3
Read the carrier and request its password when protected.
.IP 2.
Verify the selected encrypted package SHA-256 digest.
.IP 3.
Decrypt the package.
.IP 4.
Verify and decompress the XZ archive.
.IP 5.
Validate archive paths and restore the original payload.
.IP 6.
Remove the restored package from the reusable carrier list and delete the encrypted package.
.SH OPTIONS
.TP
.BR -v , " -verbose" , " --verbose"
Display detailed workspace scanning, carrier selection, compression, encryption, verification and commit progress. Passwords and encryption keys are never displayed.
.TP
.B --install
Install or overwrite
.IR /usr/local/bin/boop-crypt ,
install this manual page, install missing dependencies using apt, pacman or dnf, create
.IR /mnt/crypt ,
and exit.
.TP
.B --version
Display the program version.
.TP
.BR -h , " --help"
Display command help.
.SH LICENSE
MIT License.
.PP
Copyright (c) 2026 Peter George Haworth.
.PP
Permission is granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, subject to inclusion of the copyright and permission notice. The software is provided without warranty of any kind.
.SH SECURITY
The optional password and the encryption key are separate values. Without a password, the random encryption key is recoverable directly from the carrier. With a password, the carrier stores only a GnuPG-encrypted form of that random key.
.PP
Anyone possessing an unprotected carrier and a tracked encrypted package can decrypt it. Anyone possessing a password-protected carrier, its password and a tracked package can decrypt it. Keep carriers and packages separate when confidentiality matters.
.PP
The appended carrier record is concealment, not robust steganography. Re-saving, resizing, optimising or converting an image can remove the record.
.SH EXIT STATUS
Zero indicates success. A non-zero value indicates validation, installation, password, encryption, decryption, verification or cleanup failure.
.SH FILES
.TP
.I /usr/local/bin/boop-crypt
Installed command.
.TP
.I /usr/local/share/man/man1/boop-crypt.1
Manual page.
.TP
.I /mnt/crypt
Default working directory.
.TP
.I /mnt/crypt/boop-key.bin
Automatically generated binary carrier when no separate image is available.
MANPAGE
}

install_self_and_man() {
    CURRENT_STEP="installing $PROGRAM"
    local source
    source="$(script_path)"

    as_root install -d -m 0755 "$(dirname "$SYSTEM_BIN")"
    as_root install -m 0755 -- "$source" "$SYSTEM_BIN"
    info "Installed command: $SYSTEM_BIN"

    MAN_TEMP="$(mktemp)"
    write_man_page "$MAN_TEMP"
    as_root install -d -m 0755 "$(dirname "$SYSTEM_MAN")"
    as_root install -m 0644 -- "$MAN_TEMP" "$SYSTEM_MAN"
    rm -f -- "$MAN_TEMP"
    MAN_TEMP=""

    if command -v mandb >/dev/null 2>&1; then
        as_root mandb -q >/dev/null 2>&1 || true
    fi
    info "Installed manual: $SYSTEM_MAN"
}

detect_package_manager() {
    local distro="unknown Linux"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        distro="${PRETTY_NAME:-${NAME:-unknown Linux}}"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    else
        die "Unsupported distribution: apt, pacman or dnf was not found."
    fi
    info "Detected ${distro}; package manager: ${PACKAGE_MANAGER}."
    verbose "Package manager selected: $PACKAGE_MANAGER."
}

missing_runtime_commands() {
    local cmd
    local missing=()
    for cmd in gpg python3 file tar xz flock sha256sum findmnt find base64 head tr cmp install stat mktemp readlink dirname getconf; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    printf '%s\n' "${missing[@]:-}"
}

install_dependencies() {
    CURRENT_STEP="checking runtime dependencies"
    local missing
    missing="$(missing_runtime_commands)"
    if [[ -z "$missing" ]]; then
        info "All runtime dependencies are already installed."
        return 0
    fi

    local missing_display="${missing//$'\n'/ }"
    warn "Missing commands: ${missing_display% }"
    CURRENT_STEP="installing runtime dependencies"

    case "$PACKAGE_MANAGER" in
        apt)
            as_root env DEBIAN_FRONTEND=noninteractive apt-get update
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                gnupg python3 file tar xz-utils util-linux coreutils findutils
            ;;
        pacman)
            as_root pacman -S --needed --noconfirm \
                gnupg python file tar xz util-linux coreutils findutils
            ;;
        dnf)
            as_root dnf install -y \
                gnupg2 python3 file tar xz util-linux coreutils findutils
            ;;
        *)
            die "Internal error: unsupported package manager '$PACKAGE_MANAGER'."
            ;;
    esac

    missing="$(missing_runtime_commands)"
    [[ -z "$missing" ]] || die "Dependencies remain unavailable after installation: $missing"
    success "Runtime dependencies are installed."
}

runtime_user() {
    if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

prepare_workspace() {
    CURRENT_STEP="creating and securing $CRYPT_DIR"
    local run_user run_uid run_gid
    run_user="$(runtime_user)"
    run_uid="$(id -u "$run_user")"
    run_gid="$(id -g "$run_user")"

    as_root install -d -m 0700 "$CRYPT_DIR"
    as_root chown "$run_uid:$run_gid" "$CRYPT_DIR"
    as_root chmod 0700 "$CRYPT_DIR"

    [[ -d "$CRYPT_DIR" ]] || die "$CRYPT_DIR was not created."
    [[ "$(stat -c '%a' "$CRYPT_DIR")" == "700" ]] || die "$CRYPT_DIR permissions are not 0700."
    [[ "$(stat -c '%u' "$CRYPT_DIR")" == "$run_uid" ]] || die "$CRYPT_DIR is not owned by $run_user."
    info "Workspace ready: $CRYPT_DIR (owner $run_user, mode 0700)."
    verbose "Resolved workspace path: $(readlink -f "$CRYPT_DIR")"
}

# Carrier layout:
#   original carrier bytes | UTF-8 JSON | 8-byte big-endian length | magic
# The same footer is retained for legacy compatibility; format_version 4 is the
# reusable password-aware vault format.
carrier_record_tool() {
    python3 - "$@" <<'PY'
import json
import os
import shutil
import struct
import sys
from pathlib import Path

MAGIC = b"BOOPCRYPT-KEY-V1"
MAX_PAYLOAD = 8 * 1024 * 1024


def locate_record(path: Path):
    size = path.stat().st_size
    footer_size = 8 + len(MAGIC)
    if size < footer_size:
        return None
    with path.open("rb") as handle:
        handle.seek(-footer_size, os.SEEK_END)
        footer = handle.read(footer_size)
        if footer[8:] != MAGIC:
            return None
        length = struct.unpack(">Q", footer[:8])[0]
        if length <= 0 or length > MAX_PAYLOAD or length > size - footer_size:
            raise ValueError("invalid embedded record length")
        payload_start = size - footer_size - length
        handle.seek(payload_start)
        raw = handle.read(length)
    record = json.loads(raw.decode("utf-8"))
    if not isinstance(record, dict) or record.get("format_version") not in (1, 2, 3, 4):
        raise ValueError("unsupported embedded record format")
    return payload_start, record


def copy_prefix(source: Path, destination: Path, length: int):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src, destination.open("wb") as dst:
        remaining = length
        while remaining:
            chunk = src.read(min(1024 * 1024, remaining))
            if not chunk:
                raise OSError("unexpected end of carrier")
            dst.write(chunk)
            remaining -= len(chunk)
        dst.flush()
        os.fsync(dst.fileno())
    shutil.copystat(source, destination, follow_symlinks=True)


def main():
    if len(sys.argv) < 3:
        raise ValueError("missing arguments")
    action = sys.argv[1]
    carrier = Path(sys.argv[2])

    if action == "probe":
        try:
            found = locate_record(carrier)
        except Exception as exc:
            print(f"carrier helper: {exc}", file=sys.stderr)
            return 2
        return 0 if found is not None else 1

    if action == "extract":
        output = Path(sys.argv[3])
        found = locate_record(carrier)
        if found is None:
            raise ValueError("carrier does not contain a Boop Crypt record")
        _, record = found
        with output.open("w", encoding="utf-8") as handle:
            json.dump(record, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(output, 0o600)
        return 0

    if action == "strip":
        output = Path(sys.argv[3])
        found = locate_record(carrier)
        if found is None:
            shutil.copy2(carrier, output)
        else:
            payload_start, _ = found
            copy_prefix(carrier, output, payload_start)
        os.chmod(output, 0o600)
        return 0

    if action == "append":
        record_file = Path(sys.argv[3])
        output = Path(sys.argv[4])
        if locate_record(carrier) is not None:
            raise ValueError("base carrier already contains a record")
        record = json.loads(record_file.read_text(encoding="utf-8"))
        if record.get("format_version") != 4:
            raise ValueError("only format-version 4 records may be written")
        raw = json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if len(raw) > MAX_PAYLOAD:
            raise ValueError("carrier record is too large")
        with carrier.open("rb") as src, output.open("wb") as dst:
            shutil.copyfileobj(src, dst, 1024 * 1024)
            dst.write(raw)
            dst.write(struct.pack(">Q", len(raw)))
            dst.write(MAGIC)
            dst.flush()
            os.fsync(dst.fileno())
        shutil.copystat(carrier, output, follow_symlinks=True)
        os.chmod(output, 0o600)
        return 0

    raise ValueError(f"unknown action: {action}")


try:
    raise SystemExit(main())
except Exception as exc:
    print(f"carrier helper: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

json_helper() {
    python3 - "$@" <<'PY'
import datetime
import json
import os
import sys
import uuid
from pathlib import Path


def load(path):
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save(path, data):
    p = Path(path)
    with p.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(p, 0o600)


def read_fd3():
    with os.fdopen(3, "r", encoding="utf-8", closefd=False) as stream:
        return stream.read().rstrip("\n")


def legacy_package(record):
    version = record.get("format_version")
    common = {
        "original_name": record["original_name"],
        "created_utc": record.get("created_utc"),
    }
    if version == 1:
        return {
            **common,
            "pipeline": "alpha1",
            "encrypted_name": record["encrypted_name"],
            "encrypted_sha256": record["encrypted_sha256"],
        }
    if version == 2:
        return {
            **common,
            "pipeline": "beta1",
            "encrypted_name": record["compressed_name"],
            "encrypted_sha256": record["compressed_sha256"],
            "ciphertext_sha256": record["ciphertext_sha256"],
        }
    if version == 3:
        return {
            **common,
            "pipeline": "beta2",
            "encrypted_name": record["encrypted_name"],
            "encrypted_sha256": record["encrypted_sha256"],
            "compressed_archive_sha256": record["compressed_archive_sha256"],
            "archive_sha256": record["archive_sha256"],
            "compression": record.get("compression", "xz"),
        }
    raise ValueError("not a supported legacy record")


def main():
    action = sys.argv[1]

    if action == "normalize":
        record = load(sys.argv[2])
        meta_out, packages_out, carrier_type = sys.argv[3], sys.argv[4], sys.argv[5]
        version = record.get("format_version")
        if version == 4:
            kp = record.get("key_protection")
            carrier = record.get("carrier")
            packages = record.get("packages")
            if not isinstance(kp, dict) or kp.get("mode") not in ("plain", "gpg-wrapped"):
                raise ValueError("invalid key protection record")
            if not isinstance(carrier, dict) or not carrier.get("base_sha256"):
                raise ValueError("invalid carrier metadata")
            if not isinstance(packages, list):
                raise ValueError("invalid package list")
            if kp["mode"] == "plain":
                key_value = kp.get("key")
            else:
                key_value = kp.get("wrapped_key_b64")
            if not isinstance(key_value, str) or not key_value:
                raise ValueError("carrier key material is missing")
            meta = {
                "vault_id": record.get("vault_id") or str(uuid.uuid4()),
                "base_sha256": carrier["base_sha256"],
                "carrier_type": carrier.get("type") or carrier_type,
                "key_mode": kp["mode"],
                "key_value": key_value,
                "created_utc": record.get("created_utc") or datetime.datetime.now(datetime.timezone.utc).isoformat(),
            }
        elif version in (1, 2, 3):
            key = record.get("key")
            base_sha = record.get("carrier_sha256")
            if not isinstance(key, str) or not key or not isinstance(base_sha, str) or not base_sha:
                raise ValueError("legacy carrier key metadata is incomplete")
            meta = {
                "vault_id": str(uuid.uuid4()),
                "base_sha256": base_sha,
                "carrier_type": carrier_type,
                "key_mode": "plain",
                "key_value": key,
                "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            }
            packages = [legacy_package(record)]
        else:
            raise ValueError("unsupported carrier record version")
        save(meta_out, meta)
        save(packages_out, packages)
        return

    if action == "new-meta":
        output, base_sha, carrier_type = sys.argv[2], sys.argv[3], sys.argv[4]
        key = read_fd3()
        if not key:
            raise ValueError("empty random key")
        meta = {
            "vault_id": str(uuid.uuid4()),
            "base_sha256": base_sha,
            "carrier_type": carrier_type,
            "key_mode": "plain",
            "key_value": key,
            "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        save(output, meta)
        return

    if action == "set-wrapped":
        meta = load(sys.argv[2])
        output = sys.argv[3]
        wrapped = read_fd3()
        if not wrapped:
            raise ValueError("empty wrapped key")
        meta["key_mode"] = "gpg-wrapped"
        meta["key_value"] = wrapped
        save(output, meta)
        return

    if action == "new-package":
        output = sys.argv[2]
        package = {
            "pipeline": "beta2",
            "original_name": sys.argv[3],
            "encrypted_name": sys.argv[4],
            "encrypted_sha256": sys.argv[5],
            "compressed_archive_sha256": sys.argv[6],
            "archive_sha256": sys.argv[7],
            "compression": "xz",
            "compression_preset": "9e",
            "compression_threads": "auto",
            "created_utc": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
        }
        save(output, package)
        return

    if action == "add-package":
        packages = load(sys.argv[2])
        package = load(sys.argv[3])
        output = sys.argv[4]
        if any(item.get("encrypted_name") == package.get("encrypted_name") for item in packages):
            raise ValueError("carrier already tracks that encrypted package name")
        packages.append(package)
        save(output, packages)
        return

    if action == "remove-package":
        packages = load(sys.argv[2])
        name, output = sys.argv[3], sys.argv[4]
        filtered = [item for item in packages if item.get("encrypted_name") != name]
        if len(filtered) == len(packages):
            raise ValueError("selected package is not tracked by the carrier")
        save(output, filtered)
        return

    if action == "get-package":
        packages = load(sys.argv[2])
        name, output = sys.argv[3], sys.argv[4]
        matches = [item for item in packages if item.get("encrypted_name") == name]
        if len(matches) != 1:
            raise ValueError("selected package is not uniquely tracked")
        save(output, matches[0])
        return

    if action == "names":
        packages = load(sys.argv[2])
        for item in packages:
            name = item.get("encrypted_name")
            if not isinstance(name, str) or not name or "\x00" in name:
                raise ValueError("invalid tracked package name")
            sys.stdout.buffer.write(name.encode("utf-8") + b"\0")
        return

    if action == "build":
        meta, packages, output = load(sys.argv[2]), load(sys.argv[3]), sys.argv[4]
        mode = meta.get("key_mode")
        value = meta.get("key_value")
        if mode == "plain":
            kp = {"mode": "plain", "key": value, "password_protected": False}
        elif mode == "gpg-wrapped":
            kp = {
                "mode": "gpg-wrapped",
                "wrapped_key_b64": value,
                "password_protected": True,
                "wrapper": "gpg-symmetric-aes256",
            }
        else:
            raise ValueError("invalid key mode")
        record = {
            "format_version": 4,
            "program": "boop-crypt",
            "program_version": "1.0.0",
            "vault_id": meta["vault_id"],
            "created_utc": meta["created_utc"],
            "updated_utc": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
            "key_protection": kp,
            "carrier": {
                "base_sha256": meta["base_sha256"],
                "type": meta["carrier_type"],
            },
            "packages": packages,
        }
        save(output, record)
        return

    if action == "get":
        data = load(sys.argv[2])
        value = data
        for component in sys.argv[3].split("."):
            if not isinstance(value, dict) or component not in value:
                raise SystemExit(1)
            value = value[component]
        if isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, (dict, list)):
            print(json.dumps(value, separators=(",", ":")))
        else:
            print(value)
        return

    if action == "count":
        data = load(sys.argv[2])
        if not isinstance(data, list):
            raise ValueError("not a list")
        print(len(data))
        return

    raise ValueError(f"unknown JSON action: {action}")


try:
    main()
except Exception as exc:
    print(f"record helper: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

json_get() {
    json_helper get "$1" "$2"
}

is_supported_image() {
    local path="$1"
    local mime
    [[ -f "$path" && ! -L "$path" ]] || return 1
    mime="$(file --brief --mime-type -- "$path" 2>/dev/null || true)"
    case "$mime" in
        image/jpeg|image/png|image/gif|image/bmp|image/x-ms-bmp|image/webp|image/tiff)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_preferred_carrier_name() {
    local name="${1##*/}"
    shopt -s nocasematch
    if [[ "$name" =~ ^boop-key\.(jpe?g|png|gif|bmp|webp|tiff?)$ ]]; then
        shopt -u nocasematch
        return 0
    fi
    shopt -u nocasematch
    return 1
}

generate_bin_carrier() {
    local output="$1"
    python3 - "$output" <<'PY'
import os
import secrets
import string
import sys
from pathlib import Path

path = Path(sys.argv[1])
alphabet = string.ascii_letters + string.digits + string.punctuation + " \n\t"
size = 128 * 1024
text = "".join(secrets.choice(alphabet) for _ in range(size))
with path.open("w", encoding="utf-8", newline="") as handle:
    handle.write(text)
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(path, 0o600)
PY
}

sha256_file() {
    local hash remainder
    IFS=' ' read -r hash remainder < <(sha256sum -- "$1")
    [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s\n' "$hash"
}

cleanup_stale_workspace_files() {
    CURRENT_STEP="cleaning stale Boop Crypt temporary files"
    local stale_dir
    while IFS= read -r -d '' stale_dir; do
        if [[ -f "$stale_dir/.boop-crypt-temp" ]]; then
            rm -rf -- "$stale_dir"
        fi
    done < <(find "$CRYPT_DIR" -mindepth 1 -maxdepth 1 -type d -name '.boop-work.*' -print0)
}

scan_workspace() {
    CURRENT_STEP="scanning $CRYPT_DIR"
    local entry rc
    local all_entries=()
    local non_packages=()
    local record_carriers=()
    local preferred_images=()
    local images=()
    local bin_candidates=()
    local payload_entries=()

    mapfile -d '' all_entries < <(
        find "$CRYPT_DIR" -mindepth 1 -maxdepth 1 \
            ! -name '.boop-crypt.lock' ! -name '.boop-work.*' -print0
    )
    verbose "Workspace scan found ${#all_entries[@]} top-level item(s)."

    for entry in "${all_entries[@]}"; do
        if [[ -f "$entry" && ! -L "$entry" && ( "${entry##*/}" == *.boopcrypt || "${entry##*/}" == *.boopcrypt.xz ) ]]; then
            ENCRYPTED_ENTRIES+=("$entry")
            verbose "Classified encrypted package: ${entry##*/}"
            continue
        fi
        non_packages+=("$entry")
        if [[ -f "$entry" && ! -L "$entry" ]]; then
            if carrier_record_tool probe "$entry" >/dev/null 2>&1; then
                record_carriers+=("$entry")
                verbose "Found embedded Boop Crypt carrier record: ${entry##*/}"
            else
                rc=$?
                if (( rc == 2 )); then
                    die "${entry##*/} appears to contain a damaged Boop Crypt carrier record."
                fi
            fi
        fi
    done

    if (( ${#record_carriers[@]} > 1 )); then
        die "More than one file contains a Boop Crypt carrier record. Keep only the intended carrier in $CRYPT_DIR."
    fi

    if (( ${#record_carriers[@]} == 1 )); then
        CARRIER_FILE="${record_carriers[0]}"
        CARRIER_HAS_RECORD=1
    else
        for entry in "${non_packages[@]}"; do
            if is_supported_image "$entry"; then
                images+=("$entry")
                verbose "Found supported image candidate: ${entry##*/}"
                is_preferred_carrier_name "$entry" && preferred_images+=("$entry")
            fi
            [[ "${entry##*/}" == "$AUTO_CARRIER_NAME" ]] && bin_candidates+=("$entry")
        done

        if (( ${#preferred_images[@]} == 1 )); then
            CARRIER_FILE="${preferred_images[0]}"
        elif (( ${#preferred_images[@]} > 1 )); then
            die "More than one preferred boop-key image was found. Keep only one."
        elif (( ${#bin_candidates[@]} == 1 )); then
            CARRIER_FILE="${bin_candidates[0]}"
        elif (( ${#bin_candidates[@]} > 1 )); then
            die "More than one $AUTO_CARRIER_NAME candidate was found."
        elif (( ${#images[@]} == 1 && ${#non_packages[@]} >= 2 )); then
            CARRIER_FILE="${images[0]}"
        elif (( ${#images[@]} > 1 && ${#non_packages[@]} >= 2 )); then
            die "Multiple images were found. Rename the intended carrier to boop-key.<extension>."
        fi
    fi

    for entry in "${non_packages[@]}"; do
        [[ -n "$CARRIER_FILE" && "$entry" == "$CARRIER_FILE" ]] && continue
        payload_entries+=("$entry")
    done

    if (( ${#payload_entries[@]} == 1 )); then
        MODE="encrypt"
        PAYLOAD_PATH="${payload_entries[0]}"
        [[ "${PAYLOAD_PATH##*/}" != *.boopcrypt && "${PAYLOAD_PATH##*/}" != *.boopcrypt.xz ]] || \
            die "The payload name may not end in .boopcrypt or .boopcrypt.xz."
        [[ "${PAYLOAD_PATH##*/}" != *$'\n'* ]] || die "Payload names containing a newline are not supported."

        if [[ -z "$CARRIER_FILE" ]]; then
            CARRIER_FILE="$CRYPT_DIR/$AUTO_CARRIER_NAME"
            [[ ! -e "$CARRIER_FILE" ]] || die "$AUTO_CARRIER_NAME exists but could not be used as a carrier."
            AUTO_CREATE_CARRIER=1
            verbose "No image or existing carrier was selected; automatic binary-carrier creation is enabled."
        fi
    elif (( ${#payload_entries[@]} == 0 && ${#ENCRYPTED_ENTRIES[@]} >= 1 )); then
        MODE="decrypt"
        (( CARRIER_HAS_RECORD == 1 )) || die "Encrypted package(s) were found, but no carrier with an embedded key record was found."
    elif (( ${#payload_entries[@]} == 0 )); then
        die "$CRYPT_DIR contains no payload and no encrypted package."
    else
        die "Multiple unencrypted payload items were found. Keep exactly one payload file or folder."
    fi

    if [[ -n "$CARRIER_FILE" && -e "$CARRIER_FILE" ]] && is_supported_image "$CARRIER_FILE"; then
        CARRIER_IS_IMAGE=1
    fi

    if [[ "$MODE" == "encrypt" ]]; then
        info "Payload: ${PAYLOAD_PATH##*/}"
        if (( AUTO_CREATE_CARRIER )); then
            info "Carrier: $AUTO_CARRIER_NAME will be generated automatically."
        else
            info "Carrier: ${CARRIER_FILE##*/}"
        fi
    else
        info "Carrier: ${CARRIER_FILE##*/}"
    fi
    info "Detected operation: $MODE"
    verbose "Encrypted packages: ${#ENCRYPTED_ENTRIES[@]}; recorded carrier: $CARRIER_HAS_RECORD; automatic carrier: $AUTO_CREATE_CARRIER"
}

check_payload_mounts() {
    local path="$1"
    local resolved mount_target
    [[ -d "$path" && ! -L "$path" ]] || return 0
    resolved="$(readlink -f -- "$path")"
    while IFS= read -r mount_target; do
        [[ -n "$mount_target" ]] || continue
        if [[ "$mount_target" == "$resolved" || "$mount_target" == "$resolved/"* ]]; then
            die "Payload directory contains a mount point ($mount_target). Unmount it before encryption to prevent unsafe deletion."
        fi
    done < <(findmnt -rn -o TARGET)
}

validate_archive() {
    local archive="$1"
    local expected_name="$2"
    python3 - "$archive" "$expected_name" <<'PY'
import posixpath
import sys
import tarfile
from pathlib import PurePosixPath

archive, expected = sys.argv[1], sys.argv[2]


def safe_member(member):
    name = member.name
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsafe archive path: {name!r}")
    if member.ischr() or member.isblk() or member.isfifo():
        raise ValueError(f"special device/FIFO is not permitted: {name!r}")
    if member.issym() or member.islnk():
        link = PurePosixPath(member.linkname)
        if link.is_absolute():
            raise ValueError(f"absolute archive link is not permitted: {name!r}")
        combined = PurePosixPath(posixpath.normpath(str(path.parent / link)))
        if ".." in combined.parts or not combined.parts or combined.parts[0] != expected:
            raise ValueError(f"archive link escapes payload: {name!r}")
    if path.parts[0] != expected:
        raise ValueError(f"unexpected top-level archive entry: {name!r}")

with tarfile.open(archive, "r:") as handle:
    members = handle.getmembers()
    if not members:
        raise ValueError("archive is empty")
    for member in members:
        safe_member(member)
PY
}

read_hidden() {
    local prompt="$1"
    local __result_var="$2"
    local value
    printf '%s' "$prompt" >&2
    if [[ -t 0 ]]; then
        IFS= read -r -s value || die "Password input was cancelled."
        printf '\n' >&2
    else
        IFS= read -r value || die "Password input was cancelled."
    fi
    printf -v "$__result_var" '%s' "$value"
}

gpg_encrypt() {
    local input="$1" output="$2" key="$3"
    GNUPGHOME="$TEMP_DIR/gnupg" \
        gpg --batch --yes --quiet --no-secmem-warning --no-autostart --no-symkey-cache --pinentry-mode loopback \
        --passphrase-fd 3 --symmetric --cipher-algo AES256 --compress-algo none \
        --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count "$PACKAGE_S2K_COUNT" \
        --output "$output" -- "$input" 3<<<"$key"
}

gpg_decrypt() {
    local input="$1" output="$2" key="$3"
    GNUPGHOME="$TEMP_DIR/gnupg" \
        gpg --batch --yes --quiet --no-secmem-warning --no-autostart --no-symkey-cache --pinentry-mode loopback \
        --passphrase-fd 3 --decrypt --output "$output" -- "$input" 3<<<"$key"
}

wrap_key() {
    local key="$1" password="$2"
    install -d -m 0700 "$TEMP_DIR/gnupg"
    local key_file="$TEMP_DIR/key-to-wrap.txt"
    local wrapped_file="$TEMP_DIR/wrapped-key.gpg"
    printf '%s' "$key" > "$key_file"
    chmod 0600 "$key_file"
    GNUPGHOME="$TEMP_DIR/gnupg" \
        gpg --batch --yes --quiet --no-secmem-warning --no-autostart --no-symkey-cache --pinentry-mode loopback \
        --passphrase-fd 3 --symmetric --cipher-algo AES256 \
        --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count "$PASSWORD_WRAP_S2K_COUNT" --compress-algo none \
        --output "$wrapped_file" -- "$key_file" 3<<<"$password"
    python3 - "$wrapped_file" <<'PY'
import base64
import sys
from pathlib import Path
print(base64.b64encode(Path(sys.argv[1]).read_bytes()).decode("ascii"))
PY
    rm -f -- "$key_file" "$wrapped_file"
}

unwrap_key() {
    local wrapped="$1" password="$2"
    install -d -m 0700 "$TEMP_DIR/gnupg"
    local wrapped_file="$TEMP_DIR/wrapped-key-input.gpg"
    local key_file="$TEMP_DIR/unwrapped-key.txt"
    python3 - "$wrapped_file" 3<<<"$wrapped" <<'PY'
import base64
import os
import sys
from pathlib import Path
with os.fdopen(3, "r", encoding="utf-8", closefd=False) as stream:
    data = stream.read().strip()
Path(sys.argv[1]).write_bytes(base64.b64decode(data, validate=True))
PY
    if ! GNUPGHOME="$TEMP_DIR/gnupg" \
        gpg --batch --yes --quiet --no-secmem-warning --no-autostart --no-symkey-cache --pinentry-mode loopback \
        --passphrase-fd 3 --decrypt --output "$key_file" -- "$wrapped_file" 3<<<"$password" 2>/dev/null; then
        rm -f -- "$wrapped_file" "$key_file"
        return 1
    fi
    local key
    key="$(cat -- "$key_file")"
    rm -f -- "$wrapped_file" "$key_file"
    [[ ${#key} -ge 60 ]] || return 1
    printf '%s\n' "$key"
}

xz_compress() {
    xz --threads=0 -9e --check=sha256 --stdout -- "$1" > "$2"
}

xz_decompress() {
    xz --decompress --stdout -- "$1" > "$2"
}

prepare_carrier_metadata() {
    local base_carrier="$1"
    local carrier_type base_sha key

    if (( AUTO_CREATE_CARRIER )); then
        verbose "No carrier image exists. Generating a random printable-junk binary carrier."
        generate_bin_carrier "$base_carrier"
        verbose "Generated temporary binary carrier base ($(stat -c '%s' "$base_carrier") bytes, mode $(stat -c '%a' "$base_carrier"))."
        carrier_type="bin"
        CARRIER_IS_IMAGE=0
    else
        if (( CARRIER_HAS_RECORD )); then
            carrier_record_tool extract "$CARRIER_FILE" "$RECORD_JSON"
            carrier_record_tool strip "$CARRIER_FILE" "$base_carrier"
        else
            cp -p -- "$CARRIER_FILE" "$base_carrier"
            chmod 0600 "$base_carrier"
        fi
        if is_supported_image "$base_carrier"; then
            carrier_type="image"
            CARRIER_IS_IMAGE=1
        else
            carrier_type="bin"
            CARRIER_IS_IMAGE=0
        fi
    fi

    base_sha="$(sha256_file "$base_carrier")"

    if (( CARRIER_HAS_RECORD )); then
        json_helper normalize "$RECORD_JSON" "$META_JSON" "$PACKAGES_JSON" "$carrier_type"
        local expected_sha
        expected_sha="$(json_get "$META_JSON" base_sha256)" || die "Carrier metadata lacks its base SHA-256 digest."
        [[ "$base_sha" == "$expected_sha" ]] || die "Carrier base SHA-256 verification failed. The carrier was altered."
    else
        key="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
        [[ ${#key} -ge 60 ]] || die "Random key generation failed."
        json_helper new-meta "$META_JSON" "$base_sha" "$carrier_type" 3<<<"$key"
        printf '[]\n' > "$PACKAGES_JSON"
        chmod 0600 "$PACKAGES_JSON"
        key=""
    fi
}

obtain_key_for_encryption() {
    local key_mode key_value password confirm wrapped
    key_mode="$(json_get "$META_JSON" key_mode)" || die "Carrier key mode is missing."
    key_value="$(json_get "$META_JSON" key_value)" || die "Carrier key material is missing."

    if [[ "$key_mode" == "gpg-wrapped" ]]; then
        info "The existing carrier is password-protected."
        verbose "Unlocking the reusable carrier key; password and key values are not logged."
        local attempt
        for attempt in 1 2 3; do
            read_hidden "Carrier password: " password
            if KEY="$(unwrap_key "$key_value" "$password")"; then
                password=""
                return 0
            fi
            password=""
            warn "Incorrect carrier password (${attempt}/3)."
        done
        die "Unable to unlock the carrier after three attempts."
    fi

    [[ "$key_mode" == "plain" ]] || die "Unsupported carrier key mode: $key_mode"
    KEY="$key_value"
    verbose "Carrier key is unprotected; requesting the optional separate carrier password."
    read_hidden "Create optional carrier password (leave blank for none): " password
    if [[ -z "$password" ]]; then
        info "No carrier password will be used."
        return 0
    fi
    read_hidden "Confirm carrier password: " confirm
    [[ "$password" == "$confirm" ]] || die "Password confirmation did not match."
    wrapped="$(wrap_key "$KEY" "$password")"
    [[ -n "$wrapped" ]] || die "Failed to password-protect the carrier key."
    json_helper set-wrapped "$META_JSON" "$META_JSON.new" 3<<<"$wrapped"
    mv -f -- "$META_JSON.new" "$META_JSON"
    password=""
    confirm=""
    wrapped=""
    success "Carrier password protection enabled."
}

obtain_key_for_decryption() {
    local key_mode key_value password attempt
    key_mode="$(json_get "$META_JSON" key_mode)" || die "Carrier key mode is missing."
    key_value="$(json_get "$META_JSON" key_value)" || die "Carrier key material is missing."

    if [[ "$key_mode" == "plain" ]]; then
        KEY="$key_value"
        return 0
    fi
    [[ "$key_mode" == "gpg-wrapped" ]] || die "Unsupported carrier key mode: $key_mode"

    for attempt in 1 2 3; do
        read_hidden "Carrier password: " password
        if KEY="$(unwrap_key "$key_value" "$password")"; then
            password=""
            return 0
        fi
        password=""
        warn "Incorrect carrier password (${attempt}/3)."
    done
    die "Unable to unlock the carrier after three attempts."
}

select_decryption_package() {
    local tracked_names=()
    local present_tracked=()
    local entry name tracked candidate answer

    mapfile -d '' tracked_names < <(json_helper names "$PACKAGES_JSON")
    (( ${#tracked_names[@]} > 0 )) || die "The carrier does not currently track any encrypted packages."

    for entry in "${ENCRYPTED_ENTRIES[@]}"; do
        name="${entry##*/}"
        tracked=0
        for candidate in "${tracked_names[@]}"; do
            if [[ "$name" == "$candidate" ]]; then
                tracked=1
                present_tracked+=("$entry")
                break
            fi
        done
        (( tracked == 1 )) || die "Encrypted package '$name' is not tracked by ${CARRIER_FILE##*/}."
    done

    (( ${#present_tracked[@]} > 0 )) || die "None of the carrier's tracked encrypted packages are present in $CRYPT_DIR."

    if (( ${#present_tracked[@]} == 1 )); then
        ENCRYPTED_FILE="${present_tracked[0]}"
        return 0
    fi

    printf 'Tracked encrypted packages:\n' >&2
    local i
    for (( i=0; i<${#present_tracked[@]}; i++ )); do
        printf '  %d) %s\n' "$((i+1))" "${present_tracked[i]##*/}" >&2
    done
    printf 'Select package [1-%d]: ' "${#present_tracked[@]}" >&2
    IFS= read -r answer || die "Package selection was cancelled."
    [[ "$answer" =~ ^[0-9]+$ ]] || die "Invalid package selection."
    (( answer >= 1 && answer <= ${#present_tracked[@]} )) || die "Package selection is out of range."
    ENCRYPTED_FILE="${present_tracked[answer-1]}"
}

encrypt_payload() {
    CURRENT_STEP="preparing encryption"
    local payload_name encrypted_name final_encrypted name_max
    local base_carrier archive compressed_archive verify_archive encrypted_tmp verify_compressed verify_archive2
    local package_json packages_updated record_updated carrier_updated
    local archive_sha compressed_sha encrypted_sha carrier_count

    payload_name="${PAYLOAD_PATH##*/}"
    encrypted_name="${payload_name}.boopcrypt"
    name_max="$(getconf NAME_MAX "$CRYPT_DIR" 2>/dev/null || printf '255')"
    [[ "$name_max" =~ ^[0-9]+$ ]] || name_max=255
    (( ${#encrypted_name} <= name_max )) || die "The payload name is too long after adding .boopcrypt."
    final_encrypted="$CRYPT_DIR/$encrypted_name"
    [[ ! -e "$final_encrypted" ]] || die "$encrypted_name already exists."

    check_payload_mounts "$PAYLOAD_PATH"

    base_carrier="$TEMP_DIR/carrier-base"
    RECORD_JSON="$TEMP_DIR/existing-record.json"
    META_JSON="$TEMP_DIR/vault-meta.json"
    PACKAGES_JSON="$TEMP_DIR/packages.json"
    prepare_carrier_metadata "$base_carrier"
    obtain_key_for_encryption

    archive="$TEMP_DIR/payload.tar"
    compressed_archive="$TEMP_DIR/payload.tar.xz"
    verify_archive="$TEMP_DIR/verify-before-encryption.tar"
    encrypted_tmp="$TEMP_DIR/$encrypted_name.tmp"
    verify_compressed="$TEMP_DIR/verify-after-encryption.tar.xz"
    verify_archive2="$TEMP_DIR/verify-after-encryption.tar"
    package_json="$TEMP_DIR/new-package.json"
    packages_updated="$TEMP_DIR/packages-updated.json"
    record_updated="$TEMP_DIR/vault-record.json"
    carrier_updated="$TEMP_DIR/carrier-updated"

    CURRENT_STEP="archiving $payload_name"
    verbose "Creating TAR archive from '$payload_name'."
    tar --sparse -C "$CRYPT_DIR" -cf "$archive" -- "$payload_name"
    validate_archive "$archive" "$payload_name"

    CURRENT_STEP="compressing $payload_name with multithreaded XZ -9e"
    verbose "Compressing with XZ preset -9e, SHA-256 stream checking and automatic threads."
    xz_compress "$archive" "$compressed_archive"
    [[ -s "$compressed_archive" ]] || die "XZ did not produce a compressed archive."
    verbose "Archive size: $(stat -c '%s' "$archive") bytes; compressed size: $(stat -c '%s' "$compressed_archive") bytes."

    CURRENT_STEP="verifying the compressed archive"
    xz --test -- "$compressed_archive"
    xz_decompress "$compressed_archive" "$verify_archive"
    cmp -s -- "$archive" "$verify_archive" || die "Compression verification failed."

    install -d -m 0700 "$TEMP_DIR/gnupg"
    CURRENT_STEP="encrypting the compressed archive"
    verbose "Encrypting with GnuPG AES-256; internal compression is disabled and the random-key S2K count is $PACKAGE_S2K_COUNT."
    gpg_encrypt "$compressed_archive" "$encrypted_tmp" "$KEY"
    [[ -s "$encrypted_tmp" ]] || die "GnuPG did not produce an encrypted package."

    CURRENT_STEP="performing end-to-end encryption verification"
    gpg_decrypt "$encrypted_tmp" "$verify_compressed" "$KEY"
    cmp -s -- "$compressed_archive" "$verify_compressed" || die "Encryption verification failed."
    xz --test -- "$verify_compressed"
    xz_decompress "$verify_compressed" "$verify_archive2"
    cmp -s -- "$archive" "$verify_archive2" || die "End-to-end archive verification failed."

    archive_sha="$(sha256_file "$archive")"
    compressed_sha="$(sha256_file "$compressed_archive")"
    encrypted_sha="$(sha256_file "$encrypted_tmp")"
    verbose "Encrypted package size: $(stat -c '%s' "$encrypted_tmp") bytes."
    verbose "Verification digests: TAR=$archive_sha XZ=$compressed_sha package=$encrypted_sha"

    json_helper new-package "$package_json" "$payload_name" "$encrypted_name" \
        "$encrypted_sha" "$compressed_sha" "$archive_sha"
    json_helper add-package "$PACKAGES_JSON" "$package_json" "$packages_updated"
    json_helper build "$META_JSON" "$packages_updated" "$record_updated"
    carrier_record_tool append "$base_carrier" "$record_updated" "$carrier_updated"

    if (( CARRIER_IS_IMAGE )); then
        is_supported_image "$carrier_updated" || die "The carrier image is no longer recognised after embedding the record."
    fi
    chmod 0600 "$encrypted_tmp" "$carrier_updated"

    CURRENT_STEP="committing encrypted package and carrier"
    verbose "Committing package '$encrypted_name' and carrier '${CARRIER_FILE##*/}' after all verification checks."
    mv -- "$encrypted_tmp" "$final_encrypted"
    if ! mv -f -- "$carrier_updated" "$CARRIER_FILE"; then
        mv -- "$final_encrypted" "$encrypted_tmp" 2>/dev/null || true
        die "Could not update the carrier; the original payload was left untouched."
    fi
    carrier_updated=""

    CURRENT_STEP="removing the original payload after verification"
    if [[ -d "$PAYLOAD_PATH" && ! -L "$PAYLOAD_PATH" ]]; then
        rm -rf --one-file-system -- "$PAYLOAD_PATH"
    else
        rm -f -- "$PAYLOAD_PATH"
    fi
    [[ ! -e "$PAYLOAD_PATH" ]] || die "Encrypted data is safe, but the original payload could not be fully removed."

    carrier_count="$(json_helper count "$packages_updated")"
    KEY=""
    success "Compressed '$payload_name' and encrypted it as '$encrypted_name'."
    success "Carrier '${CARRIER_FILE##*/}' now tracks $carrier_count encrypted package(s)."
}

decrypt_selected_package() {
    local package_json="$1"
    local pipeline original_name expected_sha expected_compressed_sha expected_archive_sha expected_ciphertext_sha
    local actual_sha ciphertext compressed_archive archive

    verbose "Reading selected package metadata."
    pipeline="$(json_get "$package_json" pipeline)" || die "Package pipeline metadata is missing."
    original_name="$(json_get "$package_json" original_name)" || die "Original payload name is missing."
    expected_sha="$(json_get "$package_json" encrypted_sha256)" || die "Encrypted-package digest is missing."
    verbose "Package metadata loaded: pipeline=$pipeline, original='$original_name'."

    [[ "$original_name" != */* && "$original_name" != "." && "$original_name" != ".." ]] || die "Embedded original name is unsafe."
    [[ "$original_name" != *$'\n'* ]] || die "Embedded original name contains a newline."

    verbose "Calculating encrypted-package SHA-256 digest."
    actual_sha="$(sha256_file "$ENCRYPTED_FILE")"
    [[ "$actual_sha" == "$expected_sha" ]] || die "Encrypted-package SHA-256 verification failed."
    verbose "Encrypted-package SHA-256 digest verified."

    install -d -m 0700 "$TEMP_DIR/gnupg"
    case "$pipeline" in
        alpha1)
            archive="$TEMP_DIR/decrypted.tar"
            CURRENT_STEP="decrypting legacy Alpha 1 package"
            gpg_decrypt "$ENCRYPTED_FILE" "$archive" "$KEY"
            ;;
        beta1)
            ciphertext="$TEMP_DIR/legacy-ciphertext.boopcrypt"
            archive="$TEMP_DIR/decrypted.tar"
            expected_ciphertext_sha="$(json_get "$package_json" ciphertext_sha256)" || die "Legacy ciphertext digest is missing."
            CURRENT_STEP="testing legacy Beta 1 outer XZ stream"
            xz --test -- "$ENCRYPTED_FILE"
            xz_decompress "$ENCRYPTED_FILE" "$ciphertext"
            [[ "$(sha256_file "$ciphertext")" == "$expected_ciphertext_sha" ]] || die "Legacy ciphertext digest verification failed."
            CURRENT_STEP="decrypting legacy Beta 1 package"
            gpg_decrypt "$ciphertext" "$archive" "$KEY"
            ;;
        beta2)
            compressed_archive="$TEMP_DIR/decrypted.tar.xz"
            archive="$TEMP_DIR/decompressed.tar"
            expected_compressed_sha="$(json_get "$package_json" compressed_archive_sha256)" || die "Compressed-archive digest is missing."
            expected_archive_sha="$(json_get "$package_json" archive_sha256)" || die "Tar-archive digest is missing."
            CURRENT_STEP="decrypting ${ENCRYPTED_FILE##*/}"
            verbose "Decrypting the package to a temporary XZ archive."
            gpg_decrypt "$ENCRYPTED_FILE" "$compressed_archive" "$KEY"
            verbose "GnuPG decryption completed; verifying compressed-archive digest."
            [[ "$(sha256_file "$compressed_archive")" == "$expected_compressed_sha" ]] || die "Decrypted compressed-archive digest verification failed."
            CURRENT_STEP="testing and decompressing the XZ archive"
            verbose "Testing the XZ stream."
            xz --test -- "$compressed_archive"
            verbose "Decompressing the XZ stream to TAR."
            xz_decompress "$compressed_archive" "$archive"
            verbose "Verifying the decompressed TAR digest."
            [[ "$(sha256_file "$archive")" == "$expected_archive_sha" ]] || die "Decompressed tar-archive digest verification failed."
            ;;
        *)
            die "Unsupported package pipeline: $pipeline"
            ;;
    esac

    [[ -s "$archive" ]] || die "The decryption pipeline produced an empty tar archive."
    DECRYPT_ARCHIVE="$archive"
    DECRYPT_ORIGINAL_NAME="$original_name"
}

decrypt_payload() {
    CURRENT_STEP="preparing decryption"
    verbose "Preparing reusable carrier and package metadata for decryption."
    local base_carrier carrier_type base_sha expected_base_sha
    local package_json packages_updated record_updated carrier_updated
    local extract_dir restored_path encrypted_backup carrier_count

    RECORD_JSON="$TEMP_DIR/existing-record.json"
    META_JSON="$TEMP_DIR/vault-meta.json"
    PACKAGES_JSON="$TEMP_DIR/packages.json"
    base_carrier="$TEMP_DIR/carrier-base"
    verbose "Extracting the carrier record."
    carrier_record_tool extract "$CARRIER_FILE" "$RECORD_JSON"
    verbose "Separating the original carrier bytes from the appended record."
    carrier_record_tool strip "$CARRIER_FILE" "$base_carrier"
    if is_supported_image "$base_carrier"; then
        carrier_type="image"
        CARRIER_IS_IMAGE=1
    else
        carrier_type="bin"
        CARRIER_IS_IMAGE=0
    fi
    verbose "Normalising carrier metadata and tracked package records."
    json_helper normalize "$RECORD_JSON" "$META_JSON" "$PACKAGES_JSON" "$carrier_type"
    base_sha="$(sha256_file "$base_carrier")"
    expected_base_sha="$(json_get "$META_JSON" base_sha256)" || die "Carrier base digest is missing."
    [[ "$base_sha" == "$expected_base_sha" ]] || die "Carrier base SHA-256 verification failed."

    verbose "Selecting the encrypted package tracked by the carrier."
    select_decryption_package
    verbose "Selected package: ${ENCRYPTED_FILE##*/}"
    verbose "Unlocking the carrier encryption key."
    obtain_key_for_decryption
    verbose "Carrier encryption key unlocked."

    package_json="$TEMP_DIR/selected-package.json"
    json_helper get-package "$PACKAGES_JSON" "${ENCRYPTED_FILE##*/}" "$package_json"
    verbose "Verifying and decrypting the selected package."
    decrypt_selected_package "$package_json"
    verbose "Package decryption and decompression verification completed."

    restored_path="$CRYPT_DIR/$DECRYPT_ORIGINAL_NAME"
    [[ ! -e "$restored_path" && ! -L "$restored_path" ]] || die "Cannot restore '$DECRYPT_ORIGINAL_NAME' because it already exists."

    extract_dir="$TEMP_DIR/extracted"
    install -d -m 0700 "$extract_dir"
    CURRENT_STEP="validating the decrypted archive"
    verbose "Validating TAR paths and entry types before extraction."
    validate_archive "$DECRYPT_ARCHIVE" "$DECRYPT_ORIGINAL_NAME"
    CURRENT_STEP="extracting $DECRYPT_ORIGINAL_NAME"
    verbose "Extracting the verified archive into a private temporary directory."
    tar -xf "$DECRYPT_ARCHIVE" -C "$extract_dir" --no-same-owner
    [[ -e "$extract_dir/$DECRYPT_ORIGINAL_NAME" || -L "$extract_dir/$DECRYPT_ORIGINAL_NAME" ]] || die "The archive did not restore '$DECRYPT_ORIGINAL_NAME'."

    packages_updated="$TEMP_DIR/packages-updated.json"
    record_updated="$TEMP_DIR/vault-record.json"
    carrier_updated="$TEMP_DIR/carrier-updated"
    json_helper remove-package "$PACKAGES_JSON" "${ENCRYPTED_FILE##*/}" "$packages_updated"
    json_helper build "$META_JSON" "$packages_updated" "$record_updated"
    carrier_record_tool append "$base_carrier" "$record_updated" "$carrier_updated"
    if (( CARRIER_IS_IMAGE )); then
        is_supported_image "$carrier_updated" || die "The updated carrier image is no longer recognised."
    fi
    chmod 0600 "$carrier_updated"

    CURRENT_STEP="committing restored payload"
    verbose "Committing the restored payload and updated reusable carrier."
    encrypted_backup="$TEMP_DIR/encrypted-package.backup"
    mv -- "$extract_dir/$DECRYPT_ORIGINAL_NAME" "$restored_path"
    if ! mv -- "$ENCRYPTED_FILE" "$encrypted_backup"; then
        mv -- "$restored_path" "$extract_dir/$DECRYPT_ORIGINAL_NAME" 2>/dev/null || true
        die "Could not stage the encrypted package for removal."
    fi
    if ! mv -f -- "$carrier_updated" "$CARRIER_FILE"; then
        mv -- "$encrypted_backup" "$ENCRYPTED_FILE" 2>/dev/null || true
        mv -- "$restored_path" "$extract_dir/$DECRYPT_ORIGINAL_NAME" 2>/dev/null || true
        die "Could not update the carrier; encrypted state was retained."
    fi
    carrier_updated=""
    rm -f -- "$encrypted_backup"

    carrier_count="$(json_helper count "$packages_updated")"
    KEY=""
    success "Decrypted, decompressed and restored '$DECRYPT_ORIGINAL_NAME'."
    success "Carrier '${CARRIER_FILE##*/}' retained its key and now tracks $carrier_count encrypted package(s)."
}

run_operation() {
    CURRENT_STEP="acquiring the workspace lock"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another Boop Crypt process is already using $CRYPT_DIR."

    cleanup_stale_workspace_files
    TEMP_DIR="$(mktemp -d "${CRYPT_DIR}/.boop-work.XXXXXX")"
    chmod 0700 "$TEMP_DIR"
    : > "$TEMP_DIR/.boop-crypt-temp"
    scan_workspace

    case "$MODE" in
        encrypt) encrypt_payload ;;
        decrypt) decrypt_payload ;;
        *) die "Internal error: unknown mode '$MODE'." ;;
    esac
}

main() {
    local install_only=0
    local show_help_only=0
    local show_version_only=0
    local arg

    for arg in "$@"; do
        case "$arg" in
            -v|-verbose|--verbose)
                VERBOSE=1
                ;;
            --install)
                install_only=1
                ;;
            -h|--help)
                show_help_only=1
                ;;
            --version)
                show_version_only=1
                ;;
            --)
                ;;
            *)
                warn "Unknown option: $arg"
                show_help >&2
                exit 2
                ;;
        esac
    done

    if (( show_help_only )); then
        show_help
        exit 0
    fi
    if (( show_version_only )); then
        show_version
        exit 0
    fi

    verbose "Starting $PROGRAM $PROGRAM_VERSION."
    verbose "Invoked script: $(script_path)"
    verbose "Configured installed command: $SYSTEM_BIN"
    verbose "Configured workspace: $CRYPT_DIR"

    if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" && "${BOOP_CRYPT_DROPPED_PRIVS:-0}" != "1" ]]; then
        CURRENT_STEP="dropping unnecessary root privileges"
        verbose "Re-executing as invoking user '$SUDO_USER'."
        exec sudo -u "$SUDO_USER" -H env \
            BOOP_CRYPT_DROPPED_PRIVS=1 \
            BOOP_CRYPT_SYSTEM_BIN="$SYSTEM_BIN" \
            BOOP_CRYPT_SYSTEM_MAN="$SYSTEM_MAN" \
            BOOP_CRYPT_DIR="$CRYPT_DIR" \
            "$(script_path)" "$@"
    fi

    if [[ "$(script_path)" != "$SYSTEM_BIN" && "${BOOP_CRYPT_REEXEC:-0}" != "1" ]]; then
        verbose "Downloaded script is not the installed command; installing/overwriting it now."
        install_self_and_man
        if (( install_only )); then
            detect_package_manager
            install_dependencies
            prepare_workspace
            success "$PROGRAM $PROGRAM_VERSION installation is complete."
            exit 0
        fi
        verbose "Re-executing the newly installed 1.0.0 command."
        exec env \
            BOOP_CRYPT_REEXEC=1 \
            BOOP_CRYPT_SYSTEM_BIN="$SYSTEM_BIN" \
            BOOP_CRYPT_SYSTEM_MAN="$SYSTEM_MAN" \
            BOOP_CRYPT_DIR="$CRYPT_DIR" \
            "$SYSTEM_BIN" "$@"
    fi

    detect_package_manager
    install_dependencies
    prepare_workspace

    if (( install_only )); then
        success "$PROGRAM $PROGRAM_VERSION installation is complete."
        exit 0
    fi

    run_operation
}
main "$@"
