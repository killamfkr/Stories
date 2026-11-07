#!/usr/bin/env bash
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export PATH="/opt/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

LOG="${BUILD_LOG:-/tmp/flutter-apk-build.log}"
exec >"$LOG" 2>&1

echo "=== build started $(date -u +%FT%TZ) ==="

flutter create . --project-name audiobook_app --org com.playtorrio.audiobook
bash tool/patch_android.sh
flutter pub get
bash tool/seed_libtorrent_prebuilts.sh
bash tool/patch_audio_service.sh
dart run flutter_launcher_icons

flutter build apk --release \
  --android-skip-build-dependency-validation \
  -PlibtorrentFlutterSkipDownload=true

VERSION="$(grep '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//' | tr '+' '-')"
APK_NAME="stories-${VERSION}.apk"
mkdir -p /opt/cursor/artifacts
cp build/app/outputs/flutter-apk/app-release.apk "/opt/cursor/artifacts/${APK_NAME}"

echo "=== build finished $(date -u +%FT%TZ) ==="
echo "APK: /opt/cursor/artifacts/${APK_NAME}"
