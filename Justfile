# SafeGuardian Build Justfile

# RAM guardrails applied to every xcodebuild invocation:
#   -jobs 4           cap parallel Swift compiler instances
#   COMPILER_INDEX_STORE_ENABLE=NO  skip index (not needed outside Xcode IDE)
# These are additive to the Debug.xcconfig settings (singlefile + no index store).
BUILD_FLAGS := "-jobs 4 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO"
SCHEME_MACOS := "SafeGuardian (macOS)"
SCHEME_IOS   := "SafeGuardian (iOS)"
ARCHIVE_PATH := "/tmp/SafeGuardian.xcarchive"
EXPORT_PATH  := "/tmp/SafeGuardian-ipa"
TEAM_ID      := "V9KH637N7P"
DEVICE_ID    := "49850A95-19B2-5706-A37F-C0E37A5FDF60"

default:
    @echo "SafeGuardian Build Commands:"
    @echo "  just build              - Build the macOS app (no signing)"
    @echo "  just build-ios          - Build the iOS app (no signing)"
    @echo "  just install            - Build and install onto paired iPhone 16"
    @echo "  just archive            - Archive iOS Release for distribution"
    @echo "  just run                - Build and launch macOS app"
    @echo "  just clean              - Clean build artifacts"
    @echo "  just check              - Check prerequisites"

check:
    @echo "Checking prerequisites..."
    @command -v xcodebuild >/dev/null 2>&1 || (echo "xcodebuild not found — install Xcode" && exit 1)
    @xcode-select -p | grep -q "Xcode.app" || (echo "Full Xcode required — sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" && exit 1)
    @bash scripts/check_agent_names.sh
    @echo "Prerequisites met"

# Verify no debug-only symbols (ConversationLogger) leaked into a Release binary.
verify-release-clean:
    @echo "Building Release to verify no debug symbols leak..."
    @xcodebuild -project SafeGuardian.xcodeproj \
        -scheme "{{SCHEME_MACOS}}" \
        -configuration Release \
        {{BUILD_FLAGS}} \
        build 2>&1 | tail -1
    @APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/SafeGuardian-*/Build/Products/Release/SafeGuardian.app 2>/dev/null | head -1) && \
     BIN="$$APP/Contents/MacOS/SafeGuardian" && \
     if strings "$$BIN" | grep -q "ConversationLogger"; then \
         echo "FAILURE: ConversationLogger found in Release binary"; exit 1; \
     else \
         echo "OK: no debug logging symbols in Release binary"; \
     fi

build:
    @echo "Building SafeGuardian (macOS)..."
    @xcodebuild -project SafeGuardian.xcodeproj \
        -scheme "{{SCHEME_MACOS}}" \
        -configuration Debug \
        {{BUILD_FLAGS}} \
        build

run: build
    @ls -td ~/Library/Developer/Xcode/DerivedData/SafeGuardian-*/Build/Products/Debug/SafeGuardian.app 2>/dev/null \
        | head -1 | xargs open

build-ios:
    @echo "Building SafeGuardian (iOS)..."
    @xcodebuild -project SafeGuardian.xcodeproj \
        -scheme "{{SCHEME_IOS}}" \
        -destination "generic/platform=iOS" \
        -configuration Debug \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM={{TEAM_ID}} \
        -allowProvisioningUpdates \
        -jobs 4 \
        COMPILER_INDEX_STORE_ENABLE=NO \
        build

# Build and install directly onto the paired iPhone 16.
# Requires the V9KH637N7P team cert and the device registered in the portal.
# Override the team with: just install TEAM=MUGWTN844R
install TEAM="V9KH637N7P":
    @echo "Installing SafeGuardian onto device {{DEVICE_ID}}..."
    @xcodebuild -project SafeGuardian.xcodeproj \
        -scheme "{{SCHEME_IOS}}" \
        -destination "id:{{DEVICE_ID}}" \
        -configuration Debug \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM={{TEAM}} \
        -allowProvisioningUpdates \
        -jobs 4 \
        COMPILER_INDEX_STORE_ENABLE=NO \
        build

# Archive a Release .xcarchive — prerequisite for export-testflight.
# Requires the V9KH637N7P team cert to be present in the default keychain.
archive:
    @echo "Archiving SafeGuardian (iOS) Release..."
    @xcodebuild -project SafeGuardian.xcodeproj \
        -scheme "{{SCHEME_IOS}}" \
        -destination "generic/platform=iOS" \
        -configuration Release \
        -archivePath "{{ARCHIVE_PATH}}" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM={{TEAM_ID}} \
        -allowProvisioningUpdates \
        -jobs 4 \
        COMPILER_INDEX_STORE_ENABLE=NO \
        archive
    @echo "Archive written to {{ARCHIVE_PATH}}"

# Export .ipa and upload directly to TestFlight (destination=upload in plist).
# Requires API key env vars: APP_STORE_CONNECT_API_KEY_ID,
# APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_API_KEY_CONTENT (base64 .p8).
export-testflight: archive
    @echo "Exporting and uploading to TestFlight..."
    @if [ -n "$$APP_STORE_CONNECT_API_KEY_CONTENT" ]; then \
        mkdir -p /tmp/asc-key && \
        echo "$$APP_STORE_CONNECT_API_KEY_CONTENT" | base64 -d > /tmp/asc-key/AuthKey_$$APP_STORE_CONNECT_API_KEY_ID.p8; \
    fi
    @xcodebuild -exportArchive \
        -archivePath "{{ARCHIVE_PATH}}" \
        -exportOptionsPlist ExportOptions-TestFlight.plist \
        -exportPath "{{EXPORT_PATH}}" \
        -allowProvisioningUpdates \
        $([ -n "$$APP_STORE_CONNECT_API_KEY_ID" ] && echo \
            "-authenticationKeyID $$APP_STORE_CONNECT_API_KEY_ID \
             -authenticationKeyIssuerID $$APP_STORE_CONNECT_ISSUER_ID \
             -authenticationKeyPath /tmp/asc-key/AuthKey_$$APP_STORE_CONNECT_API_KEY_ID.p8" \
        || true)
    @echo "Export written to {{EXPORT_PATH}}"

clean:
    @echo "Cleaning build artifacts..."
    @rm -rf ~/Library/Developer/Xcode/DerivedData/SafeGuardian-* 2>/dev/null || true
    @rm -rf ~/Library/Developer/Xcode/DerivedData/bitchat-* 2>/dev/null || true
    @rm -rf "{{ARCHIVE_PATH}}" "{{EXPORT_PATH}}" 2>/dev/null || true
    @echo "Clean complete"

nuke: clean
    @if [ -f SafeGuardian/LaunchScreen.storyboard.ios ]; then \
        mv SafeGuardian/LaunchScreen.storyboard.ios SafeGuardian/LaunchScreen.storyboard; fi
