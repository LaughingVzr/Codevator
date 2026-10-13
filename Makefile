XCODEBUILD ?= $(if $(wildcard /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild),/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild,xcodebuild)
DERIVED_DATA ?= .build/CodevatorDerivedData
RELEASE_DIR ?= .build/release
RELEASE_APP = $(DERIVED_DATA)/Build/Products/Release/Codevator.app

XCODEBUILD_OPTIONS = -project Codevator.xcodeproj -derivedDataPath $(DERIVED_DATA) -skipPackagePluginValidation -disableAutomaticPackageResolution

.PHONY: build test test-ui release dmg clean

build:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator build

test:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator -only-testing:CodevatorTests test

test-ui:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator-UI test

release:
	$(XCODEBUILD) $(XCODEBUILD_OPTIONS) -scheme Codevator -configuration Release 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

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
