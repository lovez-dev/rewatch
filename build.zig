const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "rewatch", .root_module = app });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run rewatch").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = app });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("test", "Run unit and filesystem tests");
    test_step.dependOn(&run_unit.step);

    const runner = b.createModule(.{
        .root_source_file = b.path("src/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const helper = b.addExecutable(.{
        .name = "reload-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/process.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runner", .module = runner }},
        }),
    });
    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "runner", .module = runner }},
    });
    const integration = b.addExecutable(.{ .name = "integration", .root_module = integration_module });
    const run_integration = b.addRunArtifact(integration);
    run_integration.addArtifactArg(exe);
    run_integration.addArtifactArg(helper);
    test_step.dependOn(&run_integration.step);
    const proxy_test = b.addSystemCommand(&.{ b.option([]const u8, "python", "Python executable for HTTP proxy integration tests") orelse "python", "tests/proxy_integration.py" });
    proxy_test.addArtifactArg(exe);
    b.step("test-proxy", "Run HTTP proxy integration tests (requires Python 3)").dependOn(&proxy_test.step);
    const compile_tests = b.step("test-compile", "Compile tests without running (for cross compilation)");
    compile_tests.dependOn(&unit.step);
    compile_tests.dependOn(&helper.step);
    compile_tests.dependOn(&integration.step);

    const check = b.step("check", "Compile without installing");
    check.dependOn(&exe.step);
}
