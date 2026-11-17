set -euo pipefail
cd "$(dirname "$0")/.."
target=${1:?linux or macos}
case "$target" in linux|macos) ;; *) exit 2 ;; esac
mkdir -p dist
flutter build "$target" --release
flutter build web --release --no-web-resources-cdn
arch=$(uname -m)
[[ "$arch" == aarch64 ]] && arch=arm64
stage="dist/$target-$arch"
mkdir -p "$stage/web"
(cd bridge && dart pub get && dart compile exe bin/main.dart -o "../$stage/KeyboardControl")
cp -R build/web/. "$stage/web/"
cp -R firmware "$stage/"
cp README.md README.en.md LICENSE "$stage/"
if [[ "$target" == linux ]]; then
  cp -R build/linux/x64/release/bundle "$stage/native"
  cp linux/70-keyboard-control.rules "$stage/"
else
  app=$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)
  [[ -n "$app" ]]
  mkdir -p "$app/Contents/Frameworks"
  cp -L "$(brew --prefix hidapi)/lib/libhidapi.dylib" "$app/Contents/Frameworks/"
  codesign --force --deep --sign - "$app"
  cp -R "$app" "$stage/"
  cp -L "$(brew --prefix hidapi)/lib/libhidapi.dylib" "$stage/"
  cp "$(brew --prefix hidapi)/share/licenses/hidapi/LICENSE-bsd.txt" "$stage/HIDAPI-LICENSE.txt" 2>/dev/null || curl -fsSL https://raw.githubusercontent.com/libusb/hidapi/hidapi-0.15.0/LICENSE-bsd.txt -o "$stage/HIDAPI-LICENSE.txt"
fi
cat > "$stage/Connect-Phone.command" <<'SH'
#!/bin/sh
cd "$(dirname "$0")"
exec ./KeyboardControl --lan
SH
chmod +x "$stage/KeyboardControl" "$stage/Connect-Phone.command"
tar -C dist -czf "dist/OpenKeyBoad-$target-$arch.tar.gz" "$target-$arch"
