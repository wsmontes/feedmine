# Feedmine — Zero-intervention build, install, launch, test

DEVICE_14PLUS := 00008110-00067D861486201E
DEVICE_15    := 00008120-000260903ED1A01E
DEVICE       ?= $(DEVICE_14PLUS)
SIM_NAME     := iPhone 14 Plus
PROJECT      := feedmine.xcodeproj
SCHEME       := feedmine

DERIVED_DATA   := .build-device
SIM_DERIVED    := .build-dd
APP_PATH       := $(DERIVED_DATA)/Build/Products/Debug-iphoneos/feedmine.app

.PHONY: all build install launch \
        test-device test-device-only test-ui \
        test-sim test-sim-only test-ui-sim \
        device-info sim-info clean clean-all

# ── Device Info ──────────────────────────────────────────
device-info:
	@echo "📱 Connected devices:"
	@xcrun devicectl list devices 2>&1 | head -20
	@echo ""
	@echo "🎯 Target DEVICE: $(DEVICE)"

sim-info:
	@echo "📱 Simulators:"
	@xcrun simctl list devices | grep "$(SIM_NAME)"

# ── Full Cycle ───────────────────────────────────────────
all: build install launch

# ── Build (Device) ───────────────────────────────────────
build:
	@echo "🔨 Building Feedmine for device..."
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Debug 2>&1 | tail -5

# ── Install ──────────────────────────────────────────────
install:
	@echo "📲 Installing to device..."
	xcrun devicectl device install app --device $(DEVICE) "$(APP_PATH)"

# ── Launch ───────────────────────────────────────────────
launch:
	@echo "🚀 Launching..."
	xcrun devicectl device process launch --device $(DEVICE) com.feedmine.app

# ── Test: Device ─────────────────────────────────────────
test-device:
	@echo "🧪 [Device] Unit tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Debug \
		-only-testing:feedmineTests 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)" || true

test-device-only:
	@echo "🧪 [Device] Unit tests (no rebuild)..."
	xcodebuild test-without-building -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:feedmineTests 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)" || true

test-ui:
	@echo "🧪 [Device] UI tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE)" \
		-allowProvisioningUpdates \
		-derivedDataPath $(DERIVED_DATA) \
		-configuration Debug \
		-only-testing:feedmineUITests 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)" || true

# ── Test: Simulator ──────────────────────────────────────
test-sim:
	@echo "🧪 [Simulator] Unit tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath $(SIM_DERIVED) \
		-configuration Debug \
		-only-testing:feedmineTests 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing|error:)" || true

test-sim-only:
	@echo "🧪 [Simulator] Unit tests (no rebuild)..."
	xcodebuild test-without-building -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath $(SIM_DERIVED) \
		-only-testing:feedmineTests 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)" || true

test-ui-sim:
	@echo "🧪 [Simulator] UI tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath $(SIM_DERIVED) \
		-configuration Debug \
		-only-testing:feedmineUITests 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|Executed|Failing)" || true

# ── Disk / Clean ─────────────────────────────────────────
clean:
	@echo "🧹 Cleaning derived data..."
	rm -rf "$(DERIVED_DATA)" "$(SIM_DERIVED)"
	xcodebuild -project $(PROJECT) clean 2>/dev/null

clean-all: clean
	@echo "🧹 Deep cleaning..."
	rm -rf build .build-* ~/Library/Developer/Xcode/DerivedData/feedmine-*
	@df -h / | tail -1 | awk '{print "   Disk: " $$4 " free (" $$5 " used)"}'
