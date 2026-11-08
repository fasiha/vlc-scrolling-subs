#!/bin/sh
# Download and unpack VLCKit 3.7.3 into Vendor/ (gitignored). Run once before ./build-app.sh.
set -e
cd "$(dirname "$0")"
F=VLCKit-3.7.3-319ed2c0-79128878.tar.xz
mkdir -p Vendor
[ -f "Vendor/$F" ] || curl -fL -o "Vendor/$F" "https://download.videolan.org/pub/cocoapods/prod/$F"
[ -d Vendor/VLCKit.xcframework ] || { tar -xJf "Vendor/$F" -C Vendor && X=$(find Vendor -name VLCKit.xcframework -type d | head -1) && [ "$X" = Vendor/VLCKit.xcframework ] || mv "$X" Vendor/; }
echo "VLCKit ready in Vendor/VLCKit.xcframework"
