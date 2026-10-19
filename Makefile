XCODEBUILD ?= $(if $(wildcard /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild),/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild,xcodebuild)
DERIVED_DATA ?= .build/CodevatorDerivedData
RELEASE_DIR ?= .build/release
RELEASE_APP = $(DERIVED_DATA)/Build/Products/Release/Codevator.app
DEBUG_APP = $(DERIVED_DATA)/Build/Products/Debug/Codevator.app
APP_PATH ?= $(DEBUG_APP)

XCODEBUILD_OPTIONS = -project Codevator.xcodeproj -derivedDataPath $(DERIVED_DATA) -skipPackagePluginValidation -disableAutomaticPackageResolution

.PHONY: build test test-ui release dmg clean verify-signature

build:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator build
	@$(MAKE) verify-signature APP_PATH='$(DEBUG_APP)'

test:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator -only-testing:CodevatorTests test

test-ui:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator-UI test

release:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator -configuration Release 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
	@$(MAKE) verify-signature APP_PATH='$(RELEASE_APP)'

verify-signature:
	@set -eu; \
	bundle_id=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$(APP_PATH)/Contents/Info.plist'); \
	signed_id=$$(/usr/bin/codesign -dv --verbose=2 '$(APP_PATH)' 2>&1 | /usr/bin/sed -n 's/^Identifier=//p'); \
	if [ "$$bundle_id" != "$$signed_id" ]; then \
		echo "App signature identifier '$$signed_id' does not match bundle identifier '$$bundle_id'" >&2; \
		exit 1; \
	fi; \
	/usr/bin/codesign --verify --strict '$(APP_PATH)'

dmg: release
	@set -eu; \
	mkdir -p '$(RELEASE_DIR)'; \
	version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '$(RELEASE_APP)/Contents/Info.plist'); \
	stage=$$(mktemp -d '$(RELEASE_DIR)/dmg-root.XXXXXX'); \
	trap 'rm -rf "$$stage"' EXIT; \
	ditto '$(RELEASE_APP)' "$$stage/Codevator.app"; \
	ln -s /Applications "$$stage/Applications"; \
	hdiutil create -srcfolder "$$stage" -volname "Codevator $$version" -format UDZO -ov '$(RELEASE_DIR)/Codevator-'"$$version"'-macOS.dmg'

clean:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator clean
