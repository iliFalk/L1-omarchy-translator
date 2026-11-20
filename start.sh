#!/usr/bin/env bash
# One file to run after unpacking this repository.
#
#   bash start.sh              install the widget
#   bash start.sh --uninstall  remove it
#
# An unpacked archive drops the executable bit, so this script sets it on the
# installer and hands over. It must work when called as `bash start.sh`.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
installer="$here/install.sh"

if [[ ! -f $installer ]]; then
  printf 'Not a checkout: %s/install.sh is missing.\n' "$here" >&2
  printf 'Unpack the whole archive, then run this file inside that folder.\n' >&2
  exit 1
fi

chmod +x "$installer"
exec bash "$installer" "$@"
