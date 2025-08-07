SHELL := /bin/bash

.PHONY: all build iso run clean clean-artifacts

all: build

build:
	zig build -Drelease-safe -Dstrip=false

iso:
	zig build iso

run:
	zig build run

clean:
	bash scripts/clean.sh

clean-artifacts:
	zig build clean-artifacts