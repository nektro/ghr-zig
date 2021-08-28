const std = @import("std");
const zfetch = @import("zfetch");
const json = @import("json");
const string = []const u8;

const Config = struct {
    token: string,
    user: string,
    repo: string,
    commit: string,
    title: string,
    body: string,
    tag: string,
    path: string,
    draft: bool,
    prerelease: bool,
};

pub fn main() !void {
    //
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();
    const alloc = &arena.allocator;

    //
    var config: Config = .{
        .token = "",
        .user = "",
        .repo = "",
        .commit = "",
        .title = "",
        .body = "",
        .tag = "",
        .path = "",
        .draft = true,
        .prerelease = false,
    };

    //
    var envmap = try std.process.getEnvMap(alloc);
    defer envmap.deinit();
    if (envmap.get("GITHUB_TOKEN")) |env| config.token = env;

    //
    var argiter = std.process.args();
    defer argiter.deinit();
    var argi: usize = 0;
    while (argiter.next(alloc)) |item| : (argi += 1) {
        if (argi == 0) continue;
        const data = try item;

        // zig fmt: off
        if (std.mem.eql(u8, data, "-t")) { config.token = try argiter.next(alloc).?;    continue; }
        if (std.mem.eql(u8, data, "-u")) { config.user = try argiter.next(alloc).?; continue; }
        if (std.mem.eql(u8, data, "-r")) { config.repo = try argiter.next(alloc).?;     continue; }
        if (std.mem.eql(u8, data, "-c")) { config.commit = try argiter.next(alloc).?;   continue; }
        if (std.mem.eql(u8, data, "-n")) { config.title = try argiter.next(alloc).?;    continue; }
        if (std.mem.eql(u8, data, "-b")) { config.body = try argiter.next(alloc).?;     continue; }
        if (std.mem.eql(u8, data, "-draft")) { config.draft = true; continue; }
        if (std.mem.eql(u8, data, "-prerelease")) { config.prerelease = true; continue; }
        // zig fmt: on

        config.tag = data;
        config.path = try argiter.next(alloc).?;
        break;
    }

    //
    std.debug.assert(config.token.len > 0);
    std.debug.assert(config.user.len > 0);
    std.debug.assert(config.repo.len > 0);
    std.debug.assert(config.tag.len > 0);
    std.debug.assert(config.path.len > 0);

    //
    if (config.title.len == 0) config.title = config.tag;
    if (config.commit.len == 0) config.commit = try rev_HEAD(alloc);

    // https://docs.github.com/en/rest/reference/repos#create-a-release
    // https://docs.github.com/en/rest/reference/repos#get-a-release
    // https://docs.github.com/en/rest/reference/repos#update-a-release
    // https://docs.github.com/en/rest/reference/repos#delete-a-release

    // https://docs.github.com/en/rest/reference/repos#upload-a-release-asset
    // https://docs.github.com/en/rest/reference/repos#get-a-release-asset
    // https://docs.github.com/en/rest/reference/repos#update-a-release-asset
    // https://docs.github.com/en/rest/reference/repos#delete-a-release-asset

    //
    const url = try std.fmt.allocPrint(alloc, "https://api.github.com/repos/{s}/{s}/releases", .{ config.user, config.repo });
    var req = try fetchJson(alloc, config.token, .POST, url, .{
        .tag_name = config.tag,
        .target_commitish = config.commit,
        .name = config.title,
        .body = config.body,
        .draft = config.draft,
        .prerelease = config.prerelease,
    });
    defer req.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("info: creating release: {s} @ {s}:{s}\n", .{ config.title, config.tag, config.commit });
    try stdout.print("debug: status: {d} {s}\n", .{ req.status.code, req.status.reason });
    std.testing.expectEqual(@as(u16, 201), req.status.code) catch std.os.exit(1);

    const reader = req.reader();
    const body_content = try reader.readAllAlloc(alloc, std.math.maxInt(usize));
    const val = try json.parse(alloc, body_content);
    const upload_url = val.get("upload_url").?.String;

    const dir = try std.fs.cwd().openDir(config.path, .{ .iterate = true });
    var iter = dir.iterate();
    while (try iter.next()) |item| {
        if (item.kind != .File) continue;
        try stdout.print("--> Uploading: {s}\n", .{item.name});
        const path = try std.fs.path.join(alloc, &.{ config.path, item.name });

        const file = try std.fs.cwd().openFile(path, .{});
        const contents = try file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(contents);

        var upreq = try fetchRaw(alloc, config.token, .POST, upload_url, contents);
        defer upreq.deinit();
        std.testing.expectEqual(@as(u16, 201), upreq.status.code) catch {};
    }
}

/// Returns the result of running `git rev-parse HEAD`
pub fn rev_HEAD(alloc: *std.mem.Allocator) !string {
    const max = std.math.maxInt(usize);
    const dirg = try std.fs.cwd().openDir(".git", .{});
    const h = std.mem.trim(u8, try dirg.readFileAlloc(alloc, "HEAD", max), "\n");
    const r = std.mem.trim(u8, try dirg.readFileAlloc(alloc, h[5..], max), "\n");
    return r;
}

fn fetchJson(allocator: *std.mem.Allocator, token: string, method: zfetch.Method, url: string, body: anytype) !*zfetch.Request {
    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();
    try headers.appendValue("Accept", "application/vnd.github.v3+json");
    try headers.appendValue("Authorization", try std.mem.join(allocator, " ", &.{ "token", token }));
    try headers.appendValue("Content-Type", "application/json");

    var req = try zfetch.Request.init(allocator, url, null);
    try req.do(method, headers, try stringifyAlloc(allocator, .{}, body));
    return req;
}

fn fetchRaw(allocator: *std.mem.Allocator, token: string, method: zfetch.Method, url: string, body: []const u8) !*zfetch.Request {
    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();
    try headers.appendValue("Accept", "application/vnd.github.v3+json");
    try headers.appendValue("Authorization", try std.mem.join(allocator, " ", &.{ "token", token }));

    var req = try zfetch.Request.init(allocator, url, null);
    try req.do(method, headers, body);
    return req;
}

// Same as `stringify` but accepts an Allocator and stores result in dynamically allocated memory instead of using a Writer.
// Caller owns returned memory.
pub fn stringifyAlloc(allocator: *std.mem.Allocator, options: std.json.StringifyOptions, value: anytype) !string {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try std.json.stringify(value, options, list.writer());
    return list.toOwnedSlice();
}
