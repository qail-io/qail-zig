//! Fair qail-zig vs pg.zig benchmark on the shared feature surface.
//!
//! qail-zig workloads are authored as native QailCmd ASTs, compiled once to SQL
//! for statement preparation, and then executed through the low-level prepared
//! protocol path. pg.zig executes the same prepared SQL templates through its
//! cached prepared-query path.
//!
//! Usage:
//!   zig build pgzig-bench -- qail single --workload point --plain
//!   zig build pgzig-bench -- pgzig pool10 --workload wide_rows

const std = @import("std");
const qail = @import("qail");
const bench = @import("qail_pgzig_bench/workloads.zig");
const bench_runner = @import("qail_pgzig_bench/runner.zig");

const process_compat = qail.compat.process;
const Mode = bench.Mode;
const Runner = bench.Runner;
const Workload = bench.Workload;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const args = try process_compat.argsAlloc(allocator);

    var runner: ?Runner = null;
    var mode: ?Mode = null;
    var workload: Workload = .point;
    var plain = false;
    var expect_workload = false;

    for (args[1..]) |arg| {
        if (expect_workload) {
            workload = Workload.parse(arg) orelse usageAndExit("unknown workload");
            expect_workload = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--workload")) {
            expect_workload = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
            continue;
        }
        if (runner == null) {
            runner = Runner.parse(arg);
            if (runner == null) usageAndExit("unknown runner");
            continue;
        }
        if (mode == null) {
            mode = Mode.parse(arg);
            if (mode == null) usageAndExit("unknown mode");
            continue;
        }
        usageAndExit("unexpected argument");
    }
    if (expect_workload) usageAndExit("missing workload value");

    const selected_runner = runner orelse usageAndExit("missing runner");
    const selected_mode = mode orelse usageAndExit("missing mode");
    const db = try bench_runner.loadDbConfig(allocator);
    try bench_runner.ensureBenchmarkData(allocator, db);

    const result = switch (workload) {
        .point => try bench_runner.runWorkload1(selected_runner, selected_mode, allocator, db, bench.pointSpec(), bench.buildPointParams),
        .wide_rows => try bench_runner.runWorkload1(selected_runner, selected_mode, allocator, db, bench.wideRowsSpec(), bench.buildWideRowsParams),
        .large_rows => try bench_runner.runWorkload1(selected_runner, selected_mode, allocator, db, bench.largeRowsSpec(), bench.buildLargeRowsParams),
        .many_params => try bench_runner.runWorkloadN(bench.MANY_PARAMS_COUNT, selected_runner, selected_mode, allocator, db, bench.manyParamsSpec(), bench.buildManyParamsBatch),
        .aggregate => try bench_runner.runWorkloadN(2, selected_runner, selected_mode, allocator, db, bench.aggregateSpec(), bench.buildAggregateParams),
    };

    if (plain) {
        try stdout.print("{d:.3}\n", .{result.qps});
        return;
    }

    try stdout.print("{s} {s}/{s}: {d:.0} q/s", .{
        @tagName(selected_runner),
        @tagName(selected_mode),
        @tagName(workload),
        result.qps,
    });
    if (result.rows_per_sec) |rows_per_sec| {
        try stdout.print(" | {d:.0} rows/s", .{rows_per_sec});
    }
    if (result.mib_per_sec) |mib_per_sec| {
        try stdout.print(" | {d:.2} MiB/s", .{mib_per_sec});
    }
    try stdout.print(" | checksum=0x{x}\n", .{result.checksum});
}

fn usageAndExit(reason: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{reason});
    std.debug.print(
        "Usage: qail_pgzig_bench <qail|pgzig> <single|pool10> [--workload point|wide_rows|large_rows|many_params|aggregate] [--plain]\n",
        .{},
    );
    std.process.exit(1);
}
