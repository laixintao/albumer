.DEFAULT_GOAL := run

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

DEV_APP := $(CURDIR)/build/DerivedData/Build/Products/Debug/Albumer.app

.PHONY: build run release-build release release-validate ci-package release-verify release-publish test test-release audit public
export VERSION RELEASE_TAG ARTIFACT_DIR

build:
	xcodebuild -quiet -project Albumer.xcodeproj -scheme Albumer -configuration Debug \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
	codesign --verify --strict "$(DEV_APP)"

run: build
	./scripts/open-dev-app.sh "$(DEV_APP)"

release-build:
	./scripts/build-app.sh

release:
	python3 scripts/release.py

release-validate:
	python3 scripts/distribution.py validate

ci-package: test-release test release-build
	python3 scripts/distribution.py package

release-verify:
	python3 scripts/distribution.py verify

release-publish:
	python3 scripts/distribution.py publish

test:
	./scripts/test.sh

test-release:
	python3 -m unittest discover -s Tests/ReleaseTests -v

audit:
	python3 scripts/audit-release.py

public:
	python3 scripts/prepare-public-repo.py
