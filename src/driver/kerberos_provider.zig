const std = @import("std");
const builtin = @import("builtin");
const auth_options = @import("auth_options.zig");
const kerberos_preflight = @import("kerberos_preflight.zig");
const io_compat = @import("../runtime/io.zig");
const process_compat = @import("../runtime/process.zig");

pub const LinuxKrb5ProviderConfig = kerberos_preflight.LinuxKrb5ProviderConfig;

pub const LinuxKrb5Provider = if (builtin.os.tag == .linux) struct {
    pub const OmUint32 = u32;

    pub const GssOidDesc = extern struct {
        length: OmUint32,
        elements: ?*anyopaque,
    };

    pub const GssBufferDesc = extern struct {
        length: usize,
        value: ?*anyopaque,
    };

    pub const GssOid = ?*GssOidDesc;
    pub const GssName = ?*anyopaque;
    pub const GssContext = ?*anyopaque;
    pub const GssCredential = ?*anyopaque;
    pub const GssChannelBindings = ?*anyopaque;

    pub const GSS_S_COMPLETE: OmUint32 = 0;
    pub const GSS_S_CONTINUE_NEEDED: OmUint32 = 1;
    pub const GSS_C_GSS_CODE: i32 = 1;
    pub const GSS_C_MECH_CODE: i32 = 2;
    pub const GSS_C_MUTUAL_FLAG: OmUint32 = 0x0000_0002;
    pub const GSS_C_SEQUENCE_FLAG: OmUint32 = 0x0000_0008;
    pub const GSS_C_CONF_FLAG: OmUint32 = 0x0000_0010;
    const GSS_SESSION_TTL_MS: i64 = 120_000;
    const GSS_MAX_SESSIONS: usize = 256;
    // RFC 2743 / MIT Kerberos host-based service name type:
    // 1.2.840.113554.1.2.1.4
    const fallback_hostbased_service_oid_bytes = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x04 };
    var fallback_hostbased_service_oid_desc = GssOidDesc{
        .length = fallback_hostbased_service_oid_bytes.len,
        .elements = @ptrCast(@constCast(fallback_hostbased_service_oid_bytes[0..].ptr)),
    };

    pub const Api = struct {
        lib: std.DynLib,
        hostbased_service_name: GssOid,
        gss_import_name: *const fn (
            minor_status: *OmUint32,
            input_name_buffer: *const GssBufferDesc,
            input_name_type: GssOid,
            output_name: *GssName,
        ) callconv(.c) OmUint32,
        gss_release_name: *const fn (
            minor_status: *OmUint32,
            input_name: *GssName,
        ) callconv(.c) OmUint32,
        gss_init_sec_context: *const fn (
            minor_status: *OmUint32,
            initiator_cred_handle: GssCredential,
            context_handle: *GssContext,
            target_name: GssName,
            mech_type: GssOid,
            req_flags: OmUint32,
            time_req: OmUint32,
            input_chan_bindings: GssChannelBindings,
            input_token: ?*const GssBufferDesc,
            actual_mech_type: ?*GssOid,
            output_token: *GssBufferDesc,
            ret_flags: ?*OmUint32,
            time_rec: ?*OmUint32,
        ) callconv(.c) OmUint32,
        gss_delete_sec_context: *const fn (
            minor_status: *OmUint32,
            context_handle: *GssContext,
            output_token: ?*GssBufferDesc,
        ) callconv(.c) OmUint32,
        gss_release_buffer: *const fn (
            minor_status: *OmUint32,
            buffer: *GssBufferDesc,
        ) callconv(.c) OmUint32,
        gss_display_status: *const fn (
            minor_status: *OmUint32,
            status_value: OmUint32,
            status_type: i32,
            mech_type: GssOid,
            message_context: *OmUint32,
            status_string: *GssBufferDesc,
        ) callconv(.c) OmUint32,
        gss_wrap: *const fn (
            minor_status: *OmUint32,
            context_handle: GssContext,
            conf_req_flag: i32,
            qop_req: OmUint32,
            input_message_buffer: *const GssBufferDesc,
            conf_state: *i32,
            output_message_buffer: *GssBufferDesc,
        ) callconv(.c) OmUint32,
        gss_unwrap: *const fn (
            minor_status: *OmUint32,
            context_handle: GssContext,
            input_message_buffer: *const GssBufferDesc,
            output_message_buffer: *GssBufferDesc,
            conf_state: *i32,
            qop_state: *OmUint32,
        ) callconv(.c) OmUint32,

        pub fn load() !Api {
            const debug = gssDebugEnabled();

            for (linuxGssApiCandidates()) |candidate| {
                var lib = std.DynLib.open(candidate) catch |err| {
                    if (debug) std.log.warn("gssapi: failed to open candidate {s}: {}", .{ candidate, err });
                    continue;
                };
                errdefer lib.close();

                if (debug) std.log.warn("gssapi: opened candidate {s}", .{candidate});

                const hostbased_service_name = resolveHostbasedServiceName(&lib, candidate, debug) orelse continue;
                const gss_import_name = lookupRequired(*const fn (*OmUint32, *const GssBufferDesc, GssOid, *GssName) callconv(.c) OmUint32, &lib, candidate, "gss_import_name", debug) orelse continue;
                const gss_release_name = lookupRequired(*const fn (*OmUint32, *GssName) callconv(.c) OmUint32, &lib, candidate, "gss_release_name", debug) orelse continue;
                const gss_init_sec_context = lookupRequired(*const fn (*OmUint32, GssCredential, *GssContext, GssName, GssOid, OmUint32, OmUint32, GssChannelBindings, ?*const GssBufferDesc, ?*GssOid, *GssBufferDesc, ?*OmUint32, ?*OmUint32) callconv(.c) OmUint32, &lib, candidate, "gss_init_sec_context", debug) orelse continue;
                const gss_delete_sec_context = lookupRequired(*const fn (*OmUint32, *GssContext, ?*GssBufferDesc) callconv(.c) OmUint32, &lib, candidate, "gss_delete_sec_context", debug) orelse continue;
                const gss_release_buffer = lookupRequired(*const fn (*OmUint32, *GssBufferDesc) callconv(.c) OmUint32, &lib, candidate, "gss_release_buffer", debug) orelse continue;
                const gss_display_status = lookupRequired(*const fn (*OmUint32, OmUint32, i32, GssOid, *OmUint32, *GssBufferDesc) callconv(.c) OmUint32, &lib, candidate, "gss_display_status", debug) orelse continue;
                const gss_wrap = lookupRequired(*const fn (*OmUint32, GssContext, i32, OmUint32, *const GssBufferDesc, *i32, *GssBufferDesc) callconv(.c) OmUint32, &lib, candidate, "gss_wrap", debug) orelse continue;
                const gss_unwrap = lookupRequired(*const fn (*OmUint32, GssContext, *const GssBufferDesc, *GssBufferDesc, *i32, *OmUint32) callconv(.c) OmUint32, &lib, candidate, "gss_unwrap", debug) orelse continue;

                if (debug) std.log.warn("gssapi: candidate {s} satisfied all required symbols", .{candidate});

                return .{
                    .lib = lib,
                    .hostbased_service_name = hostbased_service_name,
                    .gss_import_name = gss_import_name,
                    .gss_release_name = gss_release_name,
                    .gss_init_sec_context = gss_init_sec_context,
                    .gss_delete_sec_context = gss_delete_sec_context,
                    .gss_release_buffer = gss_release_buffer,
                    .gss_display_status = gss_display_status,
                    .gss_wrap = gss_wrap,
                    .gss_unwrap = gss_unwrap,
                };
            }

            return error.GssApiLibraryUnavailable;
        }

        fn linuxGssApiCandidates() []const []const u8 {
            return switch (builtin.cpu.arch) {
                .x86_64 => &.{
                    "/lib/x86_64-linux-gnu/libgssapi_krb5.so.2",
                    "/usr/lib/x86_64-linux-gnu/libgssapi_krb5.so.2",
                    "/lib64/libgssapi_krb5.so.2",
                    "/usr/lib64/libgssapi_krb5.so.2",
                    "libgssapi_krb5.so.2",
                    "libgssapi_krb5.so",
                    "libgssapi.so.3",
                    "libgssapi.so",
                },
                .aarch64 => &.{
                    "/lib/aarch64-linux-gnu/libgssapi_krb5.so.2",
                    "/usr/lib/aarch64-linux-gnu/libgssapi_krb5.so.2",
                    "/lib64/libgssapi_krb5.so.2",
                    "/usr/lib64/libgssapi_krb5.so.2",
                    "libgssapi_krb5.so.2",
                    "libgssapi_krb5.so",
                    "libgssapi.so.3",
                    "libgssapi.so",
                },
                else => &.{
                    "/lib/libgssapi_krb5.so.2",
                    "/usr/lib/libgssapi_krb5.so.2",
                    "/lib64/libgssapi_krb5.so.2",
                    "/usr/lib64/libgssapi_krb5.so.2",
                    "libgssapi_krb5.so.2",
                    "libgssapi_krb5.so",
                    "libgssapi.so.3",
                    "libgssapi.so",
                },
            };
        }

        fn resolveHostbasedServiceName(lib: *std.DynLib, candidate: []const u8, debug: bool) ?GssOid {
            if (lib.lookup(*GssOid, "GSS_C_NT_HOSTBASED_SERVICE")) |oid_ptr| {
                if (debug) std.log.warn("gssapi: candidate {s} resolved hostbased OID via GSS_C_NT_HOSTBASED_SERVICE", .{candidate});
                return oid_ptr.*;
            }
            if (lib.lookup(*GssOid, "GSS_C_NT_HOSTBASED_SERVICE_X")) |oid_ptr| {
                if (debug) std.log.warn("gssapi: candidate {s} resolved hostbased OID via GSS_C_NT_HOSTBASED_SERVICE_X", .{candidate});
                return oid_ptr.*;
            }
            if (lib.lookup(*GssOid, "__GSS_C_NT_HOSTBASED_SERVICE")) |oid_ptr| {
                if (debug) std.log.warn("gssapi: candidate {s} resolved hostbased OID via __GSS_C_NT_HOSTBASED_SERVICE", .{candidate});
                return oid_ptr.*;
            }
            if (lib.lookup(*GssOid, "__GSS_C_NT_HOSTBASED_SERVICE_X")) |oid_ptr| {
                if (debug) std.log.warn("gssapi: candidate {s} resolved hostbased OID via __GSS_C_NT_HOSTBASED_SERVICE_X", .{candidate});
                return oid_ptr.*;
            }
            if (lib.lookup(*GssOidDesc, "__gss_c_nt_hostbased_service_oid_desc")) |oid_desc| {
                if (debug) std.log.warn("gssapi: candidate {s} resolved hostbased OID via __gss_c_nt_hostbased_service_oid_desc", .{candidate});
                return oid_desc;
            }
            if (lib.lookup(*GssOidDesc, "gss_nt_service_name")) |oid_desc| {
                if (debug) std.log.warn("gssapi: candidate {s} resolved hostbased OID via gss_nt_service_name", .{candidate});
                return oid_desc;
            }
            if (debug) std.log.warn("gssapi: candidate {s} missing hostbased service OID symbol; using RFC fallback", .{candidate});
            return &fallback_hostbased_service_oid_desc;
        }

        fn lookupRequired(
            comptime T: type,
            lib: *std.DynLib,
            candidate: []const u8,
            symbol: [:0]const u8,
            debug: bool,
        ) ?T {
            const value = lib.lookup(T, symbol) orelse {
                if (debug) std.log.warn("gssapi: candidate {s} missing symbol {s}", .{ candidate, symbol });
                return null;
            };
            return value;
        }

        fn gssDebugEnabled() bool {
            const value = process_compat.getEnvVarOwned(std.heap.page_allocator, "QAIL_GSS_DEBUG") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => return false,
                else => return false,
            };
            defer std.heap.page_allocator.free(value);

            if (value.len == 0) return false;
            if (std.mem.eql(u8, value, "0")) return false;
            if (std.ascii.eqlIgnoreCase(value, "false")) return false;
            return true;
        }

        pub fn deinit(self: *Api) void {
            self.lib.close();
        }
    };

    pub const StepResult = struct {
        token: []u8,
        complete: bool,
        ret_flags: OmUint32,
    };

    pub const LinuxKrb5Session = struct {
        api: *const Api,
        context: GssContext = null,
        target_name: GssName = null,
        mechanism: auth_options.GssMechanism,

        pub fn init(api: *const Api, target: []const u8, mechanism: auth_options.GssMechanism) !LinuxKrb5Session {
            switch (mechanism) {
                .kerberos_v5, .gss => {},
                .sspi => return error.UnsupportedGssMechanism,
            }

            const name_type = api.hostbased_service_name orelse return error.GssHostbasedServiceNameUnavailable;

            var minor: OmUint32 = 0;
            var output_name: GssName = null;
            var input = GssBufferDesc{
                .length = target.len,
                .value = if (target.len == 0) null else @ptrCast(@constCast(target.ptr)),
            };

            const major = api.gss_import_name(&minor, &input, name_type, &output_name);
            if (isGssError(major)) {
                logGssError(api, "gss_import_name failed", major, minor);
                return error.GssImportNameFailed;
            }

            return .{
                .api = api,
                .context = null,
                .target_name = output_name,
                .mechanism = mechanism,
            };
        }

        pub fn deinit(self: *LinuxKrb5Session) void {
            var minor: OmUint32 = 0;

            if (self.context != null) {
                _ = self.api.gss_delete_sec_context(&minor, &self.context, null);
                self.context = null;
            }

            if (self.target_name != null) {
                _ = self.api.gss_release_name(&minor, &self.target_name);
                self.target_name = null;
            }
        }

        pub fn step(self: *LinuxKrb5Session, allocator: std.mem.Allocator, input_token: ?[]const u8) !StepResult {
            return self.stepWithFlags(allocator, input_token, GSS_C_MUTUAL_FLAG | GSS_C_SEQUENCE_FLAG);
        }

        pub fn stepWithFlags(
            self: *LinuxKrb5Session,
            allocator: std.mem.Allocator,
            input_token: ?[]const u8,
            req_flags: OmUint32,
        ) !StepResult {
            var minor: OmUint32 = 0;
            var output = GssBufferDesc{ .length = 0, .value = null };
            var input = GssBufferDesc{ .length = 0, .value = null };
            var ret_flags: OmUint32 = 0;
            const input_ptr: ?*const GssBufferDesc = if (input_token) |bytes| blk: {
                input.length = bytes.len;
                input.value = if (bytes.len == 0) null else @ptrCast(@constCast(bytes.ptr));
                break :blk &input;
            } else null;

            const major = self.api.gss_init_sec_context(
                &minor,
                null,
                &self.context,
                self.target_name,
                null,
                req_flags,
                0,
                null,
                input_ptr,
                null,
                &output,
                &ret_flags,
                null,
            );
            const token = try takeGssBuffer(self.api, allocator, &output);
            errdefer allocator.free(token);

            if (isGssError(major)) {
                logGssError(self.api, "gss_init_sec_context failed", major, minor);
                return error.GssInitSecContextFailed;
            }

            const complete = major == GSS_S_COMPLETE;
            const continue_needed = (major & GSS_S_CONTINUE_NEEDED) != 0;
            if (!complete and !continue_needed) return error.GssUnexpectedStatus;

            return .{ .token = token, .complete = complete, .ret_flags = ret_flags };
        }

        pub fn wrap(self: *const LinuxKrb5Session, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
            var minor: OmUint32 = 0;
            var conf_state: i32 = 0;
            var input = GssBufferDesc{
                .length = plaintext.len,
                .value = if (plaintext.len == 0) null else @ptrCast(@constCast(plaintext.ptr)),
            };
            var output = GssBufferDesc{ .length = 0, .value = null };

            const major = self.api.gss_wrap(
                &minor,
                self.context,
                1,
                0,
                &input,
                &conf_state,
                &output,
            );
            const token = try takeGssBuffer(self.api, allocator, &output);
            errdefer allocator.free(token);

            if (isGssError(major)) {
                logGssError(self.api, "gss_wrap failed", major, minor);
                return error.GssWrapFailed;
            }
            if (conf_state == 0) return error.GssWrapWithoutConfidentiality;
            return token;
        }

        pub fn unwrap(self: *const LinuxKrb5Session, allocator: std.mem.Allocator, wrapped: []const u8) ![]u8 {
            var minor: OmUint32 = 0;
            var conf_state: i32 = 0;
            var qop_state: OmUint32 = 0;
            var input = GssBufferDesc{
                .length = wrapped.len,
                .value = if (wrapped.len == 0) null else @ptrCast(@constCast(wrapped.ptr)),
            };
            var output = GssBufferDesc{ .length = 0, .value = null };

            const major = self.api.gss_unwrap(
                &minor,
                self.context,
                &input,
                &output,
                &conf_state,
                &qop_state,
            );
            const token = try takeGssBuffer(self.api, allocator, &output);
            errdefer allocator.free(token);

            if (isGssError(major)) {
                logGssError(self.api, "gss_unwrap failed", major, minor);
                return error.GssUnwrapFailed;
            }
            if (conf_state == 0) return error.GssUnwrapWithoutConfidentiality;
            return token;
        }
    };

    const TrackedSession = struct {
        session: LinuxKrb5Session,
        last_seen_ms: i64,
    };

    allocator: std.mem.Allocator,
    api: Api,
    target_name: []u8,
    mutex: std.Io.Mutex = .init,
    sessions: std.AutoHashMap(u64, TrackedSession),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: LinuxKrb5ProviderConfig) !Self {
        var report = try kerberos_preflight.linuxKrb5Preflight(allocator, config);
        errdefer report.deinit();

        var api = try Api.load();
        errdefer api.deinit();

        const target_name = report.target_name;
        report.target_name = &.{};
        report.deinit();

        return .{
            .allocator = allocator,
            .api = api,
            .target_name = target_name,
            .sessions = std.AutoHashMap(u64, TrackedSession).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.session.deinit();
        }
        self.sessions.deinit();
        self.allocator.free(self.target_name);
        self.api.deinit();
    }

    pub fn authOptions(self: *Self, base: auth_options.AuthOptions) auth_options.AuthOptions {
        var out = base;
        out.allow_kerberos_v5 = true;
        out.allow_gssapi = true;
        out.gss_token_provider_ex = callback;
        out.gss_context = self;
        return out;
    }

    pub fn callback(ctx: ?*anyopaque, request: auth_options.GssTokenRequest, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx orelse return error.GssTokenProviderRequired));
        return self.handleRequest(request, allocator);
    }

    fn handleRequest(self: *Self, request: auth_options.GssTokenRequest, allocator: std.mem.Allocator) ![]const u8 {
        const io_iface = io_compat.runtimeIo();
        self.mutex.lockUncancelable(io_iface);
        defer self.mutex.unlock(io_iface);

        self.pruneStaleSessions();

        if (request.server_token == null) {
            if (self.sessions.count() >= GSS_MAX_SESSIONS) return error.GssSessionLimitReached;
            if (self.sessions.fetchRemove(request.session_id)) |removed| {
                var tracked = removed.value;
                tracked.session.deinit();
            }

            var session = try LinuxKrb5Session.init(&self.api, self.target_name, request.mechanism);
            errdefer session.deinit();

            const step = try session.step(allocator, null);
            errdefer allocator.free(step.token);

            if (!step.complete) {
                try self.sessions.put(request.session_id, .{
                    .session = session,
                    .last_seen_ms = std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds(),
                });
            }

            return step.token;
        }

        var tracked = self.sessions.fetchRemove(request.session_id) orelse return error.GssSessionNotFound;
        errdefer tracked.value.session.deinit();

        if (tracked.value.session.mechanism != request.mechanism) return error.GssSessionMechanismMismatch;

        const step = try tracked.value.session.step(allocator, request.server_token);
        errdefer allocator.free(step.token);

        if (!step.complete) {
            try self.sessions.put(request.session_id, .{
                .session = tracked.value.session,
                .last_seen_ms = std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds(),
            });
        } else {
            tracked.value.session.deinit();
        }

        return step.token;
    }

    fn pruneStaleSessions(self: *Self) void {
        const cutoff = std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds() - GSS_SESSION_TTL_MS;
        var stale_keys: [GSS_MAX_SESSIONS]u64 = undefined;
        var stale_count: usize = 0;

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_seen_ms <= cutoff and stale_count < stale_keys.len) {
                stale_keys[stale_count] = entry.key_ptr.*;
                stale_count += 1;
            }
        }

        for (stale_keys[0..stale_count]) |key| {
            if (self.sessions.fetchRemove(key)) |removed| {
                var tracked = removed.value;
                tracked.session.deinit();
            }
        }
    }
} else struct {
    pub fn init(_: std.mem.Allocator, _: LinuxKrb5ProviderConfig) !@This() {
        return error.UnsupportedLinuxKrb5ProviderPlatform;
    }

    pub fn deinit(_: *@This()) void {}

    pub fn authOptions(_: *@This(), base: auth_options.AuthOptions) auth_options.AuthOptions {
        return base;
    }
};

