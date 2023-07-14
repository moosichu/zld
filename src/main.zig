const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mem = std.mem;

const Allocator = mem.Allocator;
const Zld = @import("Zld.zig");

const gpa = std.heap.c_allocator;

const usage =
    \\zld is a generic linker driver.
    \\Call
    \\  ELF: ld.zld, ld
    \\  MachO: ld64.zld, ld64
    \\  COFF: link-dl
    \\  Wasm: wasm-zld
;

var log_scopes: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(gpa);

pub const std_options = struct {
    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // Hide debug messages unless:
        // * logging enabled with `-Dlog`.
        // * the --debug-log arg for the scope has been provided
        if (@intFromEnum(level) > @intFromEnum(std.options.log_level) or
            @intFromEnum(level) > @intFromEnum(std.log.Level.info))
        {
            if (!build_options.enable_logging) return;

            const scope_name = @tagName(scope);
            for (log_scopes.items) |log_scope| {
                if (mem.eql(u8, log_scope, scope_name)) break;
            } else return;
        }

        // We only recognize 4 log levels in this application.
        const level_txt = switch (level) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
        };
        const prefix1 = level_txt;
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

        // Print the message to stderr, silently ignoring any errors
        std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
    }
};

pub fn main() !void {
    const all_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, all_args);

    const cmd = std.fs.path.basename(all_args[0]);
    const tag: Zld.Tag = blk: {
        if (mem.eql(u8, cmd, "ld.zld") or mem.eql(u8, cmd, "ld")) {
            break :blk .elf;
        } else if (mem.eql(u8, cmd, "ld64.zld") or mem.eql(u8, cmd, "ld64")) {
            break :blk .macho;
        } else if (mem.eql(u8, cmd, "link-zld")) {
            break :blk .coff;
        } else if (mem.eql(u8, cmd, "wasm-zld")) {
            break :blk .wasm;
        } else {
            std.io.getStdOut().writeAll(usage) catch {};
            std.process.exit(0);
        }
    };
    return Zld.main(tag, .{
        .gpa = gpa,
        .cmd = cmd,
        .args = all_args[1..],
        .log_scopes = &log_scopes,
    });
}
