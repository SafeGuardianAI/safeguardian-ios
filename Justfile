# SafeGuardian macOS Build Justfile
# Handles temporary modifications needed to build and run on macOS

# Default recipe - shows available commands
default:
    @echo "SafeGuardian macOS Build Commands:"
    @echo "  just run     - Build and run the macOS app"
    @echo "  just build   - Build the macOS app only"
    @echo "  just clean   - Clean build artifacts and restore original files"
    @echo "  just check   - Check prerequisites"
    @echo ""
    @echo "Original files are preserved - modifications are temporary for builds only"

# Check prerequisites
check:
    @echo "Checking prerequisites..."
    @command -v xcodebuild >/dev/null 2>&1 || (echo "❌ xcodebuild not found. Install Xcode from App Store" && exit 1)
    @xcode-select -p | grep -q "Xcode.app" || (echo "❌ Full Xcode required, not just command line tools. Install from App Store and run:\n   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" && exit 1)
    @test -d "/Applications/Xcode.app" || (echo "❌ Xcode.app not found in Applications folder. Install from App Store" && exit 1)
    @xcodebuild -version >/dev/null 2>&1 || (echo "❌ Xcode not properly configured. Try:\n   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" && exit 1)
    @security find-identity -v -p codesigning | grep -q "Apple Development\|Developer ID" || (echo "⚠️  No Developer ID found - code signing may fail" && exit 0)
    @echo "✅ All prerequisites met"

# Backup original files
backup:
    @echo "Backing up original project configuration..."
    @if [ -f SafeGuardian.xcodeproj/project.pbxproj ]; then cp SafeGuardian.xcodeproj/project.pbxproj SafeGuardian.xcodeproj/project.pbxproj.backup; fi
    @if [ -f SafeGuardian/Info.plist ]; then cp SafeGuardian/Info.plist SafeGuardian/Info.plist.backup; fi

# Restore original files
restore:
    @echo "Restoring original project configuration..."
    @if [ -f project.yml.backup ]; then mv project.yml.backup project.yml; fi
    @# Restore iOS-specific files
    @if [ -f SafeGuardian/LaunchScreen.storyboard.ios ]; then mv SafeGuardian/LaunchScreen.storyboard.ios SafeGuardian/LaunchScreen.storyboard; fi
    @# Use git to restore all modified files except Justfile
    @git checkout -- project.yml SafeGuardian.xcodeproj/project.pbxproj SafeGuardian/Info.plist 2>/dev/null || echo "⚠️  Could not restore some files with git"
    @# Remove any backup files
    @rm -f SafeGuardian.xcodeproj/project.pbxproj.backup SafeGuardian/Info.plist.backup 2>/dev/null || true

# Apply macOS-specific modifications
patch-for-macos: backup
    @echo "Temporarily hiding iOS-specific files for macOS build..."
    @# Move iOS-specific files out of the way temporarily
    @if [ -f SafeGuardian/LaunchScreen.storyboard ]; then mv SafeGuardian/LaunchScreen.storyboard SafeGuardian/LaunchScreen.storyboard.ios; fi

# Build the macOS app
build: #check generate
    @echo "Building SafeGuardian for macOS..."
    @xcodebuild -project SafeGuardian.xcodeproj -scheme "SafeGuardian (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

# Run the macOS app
run: build
    @echo "Launching SafeGuardian..."
    @ls -td ~/Library/Developer/Xcode/DerivedData/SafeGuardian-*/Build/Products/Debug/SafeGuardian.app 2>/dev/null | head -1 | xargs open

# Clean build artifacts and restore original files
clean: restore
    @echo "Cleaning build artifacts..."
    @rm -rf ~/Library/Developer/Xcode/DerivedData/bitchat-* 2>/dev/null || true
    @# Only remove the generated project if we have a backup, otherwise use git
    @if [ -f SafeGuardian.xcodeproj/project.pbxproj.backup ]; then \
        rm -rf SafeGuardian.xcodeproj; \
    else \
        git checkout -- SafeGuardian.xcodeproj/project.pbxproj 2>/dev/null || echo "⚠️  Could not restore project.pbxproj"; \
    fi
    @rm -f project-macos.yml 2>/dev/null || true
    @echo "✅ Cleaned and restored original files"

# Quick run without cleaning (for development)
dev-run:
    @echo "Quick development build..."
    @xcodebuild -project SafeGuardian.xcodeproj -scheme "SafeGuardian (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    @ls -td ~/Library/Developer/Xcode/DerivedData/SafeGuardian-*/Build/Products/Debug/SafeGuardian.app 2>/dev/null | head -1 | xargs open

# Show app info
info:
    @echo "SafeGuardian - Decentralized Mesh Messaging"
    @echo "======================================"
    @echo "• Native macOS SwiftUI app"
    @echo "• Bluetooth LE mesh networking"
    @echo "• End-to-end encryption"
    @echo "• No internet required"
    @echo "• Works offline with nearby devices"
    @echo ""
    @echo "Requirements:"
    @echo "• macOS 13.0+ (Ventura)"
    @echo "• Bluetooth LE capable Mac"
    @echo "• Physical device (no simulator support)"
    @echo ""
    @echo "Usage:"
    @echo "• Set nickname and start chatting"
    @echo "• Use /join #channel for group chats"
    @echo "• Use /msg @user for private messages"
    @echo "• Triple-tap logo for emergency wipe"

# Force clean everything (nuclear option)
nuke:
    @echo "🧨 Nuclear clean - removing all build artifacts and backups..."
    @rm -rf ~/Library/Developer/Xcode/DerivedData/SafeGuardian-* 2>/dev/null || true
    @# Restore iOS-specific files if they were moved
    @if [ -f SafeGuardian/LaunchScreen.storyboard.ios ]; then mv SafeGuardian/LaunchScreen.storyboard.ios SafeGuardian/LaunchScreen.storyboard; fi
    @git checkout SafeGuardian.xcodeproj/project.pbxproj SafeGuardian/Info.plist 2>/dev/null || echo "⚠️  Not a git repo or no changes to restore"
    @echo "✅ Nuclear clean complete"
