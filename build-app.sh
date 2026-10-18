#!/bin/sh
# Builds build/ReolinkViewer.app as a universal (arm64 + x86_64) binary, writes its dSYM to
# build/ReolinkViewer.dSYM, code-signs it and, when credentials are available, notarizes it,
# staples the ticket and zips it to build/ReolinkViewer.zip.
#
# Environment:
#   CODESIGN_IDENTITY   certificate name or SHA-1 hash. Default: the first "Developer ID
#                       Application" certificate in the keychain, else ad-hoc (this Mac only).
#   APP_BUILD           written to CFBundleVersion (CI passes the commit count).
#   NOTARY_PROFILE      notarytool keychain profile, created once with
#                       xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password …
#   APPLE_DEVELOPER_USERNAME / APPLE_DEVELOPER_PASSWORD [/ TEAM_ID]
#                       alternative to NOTARY_PROFILE (for CI).
#                       TEAM_ID defaults to the signing certificate's team.
#   REQUIRE_NOTARIZATION=1
#                       fail instead of stopping after signing when no credentials are set (CI).
#   ARCHS               override the architectures, e.g. "--arch arm64" for a quick local build.
set -e
cd "$(dirname "$0")"

ARCHS="${ARCHS:---arch arm64 --arch x86_64}"
echo "▸ swift build -c release $ARCHS"
swift build -c release $ARCHS --product ReolinkViewer >/dev/null
# Swift 6.2 builds multi-arch products with the Xcode build system under .build/apple;
# Swift 6.4 and single-arch builds use .build/release.
if [ -x .build/apple/Products/Release/ReolinkViewer ]; then
    BIN=.build/apple/Products/Release/ReolinkViewer
else
    BIN=.build/release/ReolinkViewer
fi

APP=build/ReolinkViewer.app
rm -rf "$APP" build/ReolinkViewer.zip build/ReolinkViewer.dSYM
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReolinkViewer"
cp Sources/ReolinkViewer/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon: AppIcon.icon (Icon Composer document) → Assets.car (layered icon for macOS 26)
# plus AppIcon.icns (flattened fallback for older systems). Info.plist already names "AppIcon".
echo "▸ actool AppIcon.icon"
rm -rf build/icon && mkdir -p build/icon
xcrun actool AppIcon.icon --compile build/icon --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --include-all-app-icons --output-partial-info-plist build/icon/partial.plist \
    --output-format human-readable-text >/dev/null
cp build/icon/Assets.car build/icon/AppIcon.icns "$APP/Contents/Resources/"
if [ -n "$APP_BUILD" ]; then
    plutil -replace CFBundleVersion -string "$APP_BUILD" "$APP/Contents/Info.plist"
fi
echo "▸ version $(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")), architectures: $(lipo -archs "$BIN")"

echo "▸ dsymutil → build/ReolinkViewer.dSYM"
dsymutil "$BIN" -o build/ReolinkViewer.dSYM

if [ -z "$CODESIGN_IDENTITY" ]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
fi
if [ -z "$CODESIGN_IDENTITY" ]; then
    echo "▸ no Developer ID certificate found: signing ad-hoc (runs on this Mac only)"
    codesign --force --sign - "$APP"
    echo "Built $APP (ad-hoc)"
    exit 0
fi

# codesign refuses a name that matches several certificates, so sign by SHA-1 hash.
case "$CODESIGN_IDENTITY" in
    *[!0-9A-Fa-f]*|"") IDENTITY_HASH=$(security find-identity -v -p codesigning | grep -F "\"$CODESIGN_IDENTITY\"" | head -1 | awk '{print $2}') ;;
    *) IDENTITY_HASH="$CODESIGN_IDENTITY" ;;
esac
if [ -z "$IDENTITY_HASH" ]; then
    echo "certificate not found in keychain: $CODESIGN_IDENTITY" >&2
    exit 1
fi
echo "▸ signing with: $CODESIGN_IDENTITY ($IDENTITY_HASH)"
codesign --force --timestamp --options runtime --sign "$IDENTITY_HASH" "$APP"
codesign --verify --strict --verbose=1 "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    set -- --keychain-profile "$NOTARY_PROFILE"
elif [ -n "$APPLE_DEVELOPER_USERNAME" ] && [ -n "$APPLE_DEVELOPER_PASSWORD" ]; then
    TEAM_ID="${TEAM_ID:-$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')}"
    set -- --apple-id "$APPLE_DEVELOPER_USERNAME" --password "$APPLE_DEVELOPER_PASSWORD" --team-id "$TEAM_ID"
else
    if [ -n "$REQUIRE_NOTARIZATION" ]; then
        echo "no notarization credentials: set NOTARY_PROFILE or APPLE_DEVELOPER_USERNAME/APPLE_DEVELOPER_PASSWORD" >&2
        exit 1
    fi
    echo "Built $APP (signed, not notarized: set NOTARY_PROFILE or APPLE_DEVELOPER_USERNAME/APPLE_DEVELOPER_PASSWORD)"
    exit 0
fi

echo "▸ notarizing"
ditto -c -k --keepParent "$APP" build/ReolinkViewer.zip
xcrun notarytool submit build/ReolinkViewer.zip "$@" --wait
xcrun stapler staple "$APP"
rm build/ReolinkViewer.zip
ditto -c -k --keepParent "$APP" build/ReolinkViewer.zip
spctl --assess --type execute --verbose=1 "$APP"
echo "Built and notarized: build/ReolinkViewer.zip"
