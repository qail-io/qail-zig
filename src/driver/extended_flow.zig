const std = @import("std");
const protocol = @import("../protocol/mod.zig");

const BackendMessage = protocol.BackendMessage;

/// Configuration for extended-protocol response ordering.
pub const ExtendedFlowConfig = struct {
    /// Whether a ParseComplete is expected before BindComplete on success.
    expect_parse_complete: bool,
    /// Whether ParameterDescription is allowed in this flow.
    allow_parameter_description: bool,
    /// Whether RowDescription may appear before BindComplete.
    allow_row_description_before_bind: bool,
    /// Whether NoData may appear before BindComplete.
    allow_no_data_before_bind: bool,
    /// Whether NoData may appear after BindComplete.
    allow_no_data_after_bind: bool,
    /// Whether successful completion must include BindComplete.
    require_bind_complete_on_success: bool,
    /// Whether successful completion must include a terminal completion message.
    require_completion_on_success: bool,

    /// Parse + Bind + Execute + Sync (no Describe roundtrip).
    pub fn parseBindExecute(expect_parse_complete: bool) ExtendedFlowConfig {
        return .{
            .expect_parse_complete = expect_parse_complete,
            .allow_parameter_description = false,
            .allow_row_description_before_bind = false,
            .allow_no_data_before_bind = false,
            .allow_no_data_after_bind = false,
            .require_bind_complete_on_success = true,
            .require_completion_on_success = true,
        };
    }

    /// Parse + Bind + Describe(Portal) + Execute + Sync.
    pub fn parseBindDescribePortalExecute(expect_parse_complete: bool) ExtendedFlowConfig {
        return .{
            .expect_parse_complete = expect_parse_complete,
            .allow_parameter_description = false,
            .allow_row_description_before_bind = false,
            .allow_no_data_before_bind = false,
            .allow_no_data_after_bind = true,
            .require_bind_complete_on_success = true,
            .require_completion_on_success = true,
        };
    }

    /// Parse + Bind + Describe(Portal) + Sync.
    pub fn parseBindDescribePortal(expect_parse_complete: bool) ExtendedFlowConfig {
        return .{
            .expect_parse_complete = expect_parse_complete,
            .allow_parameter_description = false,
            .allow_row_description_before_bind = false,
            .allow_no_data_before_bind = false,
            .allow_no_data_after_bind = true,
            .require_bind_complete_on_success = true,
            .require_completion_on_success = false,
        };
    }

    /// Parse + Describe(Statement) + Bind + Execute + Sync.
    pub fn parseDescribeStatementBindExecute(expect_parse_complete: bool) ExtendedFlowConfig {
        return .{
            .expect_parse_complete = expect_parse_complete,
            .allow_parameter_description = true,
            .allow_row_description_before_bind = true,
            .allow_no_data_before_bind = true,
            .allow_no_data_after_bind = false,
            .require_bind_complete_on_success = true,
            .require_completion_on_success = true,
        };
    }

    /// Parse + Sync (prepare-only flow).
    pub fn parseOnly(expect_parse_complete: bool) ExtendedFlowConfig {
        return .{
            .expect_parse_complete = expect_parse_complete,
            .allow_parameter_description = false,
            .allow_row_description_before_bind = false,
            .allow_no_data_before_bind = false,
            .allow_no_data_after_bind = false,
            .require_bind_complete_on_success = false,
            .require_completion_on_success = false,
        };
    }
};

