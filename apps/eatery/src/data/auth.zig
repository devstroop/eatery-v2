//! PIN hashing.
//!
//! A PIN is a password, and Eatery v1 stored PINs where a curious
//! operator could read them. v2 hashes them: SHA-256 over
//! `salt || pin`, hex-encoded, salted per installation so two
//! restaurants with the same PIN do not share a hash.
//!
//! This module is pure - no clock, no allocation, no effects - so it
//! runs inside `update` without breaking the model-is-a-pure-function
//! rule.

const std = @import("std");

/// The hex length of a SHA-256 digest.
pub const hex_len = 64;

/// Hash a PIN with the installation salt, hex-encoded.
///
/// The salt is stored in `app_config` (see the schema) and never leaves
/// the device.
pub fn hashPin(salt: []const u8, pin: []const u8, out: *[hex_len]u8) void {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(salt);
    hasher.update(pin);
    hasher.final(&digest);

    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

/// Generate a fresh installation salt, hex-encoded. Called once, when
/// the database is created.
///
/// Zig 0.16 takes randomness from an `Io`, so this runs at boot (where
/// the app has one) rather than inside `update` (where it does not).
pub fn makeSalt(io: std.Io, out: *[hex_len]u8) void {
    var raw: [hex_len / 2]u8 = undefined;
    std.Io.random(io, &raw);
    const alphabet = "0123456789abcdef";
    for (raw, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

/// Compare two hashes without an early exit - a constant-time compare
/// keeps the check honest even though the attacker controls neither
/// side's timing in a meaningful way here.
pub fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |x, y| difference |= x ^ y;
    return difference == 0;
}
