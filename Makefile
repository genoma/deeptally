# SPDX-License-Identifier: GPL-3.0-or-later
# DeepTally build orchestration. macOS 15+, arm64 only, no Xcode required.
SHELL := /bin/bash

# The dev default for a local `make bundle`/`make dmg`; every release passes VERSION explicitly.
VERSION ?= 0.1.2
APP := dist/DeepTally.app
SWIFT_BUILD := swift build -c release --arch arm64

.PHONY: help build test lint bundle run dmg kill smoke screenshots verify install uninstall release-assets release-check clean

help:
	@echo "make build   - release build (app + CLI, arm64)"
	@echo "make test    - swift test"
	@echo "make lint    - swift format lint"
	@echo "make bundle  - assemble dist/DeepTally.app and ad-hoc sign it"
	@echo "make dmg     - build dist/DeepTally-<version>.dmg (add SIMULATE=1 to set quarantine)"
	@echo "make kill    - stop a running DeepTally instance"
	@echo "make smoke   - launch the bundled app and check it stays alive"
	@echo "make screenshots - render the real popover to dist/popover[-dark].png"
	@echo "make run     - bundle and launch the app"
	@echo "make verify  - build + test + lint + bundle + signature check"
	@echo "make install - install the app via Scripts/install.sh (ARGS=--user, --dir DIR, --dmg PATH)"
	@echo "make uninstall - remove it via Scripts/uninstall.sh (ARGS=--print-only, --keep-data)"
	@echo "make release-assets - build the release files into dist/ (VERSION=x.y.z)"
	@echo "make release-check  - verify + release-assets + SHA256SUMS check (VERSION=x.y.z)"
	@echo "make clean   - remove .build and dist"

build:
	$(SWIFT_BUILD)

test:
	swift test

lint:
	swift format lint --recursive Sources Tests

bundle:
	VERSION=$(VERSION) ./Scripts/bundle.sh

run: bundle
	open $(APP)

dmg: bundle
	VERSION=$(VERSION) ./Scripts/dmg.sh $(if $(filter 1,$(SIMULATE)),--simulate-download,)

# The app is an accessory (LSUIElement): no Dock icon, no ⌘Q. Use the popover's Quit button,
# or this target / pkill during development.
kill:
	@pkill -f 'DeepTally.app/Contents/MacOS/DeepTally' && echo "killed a running DeepTally" || echo "DeepTally is not running"

# Launches the built app and fails if it does not survive four seconds. Deliberately launched without
# a key: a missing key must never stop the app from starting.
smoke: bundle
	@pkill -f 'DeepTally.app/Contents/MacOS/DeepTally' 2>/dev/null || true
	@open $(APP)
	@sleep 4
	@pgrep -f 'DeepTally.app/Contents/MacOS/DeepTally' >/dev/null && echo "smoke: app alive after 4s" || { echo "smoke: FAILED - app did not stay running"; exit 1; }
	@pkill -f 'DeepTally.app/Contents/MacOS/DeepTally' 2>/dev/null || true

# Renders the shipping popover with live data to dist/popover.png and dist/popover-dark.png.
# Needs a key (Keychain or DEEPSEEK_API_KEY); used for docs screenshots and the visual half of the gate.
screenshots: bundle
	dist/DeepTally.app/Contents/MacOS/DeepTally --spike render-popover dist/popover

verify: build test lint bundle
	codesign --verify --strict $(APP)
	@echo "verify: ok"

# Install or uninstall the app. Both delegate to the shipped scripts so there is one implementation:
# install.sh verifies a DMG's SHA-256 and installs it; uninstall.sh drives the app's own removal list.
# ARGS passes through: 'make install ARGS=--user', 'make uninstall ARGS=--print-only'.
install:
	./Scripts/install.sh $(ARGS)

uninstall:
	./Scripts/uninstall.sh $(ARGS)

# Everything .github/workflows/release.yml uploads: DMG, CLI tarball, install.sh, formula, SHA256SUMS.
release-assets:
	VERSION=$(VERSION) ./Scripts/release-assets.sh

# The release gate: verify first, then build and self-check the published files.
release-check: verify
	VERSION=$(VERSION) ./Scripts/release-assets.sh
	cd dist && shasum -a 256 -c SHA256SUMS

clean:
	rm -rf .build dist
