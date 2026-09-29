const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `zautomerge` is a library. Consumers get the module; no artifact is
    // installed. Executables and the C ABI live in the test and example
    // targets below until the port grows a command-line tool.
    const mod = b.addModule("zautomerge", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // The fixture corpus lives in test/fixtures and the test reads it through
    // a path relative to the build root, which is the process working
    // directory for a build-run step.
    const fixtures_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_fixtures_tests = b.addRunArtifact(fixtures_tests);
    run_fixtures_tests.setCwd(b.path("."));
    test_step.dependOn(&run_fixtures_tests.step);

    // `zig build conformance -- <args>` drives the Rust oracle in tools/oracle
    // against the reference automerge implementation. The oracle is a
    // development tool: it is not reachable from the default step, so
    // `zig build` and `zig build test` need neither cargo nor the reference
    // checkout.
    const link_oracle = b.addSystemCommand(&.{"sh"});
    link_oracle.addFileArg(b.path("tools/link-oracle.sh"));
    link_oracle.setName("link automerge reference");

    const oracle = b.addSystemCommand(&.{"cargo"});
    oracle.addArgs(&.{ "run", "--quiet", "--manifest-path" });
    oracle.addFileArg(b.path("tools/oracle/Cargo.toml"));
    oracle.addArg("--");
    // Everything after `--` on the `zig build` line is the subcommand and its
    // arguments, handed straight through.
    if (b.args) |args| oracle.addArgs(args);
    // The reference checkout is not a declared build input, so this step
    // always runs and leaves caching to cargo.
    oracle.has_side_effects = true;
    oracle.step.dependOn(&link_oracle.step);
    oracle.setName("run automerge oracle");

    const conformance_step = b.step("conformance", "Run the automerge reference oracle");
    conformance_step.dependOn(&oracle.step);
}
