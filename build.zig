const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    defer makeZlsNotInstallAnythingDuringBuildOnSave(b);

    // CLI options
    const target = b.standardTargetOptions(.{
        .default_target = defaultTargetDetectM3() orelse .{},
    });
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "filter", "List of filters, used for example to filter unit tests by name"); // specified as a series like `-Dfilter="filter1" -Dfilter="filter2"`
    const enable_tsan = b.option(bool, "enable-tsan", "Enable TSan for the test suite");
    const no_run = b.option(bool, "no-run", "Do not run the selected step and install it") orelse false;
    const blockstore_db = b.option(BlockstoreDB, "blockstore", "Blockstore database backend") orelse .rocksdb;

    // Build options
    const build_options = b.addOptions();
    build_options.addOption(BlockstoreDB, "blockstore_db", blockstore_db);

    // CLI build steps
    const sig_step = b.step("run", "Run the sig executable");
    const test_step = b.step("test", "Run library tests");
    const fuzz_step = b.step("fuzz", "Gossip fuzz testing");
    const benchmark_step = b.step("benchmark", "Benchmark client");
    const geyser_reader_step = b.step("geyser_reader", "Read data from geyser");

    // Dependencies
    const dep_opts = .{ .target = target, .optimize = optimize };

    const base58_dep = b.dependency("base58-zig", dep_opts);
    const base58_module = base58_dep.module("base58-zig");

    const zig_network_dep = b.dependency("zig-network", dep_opts);
    const zig_network_module = zig_network_dep.module("network");

    const zig_cli_dep = b.dependency("zig-cli", dep_opts);
    const zig_cli_module = zig_cli_dep.module("zig-cli");

    const httpz_dep = b.dependency("httpz", dep_opts);
    const httpz_mod = httpz_dep.module("httpz");

    const zstd_dep = b.dependency("zstd", dep_opts);
    const zstd_mod = zstd_dep.module("zstd");

    const curl_dep = b.dependency("curl", dep_opts);
    const curl_mod = curl_dep.module("curl");

    const rocksdb_dep = b.dependency("rocksdb", dep_opts);
    const rocksdb_mod = rocksdb_dep.module("rocksdb-bindings");

    const lsquic_dep = b.dependency("lsquic", dep_opts);
    const lsquic_mod = lsquic_dep.module("lsquic");

    const ssl_dep = lsquic_dep.builder.dependency("boringssl", dep_opts);
    const ssl_mod = ssl_dep.module("ssl");

    const xev_dep = b.dependency("xev", dep_opts);
    const xev_mod = xev_dep.module("xev");

    const pretty_table_dep = b.dependency("prettytable", dep_opts);
    const pretty_table_mod = pretty_table_dep.module("prettytable");

    // expose Sig as a module
    const sig_mod = b.addModule("sig", .{
        .root_source_file = b.path("src/sig.zig"),
    });
    sig_mod.addImport("zig-network", zig_network_module);
    sig_mod.addImport("base58-zig", base58_module);
    sig_mod.addImport("zig-cli", zig_cli_module);
    sig_mod.addImport("httpz", httpz_mod);
    sig_mod.addImport("zstd", zstd_mod);
    sig_mod.addImport("curl", curl_mod);
    switch (blockstore_db) {
        .rocksdb => sig_mod.addImport("rocksdb", rocksdb_mod),
        .hashmap => {},
    }
    sig_mod.addOptions("build-options", build_options);

    // main executable
    const sig_exe = b.addExecutable(.{
        .name = "sig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = enable_tsan,
    });

    // make sure pyroscope's got enough info to profile
    sig_exe.build_id = .fast;
    sig_exe.root_module.omit_frame_pointer = false;
    sig_exe.root_module.strip = false;

    b.installArtifact(sig_exe);
    sig_exe.root_module.addImport("base58-zig", base58_module);
    sig_exe.root_module.addImport("curl", curl_mod);
    sig_exe.root_module.addImport("httpz", httpz_mod);
    sig_exe.root_module.addImport("zig-cli", zig_cli_module);
    sig_exe.root_module.addImport("zig-network", zig_network_module);
    sig_exe.root_module.addImport("zstd", zstd_mod);
    sig_exe.root_module.addImport("lsquic", lsquic_mod);
    sig_exe.root_module.addImport("ssl", ssl_mod);
    sig_exe.root_module.addImport("xev", xev_mod);
    switch (blockstore_db) {
        .rocksdb => sig_exe.root_module.addImport("rocksdb", rocksdb_mod),
        .hashmap => {},
    }
    sig_exe.root_module.addOptions("build-options", build_options);
    sig_exe.linkLibC();

    const main_exe_run = b.addRunArtifact(sig_exe);
    main_exe_run.addArgs(b.args orelse &.{});
    if (!no_run) sig_step.dependOn(&main_exe_run.step);
    if (no_run) sig_step.dependOn(&b.addInstallArtifact(sig_exe, .{}).step);

    // docs for the Sig library
    const sig_obj = b.addObject(.{
        .name = "sig",
        .root_source_file = b.path("src/sig.zig"),
        .target = target,
        .optimize = .Debug,
    });

    const docs_step = b.step("docs", "Generate and install documentation for the Sig Library");
    const install_sig_docs = b.addInstallDirectory(.{
        .source_dir = sig_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_sig_docs.step);

    // unit tests
    const unit_tests_exe = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = filters orelse &.{},
        .sanitize_thread = enable_tsan,
    });
    b.installArtifact(unit_tests_exe);
    unit_tests_exe.root_module.addImport("base58-zig", base58_module);
    unit_tests_exe.root_module.addImport("curl", curl_mod);
    unit_tests_exe.root_module.addImport("httpz", httpz_mod);
    unit_tests_exe.root_module.addImport("zig-network", zig_network_module);
    unit_tests_exe.root_module.addImport("zstd", zstd_mod);
    switch (blockstore_db) {
        .rocksdb => unit_tests_exe.root_module.addImport("rocksdb", rocksdb_mod),
        .hashmap => {},
    }
    unit_tests_exe.root_module.addOptions("build-options", build_options);
    unit_tests_exe.linkLibC();

    const unit_tests_exe_run = b.addRunArtifact(unit_tests_exe);
    if (!no_run) test_step.dependOn(&unit_tests_exe_run.step);
    if (no_run) test_step.dependOn(&b.addInstallArtifact(unit_tests_exe, .{}).step);

    // fuzz test
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = enable_tsan,
    });
    b.installArtifact(fuzz_exe);
    fuzz_exe.root_module.addImport("base58-zig", base58_module);
    fuzz_exe.root_module.addImport("zig-network", zig_network_module);
    fuzz_exe.root_module.addImport("httpz", httpz_mod);
    fuzz_exe.root_module.addImport("zstd", zstd_mod);
    fuzz_exe.linkLibC();

    const fuzz_exe_run = b.addRunArtifact(fuzz_exe);
    fuzz_exe_run.addArgs(b.args orelse &.{});
    if (!no_run) fuzz_step.dependOn(&fuzz_exe_run.step);
    if (no_run) fuzz_step.dependOn(&b.addInstallArtifact(fuzz_exe, .{}).step);

    // benchmarks
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmarks.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = enable_tsan,
    });
    b.installArtifact(benchmark_exe);
    benchmark_exe.root_module.addImport("base58-zig", base58_module);
    benchmark_exe.root_module.addImport("zig-network", zig_network_module);
    benchmark_exe.root_module.addImport("httpz", httpz_mod);
    benchmark_exe.root_module.addImport("zstd", zstd_mod);
    benchmark_exe.root_module.addImport("curl", curl_mod);
    benchmark_exe.root_module.addImport("prettytable", pretty_table_mod);
    switch (blockstore_db) {
        .rocksdb => benchmark_exe.root_module.addImport("rocksdb", rocksdb_mod),
        .hashmap => {},
    }
    benchmark_exe.root_module.addOptions("build-options", build_options);
    benchmark_exe.linkLibC();

    const benchmark_exe_run = b.addRunArtifact(benchmark_exe);
    benchmark_exe_run.addArgs(b.args orelse &.{});
    if (!no_run) benchmark_step.dependOn(&benchmark_exe_run.step);
    if (no_run) benchmark_step.dependOn(&b.addInstallArtifact(benchmark_exe, .{}).step);

    // geyser reader
    const geyser_reader_exe = b.addExecutable(.{
        .name = "geyser",
        .root_source_file = b.path("src/geyser/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = enable_tsan,
    });
    b.installArtifact(geyser_reader_exe);
    geyser_reader_exe.root_module.addImport("sig", sig_mod);
    geyser_reader_exe.root_module.addImport("zig-cli", zig_cli_module);

    const geyser_reader_exe_run = b.addRunArtifact(geyser_reader_exe);
    geyser_reader_exe_run.addArgs(b.args orelse &.{});
    if (!no_run) geyser_reader_step.dependOn(&geyser_reader_exe_run.step);
    if (no_run) geyser_reader_step.dependOn(&b.addInstallArtifact(geyser_reader_exe, .{}).step);
}

