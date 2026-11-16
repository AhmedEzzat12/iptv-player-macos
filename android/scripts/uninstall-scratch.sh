#!/bin/bash
# Removes the scratch build and its data from a device. Usage: android/scripts/uninstall-scratch.sh <serial>
set -euo pipefail
source "$(dirname "$0")/env.sh"
adb -s "${1:?usage: uninstall-scratch.sh <adb serial>}" uninstall app.antenna.player.scratch
