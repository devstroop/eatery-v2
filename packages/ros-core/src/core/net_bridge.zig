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
//! | `GET /v1/ops` | the recent ops above the requester's cursor |
//! | `POST /v1/ops` | decoded, validated, and applied |
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
const record = @import("../net/record.zig");
const reference = @import("../net/reference.zig");
const server = @import("../net/server.zig");
const discovery = @import("../net/discovery.zig");
const client = @import("../net/client.zig");
const repos = @import("../data/repos.zig");

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
    device: [64]u8 = undefined,
    device_len: usize = 0,
    role: protocol.DeviceRole = .admin,
    beacon_stop: std.atomic.Value(bool) = .init(false),
}{};

/// The threads `start` owns. The beacon and receiver are optional: a
/// machine that cannot open the discovery sockets still serves and
/// pulls over the manual address.
pub const Threads = struct {
    listener: std.Thread,
    beacon: ?std.Thread = null,
    receiver: ?std.Thread = null,

    pub fn join(self: Threads) void {
        self.listener.join();
        if (self.beacon) |thread| thread.join();
        if (self.receiver) |thread| thread.join();
    }
};

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

/// Start the listener, the beacon sender and the beacon receiver.
/// `main` calls this: it is the one place with an `Io`.
pub fn start(
    io: std.Io,
    bind_host: []const u8,
    port: u16,
    device: []const u8,
    role: protocol.DeviceRole,
) !Threads {
    const len = @min(bind_host.len, shared.bind_host.len);
    @memcpy(shared.bind_host[0..len], bind_host[0..len]);
    shared.bind_host_len = len;

    const device_len = @min(device.len, shared.device.len);
    @memcpy(shared.device[0..device_len], device[0..device_len]);
    shared.device_len = device_len;
    shared.role = role;

    const listener = try std.Thread.spawn(.{}, server.run, .{
        io,
        server.Config{
            .bind_host = shared.bind_host[0..len],
            .port = port,
            .poster = .{ .context = @ptrCast(&shared), .post = post },
        },
        &shared.server_state,
    });

    return .{
        .listener = listener,
        .beacon = std.Thread.spawn(.{}, beaconLoop, .{io}) catch null,
        .receiver = std.Thread.spawn(.{}, receiverLoop, .{io}) catch null,
    };
}

/// Stop the listener and the beacon threads, and wake the listener out
/// of `accept`. Call before joining.
pub fn stop(io: std.Io) void {
    shared.beacon_stop.store(true, .release);
    server.stop(io, &shared.server_state);
}

/// Broadcast this device's hello card every five seconds. The card is
/// rebuilt each time because the listener's port is not known until it
/// binds, and the model's address can change before then.
fn beaconLoop(io: std.Io) void {
    var sender = discovery.openSender(io) catch return;
    defer sender.close(io);

    // Wait for the listener to report the port it actually bound.
    var waited_ms: u32 = 0;
    while (!shared.beacon_stop.load(.acquire) and
        shared.server_state.port.load(.acquire) == 0 and waited_ms < 5_000)
    {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch return;
        waited_ms += 50;
    }
    if (shared.server_state.port.load(.acquire) == 0) return;

    while (!shared.beacon_stop.load(.acquire)) {
        const hello: protocol.Hello = .{
            .device = shared.device[0..shared.device_len],
            .role = shared.role,
            .host = shared.bind_host[0..shared.bind_host_len],
            .tcp = shared.server_state.port.load(.acquire),
            .app_version = app_version,
        };
        discovery.sendBeacon(io, &sender, hello) catch {};

        var slept_ms: u32 = 0;
        while (!shared.beacon_stop.load(.acquire) and slept_ms < 5_000) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return;
            slept_ms += 100;
        }
    }
}

