.DEFAULT_GOAL := run

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

DEV_APP := $(CURDIR)/build/DerivedData/Build/Products/Debug/Albumer.app

.PHONY: build run

build:
	xcodebuild -quiet -project Albumer.xcodeproj -scheme Albumer -configuration Debug \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
	codesign --verify --strict "$(DEV_APP)"

run: build
	./scripts/open-dev-app.sh "$(DEV_APP)"
