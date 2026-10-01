const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. `@import("frostlake")` in a consumer resolves to src/frostlake.zig.
    const frostlake = b.addModule("frostlake", .{
        .root_source_file = b.path("src/frostlake.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests: the `test` blocks inside the library itself plus the offline suites in
    // tests/. Neither needs an engine, a JVM or a network.
    const unit_tests = b.addTest(.{ .root_module = frostlake });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const offline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/offline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "frostlake", .module = frostlake }},
        }),
    });
    const run_offline_tests = b.addRunArtifact(offline_tests);

    const test_step = b.step("test", "Run the unit tests (no engine needed)");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_offline_tests.step);

    // Integration tests: these talk to a running engine and skip themselves when
    // FROSTLAKE_URL names none. `zig build test-integration` runs them.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "frostlake", .module = frostlake }},
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    // An integration run must not be answered from the cache: the engine it talks to can
    // change without a single source file changing.
    run_integration_tests.has_side_effects = true;

    // The engine's testkit corpus, replayed through the driver against the same engine. It runs
    // only when FL_CORPUS names the frostlake repo's testkit directory, and skips otherwise.
    // `zig build test-suites` runs it alone, and the integration run includes it.
    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suites.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "frostlake", .module = frostlake }},
        }),
    });
    const run_suite_tests = b.addRunArtifact(suite_tests);
    run_suite_tests.has_side_effects = true;

    const suites_step = b.step("test-suites", "Run the engine's JSON testkit suites through this driver");
    suites_step.dependOn(&run_suite_tests.step);

    const integration_step = b.step("test-integration", "Run the integration tests and the testkit corpus against a running engine");
    integration_step.dependOn(&run_integration_tests.step);
    integration_step.dependOn(&run_suite_tests.step);

    // Everything at once.
    const all_step = b.step("test-all", "Run unit, integration and testkit suites");
    all_step.dependOn(test_step);
    all_step.dependOn(integration_step);

    // A worked example, built and runnable with `zig build example`.
    const example = b.addExecutable(.{
        .name = "frostlake-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "frostlake", .module = frostlake }},
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_example.addArgs(args);
    const example_step = b.step("example", "Build and run the example against a running engine");
    example_step.dependOn(&run_example.step);
}
