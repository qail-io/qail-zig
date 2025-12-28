//! QAIL Language Server
//!
//! Main LSP server implementation with JSON-RPC over stdio.
//! Port of qail.rs/qail-lsp

const std = @import("std");
const json = std.json;
const protocol = @import("protocol.zig");
const grammar = @import("qail").parser.grammar;

pub const QailServer = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) QailServer {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *QailServer) void {
        var iter = self.documents.valueIterator();
        while (iter.next()) |val| {
            self.allocator.free(val.*);
        }
        self.documents.deinit();
    }

    /// Main server loop - read JSON-RPC messages and respond
    pub fn run(self: *QailServer) !void {
        while (true) {
            const msg = try self.readMessage();
            defer self.allocator.free(msg);

            try self.handleMessage(msg);
        }
    }

    /// Read a JSON-RPC message from stdin (Content-Length header format)
    fn readMessage(self: *QailServer) ![]u8 {
        var content_length: usize = 0;

        // Read headers line by line
        var header_buf: [1024]u8 = undefined;
        var header_len: usize = 0;

        while (true) {
            var byte_buf: [1]u8 = undefined;
            const n = readStdin(&byte_buf) catch return error.ReadError;
            if (n == 0) return error.EndOfStream;

            const byte = byte_buf[0];

            if (byte == '\n') {
                const line = if (header_len > 0 and header_buf[header_len - 1] == '\r')
                    header_buf[0 .. header_len - 1]
                else
                    header_buf[0..header_len];

                if (line.len == 0) break;

                if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                    content_length = try std.fmt.parseInt(usize, line[16..], 10);
                }
                header_len = 0;
            } else {
                if (header_len < header_buf.len) {
                    header_buf[header_len] = byte;
                    header_len += 1;
                }
            }
        }

        // Read body
        const body = try self.allocator.alloc(u8, content_length);
        var total_read: usize = 0;
        while (total_read < content_length) {
            const n = readStdin(body[total_read..]) catch return error.ReadError;
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }
        return body;
    }

    /// Cross-platform stdin read helper
    fn readStdin(buf: []u8) !usize {
        const builtin = @import("builtin");
        if (builtin.os.tag == .windows) {
            // Windows: LSP not supported yet, return error
            return error.UnsupportedPlatform;
        } else {
            return std.posix.read(std.posix.STDIN_FILENO, buf);
        }
    }

    /// Handle incoming JSON-RPC message
    fn handleMessage(self: *QailServer, msg: []const u8) !void {
        const parsed = try json.parseFromSlice(json.Value, self.allocator, msg, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const method = obj.get("method") orelse return;
        const method_str = method.string;

        if (std.mem.eql(u8, method_str, "initialize")) {
            try self.handleInitialize(obj);
        } else if (std.mem.eql(u8, method_str, "initialized")) {
            // No response needed
        } else if (std.mem.eql(u8, method_str, "shutdown")) {
            try self.handleShutdown(obj);
        } else if (std.mem.eql(u8, method_str, "exit")) {
            return error.ServerExit;
        } else if (std.mem.eql(u8, method_str, "textDocument/didOpen")) {
            try self.handleDidOpen(obj);
        } else if (std.mem.eql(u8, method_str, "textDocument/didChange")) {
            try self.handleDidChange(obj);
        } else if (std.mem.eql(u8, method_str, "textDocument/hover")) {
            try self.handleHover(obj);
        } else if (std.mem.eql(u8, method_str, "textDocument/completion")) {
            try self.handleCompletion(obj);
        }
    }

    /// Handle initialize request
    fn handleInitialize(self: *QailServer, obj: json.ObjectMap) !void {
        const id = obj.get("id") orelse return;
        const id_val: i64 = if (id == .integer) id.integer else 0;

        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{\"textDocumentSync\":1,\"hoverProvider\":true,\"completionProvider\":{{\"triggerCharacters\":[\":\",\"[\",\"#\"]}}}}}}}}",
            .{id_val},
        );
        defer self.allocator.free(response);
        try self.sendRaw(response);
    }

    /// Handle shutdown request
    fn handleShutdown(self: *QailServer, obj: json.ObjectMap) !void {
        const id = obj.get("id") orelse return;
        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}",
            .{id.integer},
        );
        defer self.allocator.free(response);
        try self.sendRaw(response);
    }

    /// Handle textDocument/didOpen
    fn handleDidOpen(self: *QailServer, obj: json.ObjectMap) !void {
        const params = obj.get("params") orelse return;
        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri").?.string;
        const text = text_doc.object.get("text").?.string;

        // Store document
        const uri_copy = try self.allocator.dupe(u8, uri);
        const text_copy = try self.allocator.dupe(u8, text);
        try self.documents.put(uri_copy, text_copy);

        // Publish diagnostics
        const diagnostics = try self.getDiagnostics(text_copy);
        defer self.allocator.free(diagnostics);
        try self.publishDiagnostics(uri, diagnostics);
    }

    /// Handle textDocument/didChange
    fn handleDidChange(self: *QailServer, obj: json.ObjectMap) !void {
        const params = obj.get("params") orelse return;
        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri").?.string;
        const changes = params.object.get("contentChanges").?.array;

        if (changes.items.len > 0) {
            const text = changes.items[0].object.get("text").?.string;
            const text_copy = try self.allocator.dupe(u8, text);

            // Update stored document
            if (self.documents.getPtr(uri)) |old| {
                self.allocator.free(old.*);
                old.* = text_copy;
            }

            const diagnostics = try self.getDiagnostics(text_copy);
            defer self.allocator.free(diagnostics);
            try self.publishDiagnostics(uri, diagnostics);
        }
    }

    /// Handle textDocument/hover
    fn handleHover(self: *QailServer, obj: json.ObjectMap) !void {
        const id = obj.get("id") orelse return;
        const params = obj.get("params") orelse return;
        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri").?.string;
        const pos = params.object.get("position") orelse return;
        const line = @as(usize, @intCast(pos.object.get("line").?.integer));

        const doc = self.documents.get(uri) orelse {
            try self.sendNull(id);
            return;
        };

        // Extract QAIL at line
        var lines = std.mem.splitScalar(u8, doc, '\n');
        var current_line: usize = 0;
        while (lines.next()) |l| {
            if (current_line == line) {
                if (self.extractQail(l)) |qail| {
                    // Try to parse and show SQL
                    const result = grammar.parse(self.allocator, qail);
                    if (result) |cmd| {
                        _ = cmd;
                        const hover_text = try std.fmt.allocPrint(
                            self.allocator,
                            "**QAIL Query**\\n\\n```\\n{s}\\n```",
                            .{qail},
                        );
                        defer self.allocator.free(hover_text);
                        try self.sendHover(id, hover_text);
                        return;
                    } else |_| {
                        try self.sendHover(id, "Parse Error");
                        return;
                    }
                }
                break;
            }
            current_line += 1;
        }

        try self.sendNull(id);
    }

    /// Handle textDocument/completion
    fn handleCompletion(self: *QailServer, obj: json.ObjectMap) !void {
        const id = obj.get("id") orelse return;
        const id_val: i64 = if (id == .integer) id.integer else 0;

        // Static completions
        const completions = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
                "{{\"label\":\"get::\",\"kind\":14,\"detail\":\"SELECT query\",\"insertText\":\"get::${{1:table}} : ${{2:'_}}\",\"insertTextFormat\":2}}," ++
                "{{\"label\":\"set::\",\"kind\":14,\"detail\":\"UPDATE query\",\"insertText\":\"set::${{1:table}} [ ${{2:col}}=${{3:val}} ]\",\"insertTextFormat\":2}}," ++
                "{{\"label\":\"del::\",\"kind\":14,\"detail\":\"DELETE query\",\"insertText\":\"del::${{1:table}} [ ${{2:where}} ]\",\"insertTextFormat\":2}}," ++
                "{{\"label\":\"add::\",\"kind\":14,\"detail\":\"INSERT query\",\"insertText\":\"add::${{1:table}} : ${{2:cols}} [ ${{3:vals}} ]\",\"insertTextFormat\":2}}," ++
                "{{\"label\":\"#count\",\"kind\":3,\"detail\":\"COUNT aggregate\"}}," ++
                "{{\"label\":\"#sum\",\"kind\":3,\"detail\":\"SUM aggregate\"}}," ++
                "{{\"label\":\"#avg\",\"kind\":3,\"detail\":\"AVG aggregate\"}}" ++
                "]}}",
            .{id_val},
        );
        defer self.allocator.free(completions);
        try self.sendRaw(completions);
    }

    /// Get diagnostics for document text
    fn getDiagnostics(self: *QailServer, text: []const u8) ![]u8 {
        var diagnostics: std.ArrayList(u8) = .empty;
        errdefer diagnostics.deinit(self.allocator);
        try diagnostics.appendSlice(self.allocator, "[");

        const patterns = [_][]const u8{ "get::", "set::", "del::", "add::", "make::", "mod::" };

        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_num: u32 = 0;
        var first = true;

        while (lines.next()) |line| {
            for (patterns) |pattern| {
                if (std.mem.indexOf(u8, line, pattern)) |start| {
                    const query = line[start..];
                    const result = grammar.parse(self.allocator, query);
                    if (result) |_| {
                        // Valid parse
                    } else |_| {
                        if (!first) try diagnostics.appendSlice(self.allocator, ",");
                        first = false;

                        const diag = try std.fmt.allocPrint(
                            self.allocator,
                            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1,\"source\":\"qail-lsp\",\"message\":\"Parse error\"}}",
                            .{ line_num, start, line_num, start + query.len },
                        );
                        defer self.allocator.free(diag);
                        try diagnostics.appendSlice(self.allocator, diag);
                    }
                }
            }
            line_num += 1;
        }

        try diagnostics.appendSlice(self.allocator, "]");
        return try diagnostics.toOwnedSlice(self.allocator);
    }

    /// Publish diagnostics notification
    fn publishDiagnostics(self: *QailServer, uri: []const u8, diagnostics: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"{s}\",\"diagnostics\":{s}}}}}",
            .{ uri, diagnostics },
        );
        defer self.allocator.free(msg);
        try self.sendRaw(msg);
    }

    /// Extract QAIL query from line
    fn extractQail(_: *QailServer, line: []const u8) ?[]const u8 {
        const patterns = [_][]const u8{ "get::", "set::", "del::", "add::", "make::" };
        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, line, pattern)) |start| {
                return line[start..];
            }
        }
        return null;
    }

    /// Format JSON-RPC id
    fn formatId(_: *QailServer, id: json.Value) []const u8 {
        return switch (id) {
            .integer => |i| blk: {
                // For simplicity, return static strings for common IDs
                if (i == 0) break :blk "0";
                if (i == 1) break :blk "1";
                if (i == 2) break :blk "2";
                if (i == 3) break :blk "3";
                if (i == 4) break :blk "4";
                if (i == 5) break :blk "5";
                // Fallback for larger IDs
                break :blk "0";
            },
            .string => |s| s,
            else => "0",
        };
    }

    /// Send null result
    fn sendNull(self: *QailServer, id: json.Value) !void {
        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}",
            .{id.integer},
        );
        defer self.allocator.free(response);
        try self.sendRaw(response);
    }

    /// Send hover response
    fn sendHover(self: *QailServer, id: json.Value, content: []const u8) !void {
        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}}}}}",
            .{ id.integer, content },
        );
        defer self.allocator.free(response);
        try self.sendRaw(response);
    }

    /// Send raw JSON-RPC message
    fn sendRaw(_: *QailServer, content: []const u8) !void {
        const posix = std.posix;

        // Build header
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{content.len}) catch return error.FormatError;

        // Write header
        var written: usize = 0;
        while (written < header.len) {
            const n = posix.write(posix.STDOUT_FILENO, header[written..]) catch return error.WriteError;
            if (n == 0) return error.WriteError;
            written += n;
        }

        // Write content
        written = 0;
        while (written < content.len) {
            const n = posix.write(posix.STDOUT_FILENO, content[written..]) catch return error.WriteError;
            if (n == 0) return error.WriteError;
            written += n;
        }
    }
};

// ==================== Main Entry Point ====================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = QailServer.init(allocator);
    defer server.deinit();

    server.run() catch |err| {
        if (err == error.ServerExit) return;
        return err;
    };
}

// ==================== Tests ====================

test "extract qail patterns" {
    const allocator = std.testing.allocator;
    var server = QailServer.init(allocator);
    defer server.deinit();

    try std.testing.expect(server.extractQail("get::users : '_") != null);
    try std.testing.expect(server.extractQail("some random text") == null);
}
