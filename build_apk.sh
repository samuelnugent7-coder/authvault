#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building AuthVault API (Linux/macOS)..."
cd "$SCRIPT_DIR/api"
go mod tidy
go build -ldflags="-s -w" -o ../build/authvault-api .

echo "Building Flutter APK..."
cd "$SCRIPT_DIR/app"
flutter pub get
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk ../build/authvault.apk

echo ""
echo "Done!"
echo "  API:     build/authvault-api"
echo "  APK:     build/authvault.apk"
