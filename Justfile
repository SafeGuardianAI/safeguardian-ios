# SafeGuardian macOS Build Justfile

# RAM guardrails applied to every xcodebuild invocation:
#   -jobs 4           cap parallel Swift compiler instances
#   COMPILER_INDEX_STORE_ENABLE=NO  skip index (not needed outside Xcode IDE)
# These are additive to the Debug.xcconfig settings (singlefile + no index store).
BUILD_FLAGS := "-jobs 4 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO"
SCHEME_MACOS := "SafeGuardian (macOS)"
SCHEME_IOS   := "SafeGuardian (iOS)"

default:
    @echo "SafeGuardian macOS Build Commands:"
    @echo "  just build   - Build the macOS app"
    @echo "  just run     - Build and launch"
    @echo "  just clean   - Clean build artifacts"
    @echo "  just check   - Check prerequisites"

check:
    @echo "Checking prerequisites..."
    @command -v xcodebuild >/dev/null 2>&1 || (echo "xcodebuild not found — install Xcode" && exit 1)
    @xcode-select -p | grep -q "Xcode.app" || (echo "Full Xcode required — sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" && exit 1)
    @echo "Prerequisites met"

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
        DEVELOPMENT_TEAM=V9KH637N7P \
        -allowProvisioningUpdates \
        -jobs 4 \
        COMPILER_INDEX_STORE_ENABLE=NO \
        build

clean:
    @echo "Cleaning build artifacts..."
    @rm -rf ~/Library/Developer/Xcode/DerivedData/SafeGuardian-* 2>/dev/null || true
    @rm -rf ~/Library/Developer/Xcode/DerivedData/bitchat-* 2>/dev/null || true
    @echo "Clean complete"

nuke: clean
    @if [ -f SafeGuardian/LaunchScreen.storyboard.ios ]; then \
        mv SafeGuardian/LaunchScreen.storyboard.ios SafeGuardian/LaunchScreen.storyboard; fi
