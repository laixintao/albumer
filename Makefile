.DEFAULT_GOAL := run

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

DEV_APP := $(CURDIR)/build/DerivedData/Build/Products/Debug/Albumer.app

.PHONY: build run release test audit public

build:
	xcodebuild -quiet -project Albumer.xcodeproj -scheme Albumer -configuration Debug \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
	codesign --verify --strict "$(DEV_APP)"

run: build
	./scripts/open-dev-app.sh "$(DEV_APP)"

release:
	./scripts/build-app.sh

test:
	./scripts/test.sh

audit:
	python3 scripts/audit-release.py

public:
	python3 scripts/prepare-public-repo.py
