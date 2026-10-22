//! The app's side of the wire.
//!
//! `net/server.zig` owns the socket and knows nothing about the model.
//! This file is the joint: it publishes the channel the thread posts
//! into, answers the requests the thread delivers, and records the
//! answers to the requests the app makes.
//!
//! The work happens in `update`, on the loop thread, for the usual
//! reason: every state change is one place. The thread only moves bytes.
//!
//! ## What answers what
//!
//! | Request | Today |
//! |---|---|
//! | `GET /v1/hello` | the peer card, from the model |
//! | `GET /v1/ops` | an empty NDJSON body - the ops arrive in 9.3 |
//! | `POST /v1/ops` | accepted, counted, and held for 9.3 |
//! | anything else | 404 |
//!
//! The device id is the installation token for now. It is stable for the
//! life of the process, which is enough to prove the seam; 9.3 replaces
//! it with the `device` row, which is stable across restarts.

const std = @import("std");
const native_sdk = @import("native_sdk");

const model_mod = @import("model.zig");
const msg_mod = @import("msg.zig");
const protocol = @import("../net/protocol.zig");
const server = @import("../net/server.zig");

const Model = model_mod.Model;
const Msg = msg_mod.Msg;
const Effects = native_sdk.Effects(Msg);

/// The channel's key on the effects channel. The database keys are small
/// and dense; this is far away from them on purpose.
pub const channel_key: u64 = 9001;

pub const app_version = "0.1.0";

/// The state both threads reach. One per process.
var shared = struct {
    handle: native_sdk.ChannelHandle = .{},
    server_state: server.Shared = .{},
    bind_host: [64]u8 = undefined,
    bind_host_len: usize = 0,
}{};

/// Open the channel and tell the thread it may post.
///
/// Called from `boot`, which is the first thing the runtime runs on the
/// loop thread and the only place that has an `fx`.
pub fn open(fx: *Effects) void {
    shared.handle = fx.openChannel(.{
        .key = channel_key,
        .on_event = Effects.channelMsg(.net),
    });
    shared.server_state.app_ready.store(true, .release);
}

/// Start the listener thread. `main` calls this: it is the one place
/// with an `Io`.
pub fn start(io: std.Io, bind_host: []const u8, port: u16) !std.Thread {
    const len = @min(bind_host.len, shared.bind_host.len);
    @memcpy(shared.bind_host[0..len], bind_host[0..len]);
    shared.bind_host_len = len;

    return std.Thread.spawn(.{}, server.run, .{
        io,
        server.Config{
            .bind_host = shared.bind_host[0..len],
            .port = port,
            .poster = .{ .context = @ptrCast(&shared), .post = post },
        },
        &shared.server_state,
    });
}

/// Stop the listener and wake it out of `accept`. Call before joining.
pub fn stop(io: std.Io) void {
    server.stop(io, &shared.server_state);
}

fn post(context: *anyopaque, bytes: []const u8) bool {
    _ = context;
    return switch (shared.handle.post(bytes)) {
        .accepted => true,
        .dropped_full, .dropped_oversized, .closed => false,
    };
}

/// A message from the net thread.
pub fn onChannel(model: *Model, event: native_sdk.EffectChannelEvent) void {
    switch (event.kind) {
        .data => {
            // The bytes are drain scratch: valid only for this call, so
            // anything the model keeps is copied.
            const control = server.Control.parse(event.bytes) orelse return;
            switch (control) {
                .listener => |where| {
                    model.net_port = where.port;
                    model.net_bound = true;
                    const len = @min(where.host.len, model.net_host_buf.len);
                    @memcpy(model.net_host_buf[0..len], where.host[0..len]);
                    model.net_host_len = len;
                },
                .request => |request| {
                    model.net_requests +%= 1;
                    answer(model, request.conn, request.bytes);
                },
            }
        },
        .closed, .rejected => {},
    }
}

/// A peer's answer to a request this app made. 9.3 applies the ops it
/// carries; today the answer is recorded so the seam is visible.
pub fn onResponse(model: *Model, response: native_sdk.EffectResponse) void {
    model.peer_outcome = @tagName(response.outcome);
    model.peer_status = response.status;
    const len = @min(response.body.len, model.peer_body_buf.len);
    @memcpy(model.peer_body_buf[0..len], response.body[0..len]);
    model.peer_body_len = len;
}

// --------------------------------------------------------------- answers

fn answer(model: *Model, conn: u32, bytes: []const u8) void {
    const split = server.splitBody(bytes);
    const request = server.Request.parse(split.head) orelse return;

    var body: [4096]u8 = undefined;
    var body_len: usize = 0;
    var status: u16 = 200;
    var reason: []const u8 = "OK";
    var content_type: []const u8 = protocol.content_type;

    if (std.mem.eql(u8, request.path, protocol.endpoints.hello)) {
        var writer = std.Io.Writer.fixed(&body);
        protocol.encodeHello(&writer, helloCard(model)) catch return;
        body_len = writer.end;
        content_type = "application/json";
    } else if (std.mem.eql(u8, request.path, protocol.endpoints.ops)) {
        switch (request.method) {
            .get => {
                // 9.3: the ops this device holds above the cursor. The
                // empty answer is honest - this build has no op log yet.
                body_len = 0;
            },
            .post => {
                const text = std.fmt.bufPrint(&body, "{{\"accepted\":{d}}}\n", .{split.body.len}) catch return;
                body_len = text.len;
                content_type = "application/json";
            },
            .other => {
                status = 405;
                reason = "Method Not Allowed";
                const text = "{\"error\":\"method not allowed\"}\n";
                @memcpy(body[0..text.len], text);
                body_len = text.len;
                content_type = "application/json";
            },
        }
    } else {
        status = 404;
        reason = "Not Found";
        const text = "{\"error\":\"not found\"}\n";
        @memcpy(body[0..text.len], text);
        body_len = text.len;
        content_type = "application/json";
    }

    var response: [server.max_frame_bytes]u8 = undefined;
    const text = server.formatResponse(&response, status, reason, content_type, body[0..body_len]) catch return;
    if (!shared.server_state.outbox.write(conn, text)) {
        model.net_dropped = shared.server_state.outbox.dropped.load(.monotonic);
    }
}

fn helloCard(model: *const Model) protocol.Hello {
    return .{
        .device = if (model.device_token_len > 0) model.device_token_buf[0..model.device_token_len] else "device",
        .role = switch (model.role) {
            .admin => .admin,
            .waiter => .waiter,
            .kds => .kds,
            .display => .display,
        },
        .host = if (model.net_host_len > 0) model.net_host_buf[0..model.net_host_len] else "127.0.0.1",
        .tcp = model.net_port,
        .app_version = app_version,
    };
}

/// Read the answer the app wrote for a connection. The tests need it:
/// the outbox is process-wide because the net thread and the loop thread
/// both reach it, and a test that used a different outbox would be
/// testing nothing.
pub fn takeAnswer(conn: u32, out: []u8) ?usize {
    return shared.server_state.outbox.read(conn, out);
}

/// The listener's port, as the net thread reported it.
pub fn listeningPort() u16 {
    return shared.server_state.port.load(.acquire);
}
