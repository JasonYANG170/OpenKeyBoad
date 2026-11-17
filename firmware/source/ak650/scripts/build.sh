#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/sources.env"

target=a_jazz/ak650/reference
board=keyboards/a_jazz/ak650
cache="$root/.build"
qmk="$cache/qmk"
venv="$cache/venv"
mode="${1:-via}"
case "$mode" in
    via|default)
        keymap="$mode"
        flags=()
        ;;
    matrix-test)
        keymap=via
        flags=(AK650_MATRIX_TEST=yes)
        ;;
    *)
        printf 'Usage: %s [via|default|matrix-test]\n' "$0" >&2
        exit 2
        ;;
esac

if [[ ! -d "$qmk/.git" ]]; then
    git init --quiet "$qmk"
    git -C "$qmk" remote add origin "$QMK_REPO"
fi
if ! git -C "$qmk" cat-file -e "$QMK_COMMIT^{commit}" 2>/dev/null; then
    git -C "$qmk" fetch --depth 1 origin "$QMK_COMMIT"
fi
if [[ "$(git -C "$qmk" rev-parse --verify HEAD 2>/dev/null || true)" != "$QMK_COMMIT" ]]; then
    git -C "$qmk" checkout --detach "$QMK_COMMIT"
fi
git -C "$qmk" submodule update --init --depth 1 lib/chibios lib/chibios-contrib lib/lufa lib/printf

apply_patch_once() {
    local checkout="$1" patch="$2"
    if ! git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
        git -C "$checkout" apply "$patch"
    fi
}
apply_patch_once "$qmk" "$root/patches/ak650-platform.patch"
apply_patch_once "$qmk" "$root/patches/ak650-wireless-leds.patch"
for patch in hardware_pwm i2c_fallback rtc_lld spi_fifo_pump spi_flash_dma efl_ramtext; do
    apply_patch_once "$qmk/lib/chibios-contrib" "$qmk/keyboards/a_jazz/ak820pro/$patch.diff"
done

if [[ ! -x "$venv/bin/qmk" ]]; then
    python3 -m venv "$venv"
    "$venv/bin/python" -m pip install "qmk==$QMK_CLI_VERSION" -r "$qmk/requirements.txt"
fi
export PATH="$venv/bin:$PATH"

mkdir -p "$qmk/$board" "$root/dist"
cp -R "$root/$board/." "$qmk/$board/"
cd "$qmk"
python3 "$board/generate_reference.py"
make SKIP_GIT=yes -j "${JOBS:-$(nproc)}" "$target:$keymap" "${flags[@]}"
image="AK650-$mode.bin"
cp "a_jazz_ak650_reference_$keymap.bin" "$root/dist/$image"
if [[ "$keymap" == via ]]; then
    cp "$board/reference/via.json" "$root/dist/AK650-VIA.json"
fi
cd "$root/dist"
sha256sum "$image" > "$image.sha256"
printf 'Built %s/dist/%s\n' "$root" "$image"
