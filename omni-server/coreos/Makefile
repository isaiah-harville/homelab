# Build the Omni host's Ignition config and an auto-installing ISO.
#   make ign     render build/omni.ign (needs sops and the age identity)
#   make iso     build/omni-install.iso: boots, installs to INSTALL_DEVICE
#                keeping omni-data, and reboots into the new install
#
# build/ holds decrypted secrets. Delete it, and the ISO, when done.

SHELL := /bin/bash
OUT ?= build
HOST_ENV ?= host.env
INSTALLER_IMAGE ?= quay.io/coreos/coreos-installer:release
STREAM ?= stable
ARCH ?= x86_64
INSTALL_DEVICE = $(shell sed -nE 's/^INSTALL_DEVICE=(.*)/\1/p' $(HOST_ENV))

.PHONY: ign iso

ign:
	OUT=$(OUT) HOST_ENV=$(HOST_ENV) ./render.sh

$(OUT)/fedora-coreos-live.$(ARCH).iso:
	mkdir -p $(OUT)
	docker run --rm -v "$(CURDIR)/$(OUT):/data" -w /data $(INSTALLER_IMAGE) \
	  download -s $(STREAM) -a $(ARCH) -p metal -f iso
	mv $(OUT)/fedora-coreos-*-live-iso.$(ARCH).iso $@

iso: ign $(OUT)/fedora-coreos-live.$(ARCH).iso
	if [[ -f $(OUT)/omni-install.iso ]]; then mv -f $(OUT)/omni-install.iso $(OUT)/omni-install.iso.old; fi
	docker run --rm -v "$(CURDIR):/data" -w /data $(INSTALLER_IMAGE) \
	  iso customize --force --dest-device $(INSTALL_DEVICE) \
	  --dest-ignition $(OUT)/omni.ign --installer-config installer.yaml \
	  -o $(OUT)/omni-install.iso $(OUT)/fedora-coreos-live.$(ARCH).iso
	@echo "wrote $(OUT)/omni-install.iso: contains secrets, and WIPES $(INSTALL_DEVICE) (except omni-data) on boot"
