#!/usr/bin/env bash
#
# Back up /etc and /root from OpenWrt devices over ssh, then remove duplicate
# backups (unchanged configs) with jdupes.
#
# Settings live in a config file outside the repo, see openwrt_backup.conf.example.

set -uo pipefail

# Backups hold Wi-Fi keys, /etc/shadow and ssh keys: keep them private
umask 077

CONFIG_FILE="${OPENWRT_BACKUP_CONFIG:-$HOME/.openwrt_backup}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [-v] [-h] [hostname ...]
  -v, --verbose   Print progress
  -h, --help      Show this help and exit

Backs up the hosts given, or BACKUP_HOSTS from '$CONFIG_FILE' when none are.
EOF
}

# Parse command line arguments
VERBOSE=false
HOSTNAMES=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 1 ;;
        *) HOSTNAMES+=("$1") ;;
    esac
    shift
done

log() { if [[ "$VERBOSE" == true ]]; then echo "$*"; fi }

# Load and validate settings
[[ -r "$CONFIG_FILE" ]] || die "Config file '$CONFIG_FILE' not found, see openwrt_backup.conf.example"
# It's sourced, so refuse a file other users could change
[[ -z "$(find "$CONFIG_FILE" -perm /022)" ]] || die "Config file '$CONFIG_FILE' is writable by group or others"
BACKUP_STORAGE=""
BACKUP_HOSTS=()
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Checked before anything writes or deletes there: jdupes removes files under this path
[[ "$BACKUP_STORAGE" == /?* ]] || die "BACKUP_STORAGE must be an absolute path other than / in '$CONFIG_FILE'"
[[ -d "$BACKUP_STORAGE" ]] || die "BACKUP_STORAGE '$BACKUP_STORAGE' doesn't exist (storage not mounted?)"
[[ -w "$BACKUP_STORAGE" ]] || die "BACKUP_STORAGE '$BACKUP_STORAGE' isn't writable"

if [[ ${#HOSTNAMES[@]} -eq 0 ]]; then
    HOSTNAMES=("${BACKUP_HOSTS[@]}")
fi
[[ ${#HOSTNAMES[@]} -gt 0 ]] || die "No hosts given and BACKUP_HOSTS is empty in '$CONFIG_FILE'"

# Back up a single device by streaming a tarball over ssh
backup_host() {
    local hostname=$1
    local timestamp dest err

    if [[ ! "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "ERROR: Invalid hostname '$hostname'" >&2
        return 1
    fi

    timestamp=$(date '+%Y-%m-%d-%H%M%S')
    dest="$BACKUP_STORAGE/${hostname}_${timestamp}.tgz"
    log "Backing up $hostname..."

    # Write to .part and rename on success, so a failed transfer never leaves a truncated backup
    if ! err=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$hostname" 'tar -c -z -f - /etc/ /root/' 2>&1 >"$dest.part"); then
        rm -f "$dest.part"
        echo "ERROR: Backup of $hostname failed: $err" >&2
        return 1
    fi
    if ! gzip -t "$dest.part" 2>/dev/null; then
        rm -f "$dest.part"
        echo "ERROR: Backup of $hostname is empty or corrupt" >&2
        return 1
    fi
    mv "$dest.part" "$dest"

    log "Successfully backed up $hostname"
}

failed_backups=()
for hostname in "${HOSTNAMES[@]}"; do
    backup_host "$hostname" || failed_backups+=("$hostname")
done

# Remove duplicate backups, keeping the oldest copy of each
if ! command -v jdupes >/dev/null 2>&1; then
    echo "WARNING: Please install 'jdupes' to remove duplicates!" >&2
else
    log "Removing duplicate files..."
    JDUPES_OUTPUT=$(jdupes -rqdN "$BACKUP_STORAGE" 2>&1)
    if [[ -n "$JDUPES_OUTPUT" ]]; then
        log "$JDUPES_OUTPUT"
    fi
fi

# Report results
if [[ ${#failed_backups[@]} -eq 0 ]]; then
    log "All backups completed successfully!"
    exit 0
fi

MESSAGE="OpenWrt backup failed for: ${failed_backups[*]}"
echo "$MESSAGE" >&2
if command -v slack-notify >/dev/null 2>&1; then
    echo "$MESSAGE" | slack-notify
fi
exit 1
