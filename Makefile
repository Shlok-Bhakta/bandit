# Bandit: `make help` lists everything. Dongle targets run in firmware/bandit
# (its own `make help` has more: log, status, cmd, ota-test, ...).
SHELL := /bin/bash
.DEFAULT_GOAL := help
DONGLE := $(MAKE) -C firmware/bandit
# Host-side Rust (band-core tests, dongle-pack): the dongle's config.mk may point elsewhere.
-include firmware/bandit/config.mk
HOST_TARGET ?= $(abspath firmware/dongle-pack/target)
CARGO_HOST := $(if $(CARGO_HOME),RUSTUP_HOME=$(RUSTUP_HOME) CARGO_HOME=$(CARGO_HOME) $(CARGO_HOME)/bin/cargo,cargo) +stable

.PHONY: help test test-swift test-rust app app-deliver project dongle-setup dongle-build dongle-flash \
        dongle-release dongle-serve dongle-log dongle-status dongle-cmd check clean

help:
	@echo "make test                  all host tests (Swift NeuralBandKit, Rust band-core and dongle-pack)"
	@echo "make app                   build the Bandit iOS app (with its Live Activities) for a device"
	@echo "make app-deliver           build it and push build/ipa/Bandit.ipa to Gala as bandit"
	@echo "make project               regenerate Bandit.xcodeproj from project.yml (XcodeGen)"
	@echo "make dongle-setup          once: the Rust ESP32 toolchain (espup, espflash, ldproxy)"
	@echo "make dongle-build          build the dongle firmware"
	@echo "make dongle-flash          build and flash it over USB [PORT=/dev/cu.usbmodem…]"
	@echo "make dongle-release NOTES= sign and publish an update for the app's update button"
	@echo "make dongle-serve          serve releases to your tailnet (once; launchd + tailscale serve)"
	@echo "make dongle-log | dongle-status | dongle-cmd C='mode slides'   talk to it over USB serial"
	@echo "make check                 scan what would be published for secrets and personal data"
	@echo "make clean                 remove host build products and published releases"

test: test-swift test-rust

test-swift:
	cd NeuralBandKit && swift test

test-rust:
	cd firmware/band-core && CARGO_TARGET_DIR=$(HOST_TARGET) $(CARGO_HOST) test -q
	cd firmware/bandit-profiles && CARGO_TARGET_DIR=$(HOST_TARGET) $(CARGO_HOST) test -q
	cd firmware/dongle-pack && CARGO_TARGET_DIR=$(HOST_TARGET) $(CARGO_HOST) build -q

project:
	xcodegen generate

app: project
	GALA_BUILD_DIR=$(CURDIR)/build GALA_ARTIFACT_DIR=$(CURDIR)/build/ipa ./ios-build.sh

app-deliver: app
	gala push build/ipa/Bandit.ipa --name bandit

dongle-setup:
	$(DONGLE) setup
dongle-build:
	$(DONGLE) build
dongle-flash:
	$(DONGLE) flash
dongle-release:
	$(DONGLE) release NOTES="$(NOTES)"
dongle-serve:
	$(DONGLE) serve
dongle-log:
	$(DONGLE) log
dongle-status:
	$(DONGLE) status
dongle-cmd:
	$(DONGLE) cmd C="$(C)"

check:
	tools/check-secrets.sh

clean:
	rm -rf build/ipa
	$(DONGLE) clean
