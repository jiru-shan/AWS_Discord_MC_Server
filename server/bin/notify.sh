#!/usr/bin/env bash
# Post a single message to the Discord webhook. Used by servermanager.js and the
# lifecycle scripts so there is one implementation of the notification logic.
set -euo pipefail
. "$(dirname "$0")/common.sh"
notify "${1:-}"
