# bandit: `make help` lists the targets. PORT defaults to a dongle plugged into this Mac.
SHELL := /bin/bash
.DEFAULT_GOAL := help

# Where the Rust ESP toolchain lives: espup's defaults, or your own in config.mk (git-ignored;
# see config.mk.example).
-include config.mk
RUSTUP_HOME ?= $(HOME)/.rustup
CARGO_HOME ?= $(HOME)/.cargo
EXPORT_ESP ?= $(HOME)/export-esp.sh
# Where the host-side packer (../dongle-pack) builds.
HOST_TARGET ?= $(abspath ../dongle-pack/target)
export RUSTUP_HOME CARGO_HOME EXPORT_ESP HOST_TARGET
export PATH := $(CARGO_HOME)/bin:$(PATH)
# macOS make looks commands up in its original PATH, so tools get absolute paths.
ESPFLASH := $(CARGO_HOME)/bin/espflash
# The Xtensa toolchain needs export-esp.sh in the same shell as cargo.
ESPENV := . $(EXPORT_ESP) &&

# Build on another machine (in config.mk: BUILD_HOST = crabcake), in ~/$(BUILD_DIR) there: git's
# files (committed or not) go over, the ELF and bootloader come back, so flash, release and
# addr2line work as before. Its toolchain: espup's, with export-esp.sh and a python3 that has
# venv in ~/$(BUILD_DIR) (README: "Building on another machine").
BUILD_HOST ?=
BUILD_DIR ?= bandit-build

