//! Fuzz test: Protocol Decoder
//!
//! Goal: Decoder.readHeader/parseAuthentication/parseErrorResponse/etc
//! must NEVER panic on arbitrary input bytes. They may return errors, but
//! must never crash, abort, or enter an infinite loop.
//!
//! Port of qail.rs/pg/fuzz/fuzz_targets/wire_decode.rs

const std = @import("std");
const Decoder = @import("../protocol/decoder.zig").Decoder;

fn fuzzDecoder(_: @TypeOf(.{}), input: []const u8) anyerror!void {
    // 1) readHeader — parses message type byte + u32 length
    {
        var decoder = Decoder.init(input);
        _ = decoder.readHeader() catch {};
    }

    // 2) parseAuthentication — reads u32 auth type
    {
        var decoder = Decoder.init(input);
        _ = decoder.parseAuthentication() catch {};
    }

    // 3) parseReadyForQuery — reads single byte
    {
        var decoder = Decoder.init(input);
        _ = decoder.parseReadyForQuery() catch {};
    }

    // 4) parseCommandComplete — reads C string
    {
        var decoder = Decoder.init(input);
        _ = decoder.parseCommandComplete() catch {};
    }

    // 5) parseErrorResponse — reads field type + C strings until NUL
    {
        var decoder = Decoder.init(input);
        _ = decoder.parseErrorResponse() catch {};
    }

    // 6) parseParameterStatus — reads two C strings
    {
        var decoder = Decoder.init(input);
        _ = decoder.parseParameterStatus() catch {};
    }

    // 7) parseBackendKeyData — reads two u32s
    {
        var decoder = Decoder.init(input);
        _ = decoder.parseBackendKeyData() catch {};
    }

    // 8) Sequential: if header succeeds, try parsing based on message type
    {
        var decoder = Decoder.init(input);
        if (decoder.readHeader()) |header| {
            switch (header.msg_type) {
                .authentication => {
                    _ = decoder.parseAuthentication() catch {};
                },
                .ready_for_query => {
                    _ = decoder.parseReadyForQuery() catch {};
                },
                .error_response => {
                    _ = decoder.parseErrorResponse() catch {};
                },
                .parameter_status => {
                    _ = decoder.parseParameterStatus() catch {};
                },
                .backend_key_data => {
                    _ = decoder.parseBackendKeyData() catch {};
                },
                .command_complete => {
                    _ = decoder.parseCommandComplete() catch {};
                },
                else => {},
            }
        } else |_| {}
    }
}

test "fuzz: protocol decoder never panics on arbitrary bytes" {
    try std.testing.fuzz(.{}, fuzzDecoder, .{});
}