/// Runtime tracker for one extended-protocol response flow.
pub const ExtendedFlowTracker = struct {
    cfg: ExtendedFlowConfig,
    saw_parse_complete: bool = false,
    saw_bind_complete: bool = false,
    saw_completion: bool = false,
    saw_error_response: bool = false,

    pub fn init(cfg: ExtendedFlowConfig) ExtendedFlowTracker {
        return .{
            .cfg = cfg,
        };
    }

    pub fn sawParseComplete(self: *const ExtendedFlowTracker) bool {
        return self.saw_parse_complete;
    }

    /// Validate that `msg_type` is legal for the current flow phase.
    ///
    /// `error_pending` should be `true` when caller has already seen an
    /// ErrorResponse and is draining until ReadyForQuery.
    pub fn validate(self: *ExtendedFlowTracker, msg_type: BackendMessage, error_pending: bool) !void {
        switch (msg_type) {
            .error_response => {
                self.saw_error_response = true;
                return;
            },
            .parse_complete => {
                if (!self.cfg.expect_parse_complete) return error.UnexpectedParseComplete;
                if (self.saw_parse_complete) return error.DuplicateParseComplete;
                if (self.saw_bind_complete) return error.ParseCompleteAfterBindComplete;
                if (self.saw_completion) return error.ParseCompleteAfterCompletion;
                self.saw_parse_complete = true;
                return;
            },
            .parameter_description => {
                if (!self.cfg.allow_parameter_description) return error.UnexpectedParameterDescription;
                if (self.cfg.expect_parse_complete and !self.saw_parse_complete) {
                    return error.ParameterDescriptionBeforeParseComplete;
                }
                if (self.saw_bind_complete) return error.ParameterDescriptionAfterBindComplete;
                if (self.saw_completion) return error.ParameterDescriptionAfterCompletion;
                return;
            },
            .bind_complete => {
                if (self.saw_bind_complete) return error.DuplicateBindComplete;
                if (self.cfg.expect_parse_complete and !self.saw_parse_complete and !error_pending and !self.saw_error_response) {
                    return error.BindCompleteBeforeParseComplete;
                }
                if (self.saw_completion) return error.BindCompleteAfterCompletion;
                self.saw_bind_complete = true;
                return;
            },
            .row_description => {
                if (self.saw_completion) return error.RowDescriptionAfterCompletion;
                if (!self.saw_bind_complete) {
                    if (!self.cfg.allow_row_description_before_bind) return error.RowDescriptionBeforeBindComplete;
                    if (self.cfg.expect_parse_complete and !self.saw_parse_complete) {
                        return error.RowDescriptionBeforeParseComplete;
                    }
                }
                return;
            },
            .no_data => {
                if (self.saw_completion) return error.NoDataAfterCompletion;
                if (self.saw_bind_complete) {
                    if (!self.cfg.allow_no_data_after_bind) return error.UnexpectedNoDataAfterBindComplete;
                } else {
                    if (!self.cfg.allow_no_data_before_bind) return error.UnexpectedNoDataBeforeBindComplete;
                    if (self.cfg.expect_parse_complete and !self.saw_parse_complete) {
                        return error.NoDataBeforeParseComplete;
                    }
                }
                return;
            },
            .data_row => {
                if (!self.saw_bind_complete) return error.DataRowBeforeBindComplete;
                if (self.saw_completion) return error.DataRowAfterCompletion;
                return;
            },
            .command_complete, .portal_suspended, .empty_query => {
                if (!self.saw_bind_complete and !error_pending and !self.saw_error_response) {
                    return error.CompletionBeforeBindComplete;
                }
                if (self.saw_completion) return error.DuplicateCompletionMessage;
                self.saw_completion = true;
                return;
            },
            .ready_for_query => {
                if (error_pending or self.saw_error_response) return;
                if (self.cfg.expect_parse_complete and !self.saw_parse_complete) {
                    return error.ReadyForQueryBeforeParseComplete;
                }
                if (self.cfg.require_bind_complete_on_success and !self.saw_bind_complete) {
                    return error.ReadyForQueryBeforeBindComplete;
                }
                if (self.cfg.require_completion_on_success and !self.saw_completion) {
                    return error.ReadyForQueryBeforeCompletion;
                }
                return;
            },
            .notice, .parameter_status => return,
            else => return,
        }
    }

    /// Validate one backend message by wire-type byte.
    pub fn validateMsgType(self: *ExtendedFlowTracker, msg_type: u8, error_pending: bool) !void {
        if (msg_type == 'N' or msg_type == 'S') return;

        const parsed: BackendMessage = switch (msg_type) {
            '1' => .parse_complete,
            '2' => .bind_complete,
            't' => .parameter_description,
            'T' => .row_description,
            'n' => .no_data,
            'D' => .data_row,
            'C' => .command_complete,
            's' => .portal_suspended,
            'I' => .empty_query,
            'E' => .error_response,
            'Z' => .ready_for_query,
            else => return error.UnexpectedBackendMessageType,
        };
        try self.validate(parsed, error_pending);
    }
};

test "extended flow parse_bind_execute happy path" {
    var tracker = ExtendedFlowTracker.init(ExtendedFlowConfig.parseBindExecute(true));
    try tracker.validate(.parse_complete, false);
    try tracker.validate(.bind_complete, false);
    try tracker.validate(.row_description, false);
    try tracker.validate(.data_row, false);
    try tracker.validate(.command_complete, false);
    try tracker.validate(.ready_for_query, false);
}

test "extended flow parse_bind_execute rejects bind before parse" {
    var tracker = ExtendedFlowTracker.init(ExtendedFlowConfig.parseBindExecute(true));
    try std.testing.expectError(error.BindCompleteBeforeParseComplete, tracker.validate(.bind_complete, false));
}

test "extended flow parse_bind_execute rejects data before bind" {
    var tracker = ExtendedFlowTracker.init(ExtendedFlowConfig.parseBindExecute(true));
    try tracker.validate(.parse_complete, false);
    try std.testing.expectError(error.DataRowBeforeBindComplete, tracker.validate(.data_row, false));
}

test "extended flow parse_bind_execute rejects ready before completion" {
    var tracker = ExtendedFlowTracker.init(ExtendedFlowConfig.parseBindExecute(true));
    try tracker.validate(.parse_complete, false);
    try tracker.validate(.bind_complete, false);
    try std.testing.expectError(error.ReadyForQueryBeforeCompletion, tracker.validate(.ready_for_query, false));
}

test "extended flow parse_describe_statement allows pre-bind describe messages" {
    var tracker = ExtendedFlowTracker.init(ExtendedFlowConfig.parseDescribeStatementBindExecute(true));
    try tracker.validate(.parse_complete, false);
    try tracker.validate(.parameter_description, false);
    try tracker.validate(.row_description, false);
    try tracker.validate(.bind_complete, false);
    try tracker.validate(.command_complete, false);
    try tracker.validate(.ready_for_query, false);
}

test "extended flow parse_bind_describe_portal allows no_data after bind" {
    var tracker = ExtendedFlowTracker.init(ExtendedFlowConfig.parseBindDescribePortalExecute(true));
    try tracker.validate(.parse_complete, false);
    try tracker.validate(.bind_complete, false);
    try tracker.validate(.no_data, false);
    try tracker.validate(.command_complete, false);
    try tracker.validate(.ready_for_query, false);
}
