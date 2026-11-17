#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sources.env
source "$root/sources.env"

target=jamesdonkey/rs2_30/reference
board=keyboards/jamesdonkey/rs2_30
cache="$root/.build"
qmk="$cache/qmk"
venv="$cache/venv"
dist="$root/dist"
mode="${1:-via}"
if [[ "$mode" != via ]]; then
    printf 'Usage: %s [via]\n' "$0" >&2
    exit 2
fi

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

# The RS2 owns its matrix, PWM scheduling, and display code. The pinned
# AK820 Pro platform patches supply the SN32 peripherals they use.
hal="$qmk/lib/chibios-contrib"
patch="$root/patches/rs2-platform.patch"
if ! git -C "$hal" apply --reverse --check "$patch" 2>/dev/null; then
    git -C "$hal" apply --whitespace=nowarn "$patch"
fi
patch="$root/patches/rs2-wireless-leds.patch"
if ! git -C "$qmk" apply --reverse --check "$patch" 2>/dev/null; then
    git -C "$qmk" apply "$patch"
fi

if [[ ! -x "$venv/bin/qmk" ]]; then
    python3 -m venv "$venv"
    "$venv/bin/python" -m pip install "qmk==$QMK_CLI_VERSION" -r "$qmk/requirements.txt"
fi
export PATH="$venv/bin:$PATH"

mkdir -p "$qmk/$board" "$dist"
cp -R "$root/$board/." "$qmk/$board/"
make -C "$qmk" SKIP_GIT=yes -j "${JOBS:-$(nproc)}" "$target:via"

image=RS2-via.bin
payload="$qmk/${target//\//_}_via.bin"
test "$(wc -c < "$payload")" -eq 262144
cp "$payload" "$dist/$image"
cp "$root/$board/reference/via.json" "$dist/RS2-VIA.json"
cd "$dist"
sha256sum "$image" > "$image.sha256"
sha256sum -c "$image.sha256"
printf 'Built %s/%s\n' "$dist" "$image"
