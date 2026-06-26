#!/usr/bin/env bash
# Wire android/app/build.gradle.kts to use android/key.properties when present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRADLE="$ROOT/android/app/build.gradle.kts"

if [[ ! -f "$GRADLE" ]]; then
  echo "error: run flutter create first (missing $GRADLE)" >&2
  exit 1
fi

python3 - "$GRADLE" <<'PY'
import re
import sys
from pathlib import Path

gradle = Path(sys.argv[1])
text = gradle.read_text()
marker = "stories-release-signing"

if marker in text:
    print("Release signing already configured in build.gradle.kts")
    raise SystemExit(0)

if "import java.util.Properties" not in text:
    text = (
        "import java.io.FileInputStream\n"
        "import java.util.Properties\n\n"
        + text
    )

android_idx = text.index("android {")
keystore_block = """
// stories-release-signing
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

"""
text = text[:android_idx] + keystore_block + text[android_idx:]

release_pattern = re.compile(
    r"\s*buildTypes\s*\{\s*release\s*\{[^}]*"
    r"signingConfig\s*=\s*signingConfigs\.getByName\(\"debug\"\)\s*\}\s*\}",
    re.DOTALL,
)
replacement = """    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }"""

new_text, count = release_pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit("error: could not patch release signing in build.gradle.kts")

gradle.write_text(new_text)
print("Configured optional release signing in build.gradle.kts")
PY
