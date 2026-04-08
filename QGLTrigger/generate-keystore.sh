#!/bin/bash
# Generate a debug keystore for signing the QGLTrigger APK
# This MUST be run on a machine with Java JDK installed before building.
# The APK will NOT install without a valid signing certificate.
#
# Usage: bash generate-keystore.sh
# Or run manually:
#   keytool -genkeypair -v -keystore app/debug.keystore -storepass android \
#     -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 \
#     -validity 10000 -dname "CN=Android Debug,O=Android,C=US"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYSTORE="$SCRIPT_DIR/app/debug.keystore"

if [ -f "$KEYSTORE" ]; then
  echo "Keystore already exists at $KEYSTORE"
  exit 0
fi

if ! command -v keytool &>/dev/null; then
  echo "ERROR: keytool not found. Install Java JDK first."
  echo "  Ubuntu/Debian: sudo apt install default-jdk"
  echo "  Arch: sudo pacman -S jdk-openjdk"
  exit 1
fi

keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -storepass android \
  -alias androiddebugkey \
  -keypass android \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -dname "CN=Android Debug,O=Android,C=US" 2>&1

if [ -f "$KEYSTORE" ]; then
  echo "Keystore generated successfully: $KEYSTORE"
else
  echo "ERROR: Failed to generate keystore"
  exit 1
fi
