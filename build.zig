const std = @import("std");

// Snap-provided Zig uses std.build API where Compile step has methods:
//  - addObject / addExecutable with root_source_file LazyPath
//  - setLinkerScript (not setLinkerScriptPath)
//  - entry via .entry = .{ .symbol_name = "_start" } or kernel.setOutputDir in older
// This variant avoids newer helpers that are unavailable on your Zig.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        },
    });
    // Force ReleaseFast to avoid sanitizer/UBSAN pulls and reduce heavy std usage in freestanding
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const kernel = b.addExecutable(.{
        .name = "barfrod",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .strip = true,
    });

    // Harden for freestanding kernel on this Zig: avoid reflection; use known APIs.
    // Disable sanitizers/stack protector where available; ignore if not supported by this toolchain.
    // Note: addBuildOption is not a sanitizer toggle; remove it to avoid build API misuse.
    // Some fields may not exist; we purposely avoid @hasField to satisfy this Zig toolchain.
    // If these fields exist, uncomment and adjust:
    // kernel.sanitize_thread = false;
    // kernel.sanitize_address = false;
    // kernel.sanitize_c = false;
    // kernel.stack_protector = .none;
    // NOTE: Avoid custom module wiring; keep @import("paging.zig") in sources.

    // Set entry symbol via .entry (supported on snap Zig)
    kernel.entry = .{ .symbol_name = "_start" };

    // Provide custom linker script using setLinkerScript (Path)
    kernel.setLinkerScript(b.path("linker.ld"));

    // No libc (call takes no args in your Zig; do NOT link libc)
    // We simply avoid calling linkLibC() to keep libc disabled by default.
    // If present from template, remove any call to linkLibC.

    // Install kernel ELF
    const install_kernel = b.addInstallArtifact(kernel, .{});
    b.getInstallStep().dependOn(&install_kernel.step);

    // Add raw backend flags to avoid compiler-rt and stack protector emission on this toolchain
    // On this Zig (snap), prefer root_module.addCSourceFlags/AddArgs equivalents are not exposed.
    // Use environment variables to set compiler flags
    const set_env_cmd = b.addSystemCommand(&.{ "bash", "-c",
        \\export ZIG_GLOBAL_ARGS='-fno-emit-stack-protector -fno-emit-compiler-rt -mcmodel=kernel -mno-red-zone'
        \\export CFLAGS='-mcmodel=kernel -mno-red-zone'
        \\export LDFLAGS='-z max-page-size=4096'
    });
    
    // Rebuild kernel with the correct environment
    const rebuild_cmd = b.addSystemCommand(&.{ "bash", "-c",
        \\export ZIG_GLOBAL_ARGS='-fno-emit-stack-protector -fno-emit-compiler-rt -mcmodel=kernel -mno-red-zone'
        \\export CFLAGS='-mcmodel=kernel -mno-red-zone'
        \\export LDFLAGS='-z max-page-size=4096'
        \\zig build
    });
    
    set_env_cmd.step.dependOn(&install_kernel.step);
    rebuild_cmd.step.dependOn(&set_env_cmd.step);

    // ISO creation
    const iso_step = b.step("iso", "Build a bootable ISO image with GRUB");
    const iso_cmd = b.addSystemCommand(&.{
        "bash", "scripts/make_iso.sh",
    });
    iso_cmd.step.dependOn(&install_kernel.step);
    iso_step.dependOn(&iso_cmd.step);

    // Run in QEMU
    const run_step = b.step("run", "Run kernel in QEMU (uses ISO and GRUB)");
    const run_cmd = b.addSystemCommand(&.{
        "bash", "scripts/run_qemu.sh",
    });
    run_cmd.step.dependOn(&iso_cmd.step);
    run_step.dependOn(&run_cmd.step);

    // Clean artifacts helper
    const clean_step = b.step("clean-artifacts", "Clean build artifacts (zig-out, iso)");
    const clean_cmd = b.addSystemCommand(&.{
        "bash", "scripts/clean.sh",
    });
    clean_step.dependOn(&clean_cmd.step);
}