#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

TEMPLATE_DIR="$SCRIPT_DIR/template"
PROPERTIES_FILE="$SCRIPT_DIR/properties"
TARGET_HOME="$HOME"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

INSTALL_PIPEWIRE=false

echo "===================================="
echo "   justlofe/dotfiles installation   "
echo "===================================="
echo

if [[ "$EUID" -eq 0 ]]; then
    echo "error: don't run this script as root."
    exit 1
fi

if [[ ! -d "$TEMPLATE_DIR/home/user" ]]; then
    echo "error: template/home/user not found."
    exit 1
fi

if [[ ! -f "$PROPERTIES_FILE" ]]; then
    echo "error: properties file not found."
    exit 1
fi

hex_to_rgb() {
    local hex="${1#\#}"

    if [[ ! "$hex" =~ ^[[:xdigit:]]{6}$ ]]; then
        echo "Error: Invalid color: $1" >&2
        return 1
    fi

    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))

    echo "$r,$g,$b"
}

while IFS='=' read -r key value || [[ -n "$key" ]]; do

    [[ -z "$key" || "$key" == \#* ]] && continue

    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | xargs)"

    key="${key^^}"

    rgb="$(hex_to_rgb "$value")"
    rgb_alt="${rgb//,/;}"

    printf '%s\t%s\n' "$key" "$value"
    printf '%s_RGB\t%s\n' "$key" "$rgb"
    printf '%s_RGB_ALT\t%s\n' "$key" "$rgb_alt"

done < "$PROPERTIES_FILE" > "$TEMP_DIR/replacements"

echo "[1/5] PipeWire configuration"
echo

PIPEWIRE_TEMPLATE="$TEMPLATE_DIR/home/user/.config/pipewire"
PIPEWIRE_TARGET="$TARGET_HOME/.config/pipewire"

if [[ -d "$PIPEWIRE_TEMPLATE" ]]; then

    read -r -p "install PipeWire configuration? [y/n]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        INSTALL_PIPEWIRE=true

        # Back up existing PipeWire configuration.
        if [[ -e "$PIPEWIRE_TARGET" || -L "$PIPEWIRE_TARGET" ]]; then

            BACKUP_DIR="${PIPEWIRE_TARGET}.backup.$(date +%Y%m%d%H%M%S)"

            mv "$PIPEWIRE_TARGET" "$BACKUP_DIR"

            echo "previous configuration backed up to:"
            echo "$BACKUP_DIR"
        fi
    fi

else
    echo "no PipeWire template found. skipping."
fi

echo
echo "[2/5] installing user configuration..."

python3 - "$TEMPLATE_DIR/home/user" "$TARGET_HOME" \
    "$TEMP_DIR/replacements" "$INSTALL_PIPEWIRE" <<'PYTHON'

import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
replacement_file = pathlib.Path(sys.argv[3])
install_pipewire = sys.argv[4] == "true"

replacements = {}

with replacement_file.open() as file:
    for line in file:
        key, value = line.rstrip("\n").split("\t", 1)
        replacements[key] = value

copied_files = []

def copy_item(src, dst):

    relative = src.relative_to(source)

    # Skip PipeWire if the user declined installation.
    if not install_pipewire:
        if relative == pathlib.Path(".config/pipewire"):
            return

    if src.is_symlink():

        dst.parent.mkdir(parents=True, exist_ok=True)

        if dst.exists() or dst.is_symlink():
            if dst.is_dir() and not dst.is_symlink():
                shutil.rmtree(dst)
            else:
                dst.unlink()

        dst.symlink_to(src.readlink())
        return

    if src.is_dir():

        dst.mkdir(parents=True, exist_ok=True)

        for child in src.iterdir():
            copy_item(child, dst / child.name)

    elif src.is_file():

        dst.parent.mkdir(parents=True, exist_ok=True)

        shutil.copy2(src, dst)
        copied_files.append(dst)

# Copy all template files, including hidden files.
for item in source.iterdir():
    copy_item(item, target / item.name)

# Replace placeholders only in copied files.
for item in copied_files:

    try:
        content = item.read_bytes()
        text = content.decode("utf-8")
    except (UnicodeDecodeError, OSError):
        continue

    for key, value in replacements.items():
        text = text.replace("{{" + key + "}}", value)

    item.write_text(text, encoding="utf-8")

print("User configuration installed.")

PYTHON

echo
echo "[3/5] installing system configuration..."

if [[ -f "$TEMPLATE_DIR/etc/locale.gen" ]]; then

    sudo install -D \
        "$TEMPLATE_DIR/etc/locale.gen" \
        /etc/locale.gen

    echo "locale.gen installed."

fi

if [[ "$INSTALL_PIPEWIRE" == true ]]; then

    echo
    echo "restarting PipeWire services..."

    for service in pipewire.service pipewire-pulse.service wireplumber.service; do

        if systemctl --user list-unit-files "$service" >/dev/null 2>&1; then
            systemctl --user restart "$service" || \
                echo "Warning: Could not restart $service"
        fi

    done

    echo "PipeWire restart completed."

fi

echo
echo "[4/5] reloading KDE Plasma..."

if [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]] ||
   [[ "${DESKTOP_SESSION:-}" == *"plasma"* ]]; then

    if command -v qdbus6 >/dev/null 2>&1; then

        qdbus6 org.kde.KWin /KWin reconfigure || true

    elif command -v qdbus >/dev/null 2>&1; then

        qdbus org.kde.KWin /KWin reconfigure || true

    fi

    if command -v plasmashell >/dev/null 2>&1; then
        plasmashell --replace >/dev/null 2>&1 &
        echo "plasma shell restart requested."
    fi

else
    echo "KDE Plasma not detected. Skipping."
fi


echo
echo "synchronizing Plasma Login Manager settings..."

if ! id plasmalogin >/dev/null 2>&1; then
    echo "warning: plasmalogin system user not found."
else
    PLM_HOME="$(getent passwd plasmalogin | cut -d: -f6)"

    if [[ -z "$PLM_HOME" || ! -d "$PLM_HOME" ]]; then
        echo "warning: Plasma Login Manager home directory not found."
    else

        PLM_CONFIG_DIR="$PLM_HOME/.config"

        sudo mkdir -p "$PLM_CONFIG_DIR"

        for config in \
            kdeglobals \
            plasmarc \
            kcminputrc \
            kwinoutputconfig.json
        do
            if [[ -f "$TARGET_HOME/.config/$config" ]]; then
                sudo cp "$TARGET_HOME/.config/$config" \
                    "$PLM_CONFIG_DIR/$config"

                echo "synchronized: $config"
            fi
        done

        if [[ -d "$TARGET_HOME/.local/share/kscreen" ]]; then
            sudo mkdir -p "$PLM_HOME/.local/share"

            sudo cp -a \
                "$TARGET_HOME/.local/share/kscreen" \
                "$PLM_HOME/.local/share/"
        fi

        sudo chown -R plasmalogin:plasmalogin "$PLM_CONFIG_DIR"

        if [[ -d "$PLM_HOME/.local/share/kscreen" ]]; then
            sudo chown -R plasmalogin:plasmalogin \
                "$PLM_HOME/.local/share/kscreen"
        fi

        echo "plasma Login Manager synchronization completed."
    fi
fi


echo
echo "[5/5] Generating locales..."

sudo locale-gen

echo
echo "===================================="
echo "Installation completed successfully!"
echo "===================================="