/// Listen for beacons and post each one to the loop thread. A machine
/// whose port is already taken by another app still works: discovery is
/// a convenience, and the manual address is the other path.
fn receiverLoop(io: std.Io) void {
    var socket = discovery.openReceiver(io, protocol.beacon_port) catch return;
    defer socket.close(io);

    var buffer: [discovery.max_beacon_bytes]u8 = undefined;
    while (!shared.beacon_stop.load(.acquire)) {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();

        const heard = discovery.receiveBeacon(
            arena_state.allocator(),
            io,
            &socket,
            &buffer,
            1_000,
        ) catch continue;
        const hello = heard orelse continue;

        var json_buffer: [discovery.max_beacon_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&json_buffer);
        protocol.encodeHello(&writer, hello) catch continue;
        var control_buffer: [discovery.max_beacon_bytes + 32]u8 = undefined;
        const control = server.Control.formatBeacon(&control_buffer, writer.buffered()) catch continue;
        _ = post(@ptrCast(&shared), control);
    }
}

/// Add a manually configured peer. `text` is `host:port`; a malformed
/// value is ignored, because a typo is not a reason to refuse to boot.
pub fn parseManualPeer(model: *Model, text: []const u8) void {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return;
    const host = std.mem.trim(u8, text[0..colon], " ");
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, text[colon + 1 ..], " "), 10) catch return;
    if (host.len == 0) return;
    model.observeManualPeer(host, port, 0);
}

/// The role the beacon carries. It is the device's vocabulary, not the
/// signed-in employee's.
pub fn deviceRole(model: *const Model) protocol.DeviceRole {
    return switch (model.role) {
        .admin => .admin,
        .waiter => .waiter,
        .kds => .kds,
        .display => .display,
    };
}

/// Pull every peer's ops above this device's cursor. The cursor is a
/// vector, so one peer cannot hide another's history behind a clock
/// that happens to be higher.
pub fn poll(model: *Model, fx: *Effects) void {
    for (model.peers[0..model.peer_count], 0..) |peer, index| {
        if (peer.host_len == 0 or peer.tcp == 0) continue;
        var url_buffer: [client.max_url_bytes]u8 = undefined;
        const url = client.formatOps(
            &url_buffer,
            peer.address(),
            peer.tcp,
            &model.sync_cursor,
        ) catch continue;
        fx.fetch(.{
            .key = sync_fetch_key_base + index,
            .url = url,
            .timeout_ms = 2_000,
            .on_response = Effects.responseMsg(.peer),
        });

        // Only the owner publishes reference data, and only the other
        // apps need it. The admin keeps its own menu; a peer asks the
        // admin for what it is missing.
        if (model_mod.app_kind != .admin and peer.role == .admin) {
            var reference_buffer: [client.max_url_bytes]u8 = undefined;
            const reference_url = client.formatReference(
                &reference_buffer,
                peer.address(),
                peer.tcp,
                model.reference_version,
            ) catch continue;
            fx.fetch(.{
                .key = reference_fetch_key_base + index,
                .url = reference_url,
                .timeout_ms = 5_000,
                .on_response = Effects.responseMsg(.reference),
            });
        }
    }
}

/// The fetch keys sit above the database keys and below the channel.
pub const sync_fetch_key_base: u64 = 9200;
pub const reference_fetch_key_base: u64 = 9300;

fn post(context: *anyopaque, bytes: []const u8) bool {
    _ = context;
    return switch (shared.handle.post(bytes)) {
        .accepted => true,
        .dropped_full, .dropped_oversized, .closed => false,
    };
}

/// A message from the net thread.
pub fn onChannel(model: *Model, fx: *Effects, event: native_sdk.EffectChannelEvent) void {
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
                    answer(model, fx, request.conn, request.bytes);
                },
                .beacon => |json| {
                    var arena_buffer: [4096]u8 = undefined;
                    var fba = std.heap.FixedBufferAllocator.init(&arena_buffer);
                    const hello = protocol.decodeHello(fba.allocator(), json) catch return;
                    if (!hello.compatible()) return;
                    model.observePeer(hello, model.now_ms);
                },
            }
        },
        .closed, .rejected => {},
    }
}

