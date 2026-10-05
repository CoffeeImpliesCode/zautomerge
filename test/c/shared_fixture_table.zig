//! Emit a C table directly from the canonical manifest, only for ctest-shared.
const std = @import("std");
const manifest = @import("manifest");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.writeAll("static const struct { const char *name; bool load_ok; } shared_fixtures[] = {\n");
    for (manifest.fixtures) |fixture| {
        try out.writeAll("    { \"");
        // Fixed-width C octal escapes work for every filename byte, without
        // a source parser or a second inventory, including quotes/backslashes.
        for (fixture.name) |byte| try out.print("\\{o:0>3}", .{byte});
        try out.print("\", {s} }},\n", .{if (fixture.expect == .load_ok) "true" else "false"});
    }
    try out.writeAll("};\n");
    try out.flush();
}
