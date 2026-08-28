#!/usr/bin/env bash
# Pull the latest payload uploaded by Terraform and reinstall the scripts.
#
# Terraform re-uploads server/ on every apply, but a running instance keeps the
# copy it downloaded at first boot. Run this (or `mc update`) to pick up script
# changes without rebuilding the instance.
set -euo pipefail
. "$(dirname "$0")/common.sh"

[ -n "${PAYLOAD_BUCKET:-}" ] || die "PAYLOAD_BUCKET is not set in $CONFIG_FILE"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "downloading s3://$PAYLOAD_BUCKET/$PAYLOAD_KEY"
aws s3 cp "s3://$PAYLOAD_BUCKET/$PAYLOAD_KEY" "$tmp/payload.zip" --only-show-errors \
  || die "could not download the payload"

unzip -qo "$tmp/payload.zip" -d "$tmp/payload"

rm -rf "$INSTALL_DIR/payload"
mkdir -p "$INSTALL_DIR/payload"
cp -a "$tmp/payload/." "$INSTALL_DIR/payload/"

# Install through a rename rather than in place. This script lives in the
# directory it is updating, and bash reads a script incrementally as it runs:
# truncating and rewriting the file underneath a running shell corrupts
# execution. A rename swaps the directory entry and leaves the running inode
# alone.
replace() {
  local src="$1" dest="$2" mode="$3"
  install -m "$mode" "$src" "$dest.new"
  mv -f "$dest.new" "$dest"
}

for script in "$INSTALL_DIR/payload/bin/"*.sh "$INSTALL_DIR/payload/bin/"*.js; do
  replace "$script" "$INSTALL_DIR/bin/$(basename "$script")" 0755
done
replace "$INSTALL_DIR/payload/bin/mc" "$MC_BIN_LINK" 0755

for unit in "$INSTALL_DIR/payload/systemd/"*.service; do
  replace "$unit" "$SYSTEMD_DIR/$(basename "$unit")" 0644
done
systemctl daemon-reload

log "payload updated; restart minecraft.service to run the new servermanager"