/// A peer's answer to a request this app made. The answer is recorded
/// so the seam is visible, and an ops body is decoded and applied one
/// op at a time.
pub fn onResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    model.peer_outcome = @tagName(response.outcome);
    model.peer_status = response.status;
    const len = @min(response.body.len, model.peer_body_buf.len);
    @memcpy(model.peer_body_buf[0..len], response.body[0..len]);
    model.peer_body_len = len;

    if (response.outcome != .ok or response.status != 200) return;
    // The hello card and the POST acknowledgement are JSON objects,
    // not ops. Only a body that carries op records is applied.
    if (std.mem.indexOf(u8, response.body, "\"entity_table\"") == null) return;

    _ = applyOpLines(model, fx, response.body);
}

/// Decode and apply every op in an NDJSON body. One op at a time, with
/// an arena that dies at the end of the iteration: the apply's `dbExec`
/// is synchronous, so the decoded strings are alive for exactly as long
/// as they are needed.
fn applyOpLines(model: *Model, fx: *Effects, body: []const u8) usize {
    var accepted: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var arena_buffer: [16 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buffer);
        const op = record.decode(fba.allocator(), trimmed) catch {
            model.sync_rejected += 1;
            continue;
        };
        repos.applyOp(model, fx, op);
        accepted += 1;
    }
    return accepted;
}

/// A peer's reference document. A 204 means the admin has nothing newer;
/// an unreachable admin is not an error - the peer keeps selling with
/// the rows it has.
pub fn onReferenceResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.outcome != .ok) return;
    if (response.status == 204) return;
    if (response.status != 200 or response.truncated) {
        model.sync_rejected += 1;
        return;
    }

    var arena_buffer: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const arena = fba.allocator();

    const snapshot = reference.parse(arena, response.body) catch {
        model.sync_rejected += 1;
        return;
    };
    if (snapshot.version <= model.reference_version) return;
    if (snapshot.version <= model.reference_applying) return;

    model.reference_applying = snapshot.version;
    repos.applyReference(model, fx, snapshot, arena, fx.wallMs());
}

// --------------------------------------------------------------- answers

fn answer(model: *Model, fx: *Effects, conn: u32, bytes: []const u8) void {
    const split = server.splitBody(bytes);
    const request = server.Request.parse(split.head) orelse return;

    // The body must leave room for the response head inside one frame.
    var body: [server.max_frame_bytes - 256]u8 = undefined;
    var body_len: usize = 0;
    var status: u16 = 200;
    var reason: []const u8 = "OK";
    var content_type: []const u8 = protocol.content_type;

    if (std.mem.eql(u8, request.path, protocol.endpoints.hello)) {
        var writer = std.Io.Writer.fixed(&body);
        protocol.encodeHello(&writer, helloCard(model)) catch return;
        body_len = writer.end;
        content_type = "application/json";
    } else if (std.mem.eql(u8, request.path, protocol.endpoints.reference)) {
        switch (request.method) {
            .get => {
                // A peer that already holds this version is up to date.
                // A peer with nothing is asking for everything.
                const after_text = request.param("after") orelse "0";
                const after = std.fmt.parseInt(u64, after_text, 10) catch 0;
                if (model.reference_snapshot_len == 0 or after >= model.reference_version) {
                    status = 204;
                    reason = "No Content";
                } else {
                    const len = @min(model.reference_snapshot_len, body.len);
                    @memcpy(body[0..len], model.reference_snapshot_buf.bytes[0..len]);
                    body_len = len;
                    content_type = "application/json";
                }
            },
            .post, .other => {
                status = 405;
                reason = "Method Not Allowed";
                const text = "{\"error\":\"method not allowed\"}\n";
                @memcpy(body[0..text.len], text);
                body_len = text.len;
                content_type = "application/json";
            },
        }
    } else if (std.mem.eql(u8, request.path, protocol.endpoints.ops)) {
        switch (request.method) {
            .get => {
                // The recent ops above the requester's cursor. The
                // cursor is a vector, so a peer that has seen a lot
                // from one device still receives another's first op.
                const since = request.param("since") orelse "";
                body_len = repos.writeCachedOps(model, since, &body);
            },
            .post => {
                // A push is applied on the loop thread, in the same
                // transaction path as a local write. The answer counts
                // the ops that were well formed and handed to apply.
                const accepted = applyOpLines(model, fx, split.body);
                const text = std.fmt.bufPrint(&body, "{{\"accepted\":{d}}}\n", .{accepted}) catch return;
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
