//! PIN hashing.
//!
//! A PIN is a password, and Eatery v1 stored PINs where a curious
//! operator could read them. Restaurant OS hashes them, and it hashes them with a
//! deliberately SLOW key-derivation function: bcrypt. A stolen
//! database is then expensive to turn back into PINs, which is the
//! whole difference between a PIN and a name on a list.
//!
//! The hash is a versioned string - bcrypt's own crypt format,
//! "$2b$10$<salt>$<digest>" - and it carries the cost and the salt
//! with it. That is what makes it versioned: the cost can be raised
//! later, the old hashes still verify, and a hash written by a future
//! version of the app is readable by this one.
//!
//! The salt is the installation's, so two restaurants with the same PIN
//! do not share a hash. It is DERIVED from the installation salt rather
//! than random per employee, because the sign-in finds the employee by
//! the hash it computes: a random per-employee salt would mean trying
//! every employee in turn, and a slow hash for each of them.
//!
//! This module is pure - no clock, no allocation, no effects - so it
//! runs inside `update` without breaking the model-is-a-pure-function
//! rule. It is also slow on purpose: that is the point of it.

const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;

/// The length of a hash, in the crypt form. The buffer is larger than
/// the string because the writer that lays the string out wants room
/// for its own alignment.
pub const hash_length = 128;

/// The length of the installation salt, in hex characters.
pub const salt_len = 64;

/// The length of the OLD hash: a SHA-256 digest, hex-encoded.
pub const legacy_len = 64;

/// The cost of the key derivation: 2^10 rounds of bcrypt. On a modern
/// core that is about a tenth of a second - a pause at the sign-in,
/// and a very long time for anyone guessing.
pub const cost: u6 = 10;

/// The bytes of the installation salt that bcrypt salts with.
const salt_bytes = 16;

/// The shortest PIN this app accepts.
///
/// A four-digit PIN is ten thousand guesses, and a stolen database is
/// worth ten thousand guesses. Six digits is a hundred times more, and
/// a restaurant's staff can still type one without writing it down.
pub const min_pin_len = 6;

/// Hash a PIN for storage.
///
/// The result carries its own salt and cost, so it can be verified
/// years later without knowing what the app was doing then. Null when
/// the hash cannot be made.
pub fn hashPin(salt: []const u8, pin: []const u8, out: *[hash_length]u8) ?[]const u8 {
    const derived = deriveSalt(salt) orelse return null;
    const options: bcrypt.HashOptions = .{
        .params = .{ .rounds_log = cost, .silently_truncate_password = false },
        .encoding = .crypt,
    };
    const written = bcrypt.strHashWithSalt(pin, options, out, derived) catch return null;
    return written;
}

/// Verify a PIN against a stored hash.
///
/// The hash may be a bcrypt string or one of the old SHA-256 digests -
/// a bare sixty-four hex characters - so a restaurant that has been
/// running keeps working.
pub fn verifyPin(salt: []const u8, pin: []const u8, stored: []const u8) bool {
    if (isLegacy(stored)) {
        var buffer: [legacy_len]u8 = undefined;
        const computed = legacyHash(salt, pin, &buffer) orelse return false;
        return std.mem.eql(u8, computed, stored);
    }
    bcrypt.strVerify(stored, pin, .{ .silently_truncate_password = false }) catch return false;
    return true;
}

/// True when the stored hash is one of the old SHA-256 digests.
///
/// The old hash is sixty-four hex characters; a bcrypt string starts
/// with a dollar sign.
pub fn isLegacy(stored: []const u8) bool {
    return stored.len == legacy_len and !std.mem.startsWith(u8, stored, "$");
}

/// The OLD hash: a SHA-256 digest of the salt and the PIN, hex
/// encoded.
///
/// It is what the app stored before bcrypt, and what it looks up so a
/// restaurant that has been running can still sign in. The next
/// sign-in rewrites the row in the new form.
pub fn legacyHash(salt: []const u8, pin: []const u8, out: *[legacy_len]u8) ?[]const u8 {
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
    return out[0..];
}

/// The bytes bcrypt salts with, derived from the installation salt.
///
/// The installation salt is hex, and the first sixteen bytes of it are
/// the salt. A salt is not a secret - it is written into the hash
/// string anyway - so this is a way of spreading one installation's
/// salt over every hash it makes.
fn deriveSalt(salt: []const u8) ?[salt_bytes]u8 {
    if (salt.len < salt_bytes * 2) return null;
    var out: [salt_bytes]u8 = undefined;
    for (0..salt_bytes) |index| {
        const high = hexValue(salt[index * 2]) orelse return null;
        const low = hexValue(salt[index * 2 + 1]) orelse return null;
        out[index] = (high << 4) | low;
    }
    return out;
}

/// One hex digit, or null.
fn hexValue(digit: u8) ?u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 10,
        'A'...'F' => digit - 'A' + 10,
        else => null,
    };
}

/// Generate a fresh installation salt, hex-encoded. Called once, when
/// the database is created.
///
/// Zig 0.16 takes randomness from an `Io`, so this runs at boot (where
/// the app has one) rather than inside `update` (where it does not).
pub fn makeSalt(io: std.Io, out: *[salt_len]u8) void {
    var raw: [salt_len / 2]u8 = undefined;
    std.Io.random(io, &raw);
    const alphabet = "0123456789abcdef";
    for (raw, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

/// The length of a device token in hex characters.
pub const token_len = 16;

/// Generate a token that names THIS installation.
///
/// The token is not a secret - the salt is - it is a name. It gives
/// every request key this device makes a namespace of its own, so two
/// devices writing to the same database cannot take the same key and
/// mistake each other's sale for a retry of their own.
pub fn makeToken(io: std.Io, out: *[token_len]u8) void {
    var raw: [token_len / 2]u8 = undefined;
    std.Io.random(io, &raw);
    const alphabet = "0123456789abcdef";
    for (raw, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}