PORT ?= /dev/cu.usbmodem1101
ELF := target/xtensa-esp32s3-espidf/release/bandit
ifdef BUILD_HOST
BOOTLOADER = $(wildcard target/remote/bootloader.bin)
else
BOOTLOADER = $(firstword $(wildcard target/xtensa-esp32s3-espidf/release/build/esp-idf-sys-*/out/build/bootloader/bootloader.bin))
endif
# ESP-IDF's Python environment has pyserial.
PY = $(firstword $(wildcard .embuild/espressif/python_env/*/bin/python))
PACKAGE = $(firstword $(wildcard ../dist/*.banditfw))
NOTES ?=
SECS ?= 30
C ?= status
WAIT ?= 25

# The dongle plugged into another machine (in config.mk: REMOTE = kiwi): it still builds here;
# flashing and the serial tools run there over ssh (`make remote-setup` puts them there, in
# ~/$(REMOTE_DIR)). Unset: the dongle is on this Mac's PORT.
REMOTE ?=
REMOTE_DIR ?= bandit
# With two boards plugged in there: which one (REMOTE_PORT=/dev/serial/by-id/usb-Espressif_…).
REMOTE_PORT ?=
RUN = $(if $(REMOTE_PORT),env BANDIT_PORT=$(REMOTE_PORT) )$(REMOTE_DIR)/run
ifdef REMOTE
# $(call tool,script.py,args): the script gets the dongle's port first, here or there.
tool = ssh $(REMOTE) $(RUN) $(1) $(2)
TOOLS_READY = remote-sync
else
tool = $(PY) -I tools/$(1) $(PORT) $(2)
TOOLS_READY =
endif

.PHONY: help setup remote-setup remote-sync build flash release serve serve-status log capture capture-cmd capture-stop crashes status cmd power connect-bench profiles-get profiles-put ota-test ota-tamper-test clean distclean

help:
	@echo "make setup                 install the Rust ESP toolchain (espup), espflash and ldproxy"
	@echo "make remote-setup          put espflash and the tools on REMOTE (config.mk), for a dongle plugged in there"
	@echo "make build                 build the firmware"
	@echo "make flash                 build and flash over USB (bootloader, two-slot layout, app in ota_0; owner key and pairings kept)"
	@echo "make release NOTES='...'   build, sign and publish to ../dist (Tailscale /dongle) for the app's update button"
	@echo "make serve                 serve ../dist to your tailnet at /dongle (launchd + tailscale serve); serve-status checks it"
	@echo "make log [SECS=30]         print the dongle's log"
	@echo "make capture               keep the port open on REMOTE and log everything to ~/bandit/logs (crash hunting; stop it before flash/log/cmd)"
	@echo "make capture-stop          stop it; make crashes [N=40] shows the crash log's tail"
	@echo "make capture-cmd C='...'   send a control command through the running capture (no reset)"
	@echo "make status [WAIT=25]      print the dongle's status JSON (after WAIT s: opening the port resets it)"
	@echo "make cmd C='key playpause' send a control command (CONTROL.md) over serial"
	@echo "make power PHASES='auto:60 motion:60'   measure the band's battery and radio per state (target/power/)"
	@echo "make connect-bench [ROUNDS=5] [MODE=reboot]   time how fast the band (re)connects (MODE=reboot: like plugging in)"
	@echo "make profiles-get [FILE=target/profiles.json]  the dongle's gesture profile set, into FILE"
	@echo "make profiles-put [FILE=target/profiles.json]  FILE onto the dongle (the phone app: Get the dongle's set)"
	@echo "make ota-test              push the published package over serial through the real update path"
	@echo "make ota-tamper-test       the same with a broken signature (must be refused)"
	@echo "make clean                 remove published releases (../dist)"
	@echo "make distclean             also remove the build (the next build recompiles ESP-IDF: slow)"

setup:
	cargo install espup espflash ldproxy --locked
	espup install --export-file $(EXPORT_ESP)

build:
ifdef BUILD_HOST
	@cd ../.. && git ls-files --cached --others --exclude-standard firmware/bandit firmware/band-core firmware/bandit-profiles \
	  | while read -r file; do [ -e "$$file" ] && echo "$$file"; done | rsync -a --files-from=- . $(BUILD_HOST):$(BUILD_DIR)/repo/
	ssh $(BUILD_HOST) 'export PATH=$$HOME/$(BUILD_DIR)/bin:$$HOME/.cargo/bin:$$PATH && . $$HOME/$(BUILD_DIR)/export-esp.sh && \
	  cd $(BUILD_DIR)/repo/firmware/bandit && cargo build --release && \
	  cp "$$(ls -t target/xtensa-esp32s3-espidf/release/build/esp-idf-sys-*/out/build/bootloader/bootloader.bin | head -n 1)" target/bootloader.bin'
	@mkdir -p $(dir $(ELF)) target/remote
	scp -q $(BUILD_HOST):$(BUILD_DIR)/repo/firmware/bandit/$(ELF) $(ELF)
	scp -q $(BUILD_HOST):$(BUILD_DIR)/repo/firmware/bandit/target/bootloader.bin target/remote/bootloader.bin
else
	@test -f $(EXPORT_ESP) || { echo "no $(EXPORT_ESP): run make setup, or set EXPORT_ESP in config.mk"; exit 1; }
	$(ESPENV) cargo build --release
endif

flash: build $(TOOLS_READY)
	@test -n "$(BOOTLOADER)" || { echo "no bootloader built yet"; exit 1; }
ifdef REMOTE
	scp -q $(BOOTLOADER) $(REMOTE):$(REMOTE_DIR)/flash/bootloader.bin
	scp -q partitions.csv $(ELF) $(REMOTE):$(REMOTE_DIR)/flash/
	ssh $(REMOTE) $(RUN) flash
else
	$(ESPFLASH) flash --port $(PORT) --chip esp32s3 --flash-size 8mb --flash-freq 80mhz \
	  --bootloader $(BOOTLOADER) --partition-table partitions.csv \
	  --target-app-partition ota_0 --erase-parts otadata $(ELF)
endif

# espflash for the other machine: the Linux build of the same version as here.
ESPFLASH_VERSION = $(word 2,$(shell $(ESPFLASH) --version 2>/dev/null))
remote-setup:
	@test -n "$(REMOTE)" || { echo "set REMOTE (in config.mk, like REMOTE = kiwi)"; exit 1; }
	ssh $(REMOTE) 'set -e; mkdir -p $(REMOTE_DIR)/bin $(REMOTE_DIR)/tools $(REMOTE_DIR)/flash $(REMOTE_DIR)/files; \
	  python3 -c "import serial" || { echo "needs pyserial: sudo apt install python3-serial"; exit 1; }; \
	  cd /tmp && curl -fsSL -o espflash.zip https://github.com/esp-rs/espflash/releases/download/v$(ESPFLASH_VERSION)/espflash-$$(uname -m)-unknown-linux-gnu.zip && \
	  python3 -c "import zipfile; zipfile.ZipFile(\"espflash.zip\").extractall(\"espflash-x\")" && \
	  install -m 755 espflash-x/espflash ~/$(REMOTE_DIR)/bin/espflash && rm -rf espflash.zip espflash-x'
	$(MAKE) remote-sync
	@ssh $(REMOTE) '$(REMOTE_DIR)/bin/espflash --version; ls /dev/serial/by-id/usb-Espressif* 2>/dev/null || echo "(no dongle plugged in right now)"'
	@echo "Once: ssh -t $(REMOTE) sudo sh $(REMOTE_DIR)/setup-access.sh   (lets you open the dongle's port)"

remote-sync:
	@rsync -q -t tools/*.py $(REMOTE):$(REMOTE_DIR)/tools/
	@rsync -q -t -p tools/remote/run tools/remote/setup-access.sh $(REMOTE):$(REMOTE_DIR)/

release: $(if $(BUILD_HOST),build)
	$(if $(BUILD_HOST),BOOTLOADER=$(BOOTLOADER)) ./release.sh "$(NOTES)"

serve:
	tools/serve-releases.sh install

serve-status:
	tools/serve-releases.sh status

log: $(TOOLS_READY)
	$(call tool,serial_console.py,$(SECS))

# Opening the port resets the dongle, so a capture opens it once and holds it: a reset it logs is the dongle's own.
capture:
	@test -n "$(REMOTE)" || { echo "capture runs on REMOTE (config.mk)"; exit 1; }
	@$(MAKE) -s remote-sync
	@ssh $(REMOTE) 'pgrep -f "tools/[l]og_capture.py" >/dev/null && echo "already capturing" || { setsid nohup $(RUN) log_capture.py >/dev/null 2>&1 < /dev/null & sleep 1; echo "capturing to ~/$(REMOTE_DIR)/logs"; }'

# A serial command (CONTROL.md) through the running capture, which keeps the port (and the dongle) up.
capture-cmd:
	@ssh $(REMOTE) "printf '%s\n' '$(C)' >> ~/$(REMOTE_DIR)/logs/send"

capture-stop:
	@ssh $(REMOTE) 'pkill -f "tools/[l]og_capture.py" && echo stopped || echo "not capturing"'

N ?= 40
crashes:
	@ssh $(REMOTE) 'tail -n $(N) ~/$(REMOTE_DIR)/logs/crashes.log'

# Opening the port resets the dongle: watch the hosts reconnect, then ask.
status: $(TOOLS_READY)
	$(call tool,serial_console.py,2 wait=$(WAIT) status)

cmd: $(TOOLS_READY)
	$(call tool,serial_console.py,3 wait=$(WAIT) $(if $(REMOTE),"'$(C)'","$(C)"))

PHASES ?= auto:60 motion:60 writing:60
POWER_DIR ?= target/power/$(shell date +%Y%m%d-%H%M)
power:
	@test -z "$(REMOTE)" || { echo "power writes its results here: run it with the dongle on this Mac (REMOTE=)"; exit 1; }
	$(PY) -I tools/power_watch.py $(PORT) $(POWER_DIR) $(PHASES)

ROUNDS ?= 5
MODE ?=
connect-bench: $(TOOLS_READY)
	$(call tool,connect_bench.py,$(ROUNDS) $(MODE))

FILE ?= target/profiles.json
profiles-get: $(TOOLS_READY)
ifdef REMOTE
	$(call tool,profiles_tool.py,get files/profiles.json)
	scp -q $(REMOTE):$(REMOTE_DIR)/files/profiles.json $(FILE)
else
	$(call tool,profiles_tool.py,get $(FILE))
endif

profiles-put: $(TOOLS_READY)
ifdef REMOTE
	scp -q $(FILE) $(REMOTE):$(REMOTE_DIR)/files/profiles.json
	$(call tool,profiles_tool.py,put files/profiles.json)
else
	$(call tool,profiles_tool.py,put $(FILE))
endif

ota-test: $(TOOLS_READY)
	@test -n "$(PACKAGE)" || { echo "nothing published: make release first"; exit 1; }
	@test -z "$(REMOTE)" || scp -q $(PACKAGE) $(REMOTE):$(REMOTE_DIR)/files/update.banditfw
	$(call tool,serial_ota.py,$(if $(REMOTE),files/update.banditfw,$(PACKAGE)) ok 85)

ota-tamper-test: $(TOOLS_READY)
	@test -n "$(PACKAGE)" || { echo "nothing published: make release first"; exit 1; }
	@test -z "$(REMOTE)" || scp -q $(PACKAGE) $(REMOTE):$(REMOTE_DIR)/files/update.banditfw
	$(call tool,serial_ota.py,$(if $(REMOTE),files/update.banditfw,$(PACKAGE)) tamper 5)

clean:
	find ../dist -maxdepth 1 -type f \( -name '*.banditfw' -o -name '*-flasher.html' -o -name latest.json \) -delete

distclean: clean
	$(ESPENV) cargo clean
