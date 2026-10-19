#!/usr/bin/env bash
set -euo pipefail

mode="${1:-install}"
case "$mode" in install|uninstall) ;; *) echo "Usage: $0 install|uninstall" >&2; exit 1 ;; esac
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
agent_dir=$(omp config path)
[[ -n "$agent_dir" ]] || { echo "omp returned an empty config directory" >&2; exit 1; }
target="$agent_dir/extensions/puppy.ts"
source="$repo_dir/Support/omp-puppy.ts"

if [[ "$mode" == uninstall ]]; then
    if [[ -f "$target" ]] && cmp -s "$source" "$target"; then
        rm -- "$target"
        echo "Removed $target"
    elif [[ -e "$target" || -L "$target" ]]; then
        echo "Refusing to remove a modified extension: $target" >&2
        exit 1
    fi
else
    mkdir -p -- "$(dirname -- "$target")"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" ]] || { echo "Not a regular file: $target" >&2; exit 1; }
        if cmp -s "$source" "$target"; then
            echo "Already installed: $target"
            exit 0
        fi
        backup=$(mktemp -d "$agent_dir/puppy-backup.XXXXXX")
        cp -p -- "$target" "$backup/puppy.ts"
        echo "Backup: $backup/puppy.ts"
    fi
    temporary=$(mktemp "$(dirname -- "$target")/.puppy.XXXXXX")
    trap 'rm -f -- "$temporary"' EXIT
    cp -- "$source" "$temporary"
    mv -f -- "$temporary" "$target"
    echo "Installed $target"
fi
echo 'Restart existing omp sessions to load the extension change.'
