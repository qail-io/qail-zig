//! QAIL Language Server Protocol Implementation
//!
//! Provides IDE features for QAIL queries:
//! - Syntax error diagnostics
//! - Hover information (SQL preview)
//! - Completion suggestions
//! - Schema validation
//!
//! Port of qail.rs/qail-lsp/src/main.rs

const std = @import("std");
const json = std.json;

// ==================== JSON-RPC Types ====================

pub const JsonRpcMessage = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?json.Value = null,
    method: ?[]const u8 = null,
    params: ?json.Value = null,
    result: ?json.Value = null,
    @"error": ?JsonRpcError = null,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
};

// ==================== LSP Types ====================

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?u32 = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8,
};

pub const DiagnosticSeverity = struct {
    pub const Error: u32 = 1;
    pub const Warning: u32 = 2;
    pub const Info: u32 = 3;
    pub const Hint: u32 = 4;
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?u32 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    insertTextFormat: ?u32 = null,
};

pub const CompletionItemKind = struct {
    pub const Keyword: u32 = 14;
    pub const Function: u32 = 3;
    pub const Snippet: u32 = 15;
    pub const Class: u32 = 7;
    pub const Field: u32 = 5;
};

pub const InsertTextFormat = struct {
    pub const PlainText: u32 = 1;
    pub const Snippet: u32 = 2;
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

pub const MarkupContent = struct {
    kind: []const u8,
    value: []const u8,
};

pub const TextDocumentSyncKind = struct {
    pub const None: u32 = 0;
    pub const Full: u32 = 1;
    pub const Incremental: u32 = 2;
};

// ==================== Server Capabilities ====================

pub const ServerCapabilities = struct {
    textDocumentSync: u32 = TextDocumentSyncKind.Full,
    hoverProvider: bool = true,
    completionProvider: ?CompletionOptions = null,
    definitionProvider: bool = true,
};

pub const CompletionOptions = struct {
    triggerCharacters: []const []const u8 = &.{ ":", "[", "#" },
};
