# SPDX-License-Identifier: GPL-2.0-or-later
LOCAL_GOOSE := $(CURDIR)/.goose-toolchain/goose
GOOSE ?= $(if $(wildcard $(LOCAL_GOOSE)),$(LOCAL_GOOSE),goose)
BUILD_DIR ?= build
GOOSE_HOME ?= $(BUILD_DIR)/goose-home
TARGET := $(BUILD_DIR)/gdtc
SOURCE := src/gdtc.goose

export GOOSE_HOME

.PHONY: all build check oracle test clean

all: build

build:
	mkdir -p $(BUILD_DIR)
	$(GOOSE) build -o $(TARGET) $(SOURCE)

check:
	$(GOOSE) check $(SOURCE)

oracle:
	tests/oracle.sh

test:
	GOOSE=$(GOOSE) tests/run.sh

clean:
	rm -rf -- "$(CURDIR)/build"
