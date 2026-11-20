#!/usr/bin/env bash
# Install L1 Translator into the Omarchy shell plugin directory.
#
#   bash install.sh              install and enable
#   bash install.sh --yes        the same, without asking
#   bash install.sh --uninstall  remove the widget
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
id="L1-translator"
target="${HOME}/.config/omarchy/plugins/${id}"
assume_yes=0
mode=install

usage() {
  cat <<'USAGE'
Usage: bash install.sh [--yes] [--uninstall]

  --yes        do not ask before enabling the widget
  --uninstall  disable and remove the widget
USAGE
}

for argument in "$@"; do
  case $argument in
    -y|--yes) assume_yes=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

missing=()
for tool in omarchy omarchy-shell; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
  printf 'Cannot continue: %s not found on PATH.\n' "${missing[*]}" >&2
  printf 'This widget runs inside the Omarchy shell. Install Omarchy first.\n' >&2
  exit 1
fi

if [[ $mode == uninstall ]]; then
  # Every step is checked: a removal that only looks done leaves a widget
  # running with the user's rights while telling the user it is gone.
  status=0
  omarchy plugin disable "$id" || status=1
  omarchy plugin remove "$id" || status=1
  omarchy-shell shell rescanPlugins || status=1
  if [[ -d $target ]]; then
    printf 'Still present: %s\n' "$target" >&2
    status=1
  fi
  if (( status == 0 )); then
    printf 'Removed %s.\n' "$id"
  else
    printf 'Removal did not complete. Check with: omarchy plugin list --json | grep %s\n' "$id" >&2
  fi
  exit $status
fi

files=(manifest.json BarWidget.qml Panel.qml Model.js README.md LICENSE)
for file in "${files[@]}"; do
  if [[ ! -f "$here/$file" ]]; then
    printf 'Cannot continue: %s/%s is missing.\n' "$here" "$file" >&2
    printf 'Unpack the whole archive and run this file inside that folder.\n' >&2
    exit 1
  fi
done

install -d -m 700 "$target"
for file in "${files[@]}"; do
  cp -f "$here/$file" "$target/$file"
done

if [[ ! -f "$target/config.json" ]]; then
  # 600 from creation, inside a 700 directory: the key is never readable by
  # another local user, not even for the moment between write and chmod.
  install -m 600 "$here/config.example.json" "$target/config.json"
  printf 'Created %s/config.json — put your key in it.\n' "$target"
fi

omarchy plugin validate "$target"
omarchy-shell shell rescanPlugins

if (( assume_yes == 0 )); then
  printf 'Place the widget on the bar now? [Y/n] '
  read -r answer
  case $answer in
    n|N|no|NO) printf 'Skipped placement. Run: omarchy plugin enable %s --section centerEnd\n' "$id"; exit 0 ;;
  esac
fi

omarchy plugin enable "$id" --section centerEnd \
  || omarchy bar put "$id" --section centerEnd

cat <<EOF

Placed on the bar. Two steps are left:

1. Put the token into ${target}/config.json, or use the gear in the popup.
2. Add the hotkey to ~/.config/hypr/bindings/, then run: hyprctl reload

   o.bind("SUPER + Y", "Translate selection", "omarchy-shell -q shell toggle ${id}")

EOF
