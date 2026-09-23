const std = @import("std");

pub const Decision = enum {
    none,
    defer_until_modal_closes,
    present,
};

pub fn decide(completed_offer: bool, deferred_offer: bool, modal_active: bool) Decision {
    if (!completed_offer and !deferred_offer) return .none;
    if (modal_active) return .defer_until_modal_closes;
    return .present;
}

test "update offer remains deferred until the native modal closes" {
    try std.testing.expectEqual(Decision.none, decide(false, false, false));
    try std.testing.expectEqual(Decision.defer_until_modal_closes, decide(true, false, true));
    try std.testing.expectEqual(Decision.defer_until_modal_closes, decide(false, true, true));
    try std.testing.expectEqual(Decision.present, decide(false, true, false));
}
