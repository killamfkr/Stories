#!/usr/bin/env bash
# Populate libtorrent_flutter prebuilt JNI libs when GitHub Release zips are unavailable.
set -euo pipefail

if [[ "${LIBTORRENT_FLUTTER_SKIP_DOWNLOAD:-}" == "true" ]]; then
  exit 0
fi

PKG_DIR="${1:-}"
if [[ -z "$PKG_DIR" ]]; then
  PKG_DIR="$(find "${PUB_CACHE:-$HOME/.pub-cache}" -maxdepth 3 -type d -name 'libtorrent_flutter-*' 2>/dev/null | sort -V | tail -1)"
fi
if [[ -z "$PKG_DIR" || ! -d "$PKG_DIR" ]]; then
  echo "seed_libtorrent_prebuilts: libtorrent_flutter package dir not found"
  exit 1
fi

PREBUILT_ROOT="$PKG_DIR/prebuilt/android"
abis=(arm64-v8a armeabi-v7a x86_64)

all_present=true
for abi in "${abis[@]}"; do
  if [[ ! -f "$PREBUILT_ROOT/$abi/liblibtorrent_flutter.so" ]]; then
    all_present=false
    break
  fi
done
if $all_present; then
  echo "seed_libtorrent_prebuilts: prebuilts already present"
  exit 0
fi

VERSION="$(grep -m1 '^version:' "$PKG_DIR/pubspec.yaml" | sed 's/version:[[:space:]]*//' | tr -d '\r')"
RELEASE_BASE="https://github.com/ayman708-UX/libtorrent_flutter/releases/download/v${VERSION}"

for abi in "${abis[@]}"; do
  dest="$PREBUILT_ROOT/$abi"
  so="$dest/liblibtorrent_flutter.so"
  [[ -f "$so" ]] && continue
  mkdir -p "$dest"
  zip_url="${RELEASE_BASE}/android-native-lib-${abi}.zip"
  tmp_zip="$(mktemp)"
  if curl -fsSL --retry 3 --retry-delay 2 "$zip_url" -o "$tmp_zip"; then
    unzip -qo "$tmp_zip" -d "$dest"
    rm -f "$tmp_zip"
    if [[ -f "$so" ]]; then
      echo "seed_libtorrent_prebuilts: fetched $abi from release"
      continue
    fi
  fi
  rm -f "$tmp_zip"
  echo "seed_libtorrent_prebuilts: release zip missing for $abi"
done

all_present=true
for abi in "${abis[@]}"; do
  if [[ ! -f "$PREBUILT_ROOT/$abi/liblibtorrent_flutter.so" ]]; then
    all_present=false
  fi
done
if $all_present; then
  exit 0
fi

# Fallback: extract JNI libs from the newest Stories APK that shipped them.
APK_URL="${STORIES_SEED_APK_URL:-https://github.com/killamfkr/Stories/releases/download/v1.0.0-20/stories-1.0.0-20.apk}"
tmp_apk="$(mktemp)"
trap 'rm -f "$tmp_apk"' EXIT
echo "seed_libtorrent_prebuilts: extracting from Stories APK"
curl -fsSL --retry 3 --retry-delay 2 "$APK_URL" -o "$tmp_apk"
for abi in "${abis[@]}"; do
  dest="$PREBUILT_ROOT/$abi"
  mkdir -p "$dest"
  unzip -qo -j "$tmp_apk" "lib/${abi}/liblibtorrent_flutter.so" -d "$dest"
done

for abi in "${abis[@]}"; do
  if [[ ! -f "$PREBUILT_ROOT/$abi/liblibtorrent_flutter.so" ]]; then
    echo "seed_libtorrent_prebuilts: failed to seed $abi"
    exit 1
  fi
done
echo "seed_libtorrent_prebuilts: seeded all ABIs from APK"