pub fn linuxKrb5TokenProvider(
    allocator: std.mem.Allocator,
    config: LinuxKrb5ProviderConfig,
) !LinuxKrb5Provider {
    return LinuxKrb5Provider.init(allocator, config);
}

fn isGssError(major: u32) bool {
    return (major & 0xFF00_0000) != 0;
}

fn takeGssBuffer(api: anytype, allocator: std.mem.Allocator, buffer: anytype) ![]u8 {
    const result = if (buffer.length == 0 or buffer.value == null)
        try allocator.dupe(u8, &.{})
    else blk: {
        const bytes: [*]const u8 = @ptrCast(buffer.value.?);
        break :blk try allocator.dupe(u8, bytes[0..buffer.length]);
    };

    var minor: u32 = 0;
    _ = api.gss_release_buffer(&minor, buffer);
    return result;
}

fn logGssError(api: anytype, prefix: []const u8, major: u32, minor: u32) void {
    std.log.err("{s}: major={d} ({s}) minor={d} ({s})", .{
        prefix,
        major,
        statusMessages(api, major, 1),
        minor,
        statusMessages(api, minor, 2),
    });
}

fn statusMessages(api: anytype, status: u32, status_type: i32) []const u8 {
    if (builtin.os.tag != .linux) return "unsupported";
    const GssBufferDesc = LinuxKrb5Provider.GssBufferDesc;

    var buffer: [512]u8 = undefined;
    var fbs = io_compat.FixedBufferWriter.init(&buffer);
    const writer = fbs.writer();
    var message_context: u32 = 0;
    var first = true;

    while (true) {
        var minor: u32 = 0;
        var msg_buf: GssBufferDesc = .{ .length = 0, .value = null };
        const major = api.gss_display_status(
            &minor,
            status,
            status_type,
            null,
            &message_context,
            &msg_buf,
        );

        if (msg_buf.length != 0 and msg_buf.value != null) {
            if (!first) writer.writeAll("; ") catch break;
            const bytes: [*]const u8 = @ptrCast(msg_buf.value.?);
            writer.writeAll(bytes[0..msg_buf.length]) catch break;
            first = false;
        }

        var release_minor: u32 = 0;
        _ = api.gss_release_buffer(&release_minor, &msg_buf);

        if (isGssError(major) or message_context == 0) break;
    }

    if (fbs.getWritten().len == 0) return "code";
    return fbs.getWritten();
}

test "linux krb5 token provider is unsupported on non-linux targets" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    try std.testing.expectError(
        error.UnsupportedLinuxKrb5ProviderPlatform,
        linuxKrb5TokenProvider(std.testing.allocator, .{ .host = "db.internal" }),
    );
}

test "linux krb5 hostbased oid fallback matches RFC value" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const oid = LinuxKrb5Provider.fallback_hostbased_service_oid_desc;
    try std.testing.expectEqual(@as(u32, 10), oid.length);

    const bytes: [*]const u8 = @ptrCast(oid.elements.?);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x04 },
        bytes[0..oid.length],
    );
}
