#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$PWD/.build/android-gradle}"
mkdir -p "$GRADLE_USER_HOME/init.d" dist
cp packaging/android-repositories.init.gradle "$GRADLE_USER_HOME/init.d/openkeyboard-repositories.gradle"
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk dist/OpenKeyBoad-Android.apk
