SHELL := /bin/bash
TOOLCHAIN_ZIG ?= ./toolchain/zig/zig

.PHONY: all build iso run clean clean-artifacts toolchain-zig

all: build

# Fetch official Zig 0.12 toolchain locally (Linux x86_64)
toolchain-zig:
	mkdir -p ./toolchain
	@[ -x "$(TOOLCHAIN_ZIG)" ] || ( \
	  echo "[barfrod] Downloading Zig 0.12 toolchain..." && \
	  curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz && \
	  tar -xJf /tmp/zig.tar.xz -C ./toolchain && \
	  rm -f /tmp/zig.tar.xz && \
	  dir_name="$$(basename "$$(find ./toolchain -maxdepth 1 -type d -name 'zig-linux-*' | head -n1)")" && \
	  ln -sfn "./$$dir_name" ./toolchain/zig && \
	  echo "[barfrod] Zig placed at ./toolchain/zig/zig (symlink -> ./toolchain/$$dir_name/zig)" )

build: toolchain-zig
	$(TOOLCHAIN_ZIG) build

iso: toolchain-zig
	$(TOOLCHAIN_ZIG) build iso

run: toolchain-zig
	$(TOOLCHAIN_ZIG) build run

clean:
	bash scripts/clean.sh

clean-artifacts: toolchain-zig
	$(TOOLCHAIN_ZIG) build clean-artifacts