const BlockstoreDB = enum {
    rocksdb,
    hashmap,
};

/// Reference/inspiration: https://kristoff.it/blog/improving-your-zls-experience/
fn makeZlsNotInstallAnythingDuringBuildOnSave(b: *Build) void {
    const zls_is_build_runner = b.option(bool, "zls-is-build-runner", "" ++
        "Option passed by zls to indicate that it's the one running this build script (configured in the local zls.json). " ++
        "This should not be specified on the command line nor as a dependency argument.") orelse false;
    if (!zls_is_build_runner) return;

    for (b.install_tls.step.dependencies.items) |*install_step_dep| {
        const install_artifact = install_step_dep.*.cast(Build.Step.InstallArtifact) orelse continue;
        const artifact = install_artifact.artifact;
        install_step_dep.* = &artifact.step;
        // this will make it so `-fno-emit-bin` is passed, meaning
        // that the compiler will only go as far as semantically
        // analyzing the code, without sending it to any backend,
        // namely the slow-to-compile LLVM.
        artifact.generated_bin = null;
    }
}

/// TODO: remove after updating to 0.14, where M3/M4 feature detection is fixed.
/// Ref: https://github.com/ziglang/zig/pull/21116
fn defaultTargetDetectM3() ?std.Target.Query {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return null;
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => {},
        else => return null,
    }
    var cpu_family: std.c.CPUFAMILY = undefined;
    var len: usize = @sizeOf(std.c.CPUFAMILY);
    std.posix.sysctlbynameZ("hw.cpufamily", &cpu_family, &len, null, 0) catch unreachable;

    // Detects M4 as M3 to get around missing C flag translations when passing the target to dependencies.
    // https://github.com/Homebrew/brew/blob/64edbe6b7905c47b113c1af9cb1a2009ed57a5c7/Library/Homebrew/extend/os/mac/hardware/cpu.rb#L106
    const model: *const std.Target.Cpu.Model = switch (@intFromEnum(cpu_family)) {
        else => return null,
        0x2876f5b5 => &std.Target.aarch64.cpu.apple_a17, // ARM_COLL
        0xfa33415e => &std.Target.aarch64.cpu.apple_m3, // ARM_IBIZA
        0x5f4dea93 => &std.Target.aarch64.cpu.apple_m3, // ARM_LOBOS
        0x72015832 => &std.Target.aarch64.cpu.apple_m3, // ARM_PALMA
        0x6f5129ac => &std.Target.aarch64.cpu.apple_m3, // ARM_DONAN (M4)
        0x17d5b93a => &std.Target.aarch64.cpu.apple_m3, // ARM_BRAVA (M4)
    };

    return .{
        .cpu_arch = builtin.cpu.arch,
        .cpu_model = .{ .explicit = model },
    };
}
