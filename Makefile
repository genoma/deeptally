# SPDX-License-Identifier: GPL-3.0-or-later
# DeepTally build orchestration. macOS 15+, arm64 only, no Xcode required.
SHELL := /bin/bash

VERSION ?= 0.1.0
APP := dist/DeepTally.app
SWIFT_BUILD := swift build -c release --arch arm64

.PHONY: help build test lint bundle run verify clean

help:
	@echo "make build   - release build (app + CLI, arm64)"
	@echo "make test    - swift test"
	@echo "make lint    - swift format lint"
	@echo "make bundle  - assemble dist/DeepTally.app and ad-hoc sign it"
	@echo "make run     - bundle and launch the app"
	@echo "make verify  - build + test + lint + bundle + signature check"
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

verify: build test lint bundle
	codesign --verify --strict $(APP)
	@echo "verify: ok"

clean:
	rm -rf .build dist
