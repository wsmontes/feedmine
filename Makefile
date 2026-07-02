# Feedmine — Zero-intervention build, install, launch

DEVICE_14PLUS := 00008110-00067D861486201E
DEVICE ?= 14plus
PROJECT := feedmine.xcodeproj
SCHEME  := feedmine

DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData/feedmine-bvjkmkogrbhjrgccbmqajrgfohtd
APP_PATH     := $(DERIVED_DATA)/Build/Products/Debug-iphoneos/feedmine.app

.PHONY: all build install launch clean

# ── Full Cycle ───────────────────────────────────────────
all: build install launch

# ── Build ────────────────────────────────────────────────
build:
	@echo "🔨 Building Feedmine..."
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE_14PLUS)" \
		-allowProvisioningUpdates \
		-configuration Debug build 2>&1 | tail -3

# ── Install ──────────────────────────────────────────────
install:
	@echo "📲 Installing..."
	xcrun devicectl device install app --device $(DEVICE_14PLUS) "$(APP_PATH)"

# ── Launch ───────────────────────────────────────────────
launch:
	@echo "🚀 Launching..."
	xcrun devicectl device process launch --device $(DEVICE_14PLUS) com.feedmine.app

# ── Clean ────────────────────────────────────────────────
clean:
	@echo "🧹 Cleaning..."
	rm -rf "$(DERIVED_DATA)"
	xcodebuild -project $(PROJECT) clean 2>/dev/null
