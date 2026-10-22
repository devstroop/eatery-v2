//! The seam spike: a net thread that owns a socket, and a loop thread
//! that owns the model.
//!
//! Three claims, and the app proves all three by running for real:
//!
//! 1. a `std.Io.net` listener in a `main` thread accepts a connection
//!    and speaks HTTP/1.1;
//! 2. `fx.fetch` from the same app reaches that listener, and the
//!    response arrives as a `Msg`;
//! 3. bytes posted from the net thread with `ChannelHandle.post`
//!    arrive as a `Msg` payload, and a response written by `update`
//!    reaches the socket.
//!
//! The rule the whole design rests on: **the net thread never touches
//! the model and never touches the database.** It moves bytes. The one
//! piece of state both threads touch is the outbox, and it is a
//! single-producer/single-consumer ring of atomic indices, so
//! `update` never takes a lock and never blocks - which matters,
//! because `update` has no `Io` and therefore no mutex to take.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 760;
const window_height: f32 = 460;

// ------------------------------------------------------------------- shell

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    // The fetch needs it: the spike calls its own listener over http.
    native_sdk.security.permission_network,
};

const shell_views = [_]native_sdk.ShellView{.{
    .label = canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "Spike canvas",
    .accessibility_label = "Net spike",
    .gpu_backend = .metal,
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    .gpu_alpha_mode = .@"opaque",
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Net Spike",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ shared

/// How many bytes one answer carries.
pub const max_frame_bytes = 4096;
/// How many connections may have an answer slot at once.
pub const max_conns = 8;

/// One connection's answer slot.
///
/// The slot is per connection, not a global ring: a frame carries no
/// peer id, so a shared ring would let one peer's answer reach
/// another peer - and a leftover answer from a connection that timed
/// out would be handed to the next connection that reused the slot.
/// Each connection owns a slot instead, and the slot is cleared when
/// the connection is accepted.
pub const Slot = struct {
    len: u16 = 0,
    bytes: [max_frame_bytes]u8 = undefined,
    /// Bumped by the producer once the bytes are written. The consumer
    /// reads it to learn that a new answer is waiting.
    written: std.atomic.Value(u32) = .init(0),
    /// The consumer's last-read counter. Owned by the net thread.
    read: u32 = 0,
};

/// The answers waiting for the net thread.
///
/// The loop thread writes; the net thread reads. Two atomic counters
/// per slot are enough, and they are enough *because* there is exactly
/// one producer and one consumer. A mutex would need an `Io`, and
/// `update` has none: `std.Thread.Mutex` is gone in Zig 0.16 and
/// `std.Io.Mutex` takes the `Io` it locks against.
pub const Outbox = struct {
    slots: [max_conns]Slot = undefined,
    /// Answers the producer could not deliver.
    dropped: std.atomic.Value(u32) = .init(0),

    /// The slot a connection owns. The id is the connection's number
    /// modulo the slot count, so a long-lived app does not need an
    /// unbounded id space.
    pub fn slot(self: *Outbox, conn: u32) *Slot {
        return &self.slots[conn % max_conns];
    }

    /// Write an answer for a connection. False when the answer does
    /// not fit, and the refusal is counted: an answer that vanishes
    /// without a number is a bug nobody finds.
    pub fn write(self: *Outbox, conn: u32, bytes: []const u8) bool {
        if (bytes.len > max_frame_bytes) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        const target = self.slot(conn);
        target.len = @intCast(bytes.len);
        @memcpy(target.bytes[0..bytes.len], bytes);
        _ = target.written.fetchAdd(1, .release);
        return true;
    }

    /// Read the answer for a connection, if a new one is waiting.
    ///
    /// The returned length is the frame's **full** length. A length
    /// larger than `out.len` means the answer did not fit, and the
    /// caller must say so rather than write half a response to the
    /// socket.
    pub fn read(self: *Outbox, conn: u32, out: []u8) ?usize {
        const target = self.slot(conn);
        const written = target.written.load(.acquire);
        if (written == target.read) return null;
        const len = target.len;
        const copied = @min(len, out.len);
        @memcpy(out[0..copied], target.bytes[0..copied]);
        target.read = written;
        return len;
    }

    /// Clear a slot, for a connection that has just been accepted. A
    /// connection starts with no answer waiting.
    pub fn clear(self: *Outbox, conn: u32) void {
        const target = self.slot(conn);
        target.len = 0;
        target.read = target.written.load(.acquire);
    }

    /// Empty every slot. The tests need it: the outbox is a
    /// process-wide singleton because the net thread and the loop
    /// thread both reach it.
    pub fn reset(self: *Outbox) void {
        for (&self.slots) |*entry| {
            entry.len = 0;
            entry.read = entry.written.load(.acquire);
        }
        self.dropped.store(0, .monotonic);
    }
};

/// The state both threads touch. One instance per process.
///
/// It is public because the tests need to reach it: the outbox is
/// process-wide because the net thread and the loop thread both
/// reach it, and a test that used a different outbox would be testing
/// nothing.
pub var shared = struct {
    /// The channel the net thread posts into. The loop thread publishes
    /// it; the net thread waits for it.
    handle: native_sdk.ChannelHandle = .{},
    handle_ready: std.atomic.Value(bool) = .init(false),

    outbox: Outbox = .{},

    /// The port the listener bound, for the record.
    port: std.atomic.Value(u16) = .init(0),
    /// Whether to report the round trip on stdout. The runtime sets it
    /// in `boot`; the tests drive `update` directly and stay quiet, so
    /// a test run's log is not full of expected failures.
    verbose: std.atomic.Value(bool) = .init(false),
}{};

/// The net thread's stop signal.
///
/// `accept` blocks, so a flag alone cannot wake it: the thread has to
/// be sitting in `accept` when the app quits. The main thread sets the
/// flag and then connects to the listener, which is the portable way
/// to make `accept` return.
var stop_requested: std.atomic.Value(bool) = .init(false);

// ------------------------------------------------------------------- model

pub const Msg = union(enum) {
    /// A channel event: bytes the net thread posted, or a terminal.
    net: native_sdk.EffectChannelEvent,
    /// The answer to the fetch this app made to its own listener.
    fetched: native_sdk.EffectResponse,
    /// The tick that paces the spike.
    tick: native_sdk.EffectTimer,

    /// Messages the view never dispatches. The runtime delivers these;
    /// no markup binds them.
    pub const view_unbound = .{ "net", "fetched", "tick" };
};

pub const Model = struct {
    /// The port the net thread bound, learned from the wire.
    port: u16 = 0,
    /// The host it bound, learned from the wire.
    host: [64]u8 = undefined,
    host_len: u16 = 0,
    /// The request the net thread delivered, as text.
    request: [512]u8 = undefined,
    request_len: u16 = 0,
    /// The connection the last request came in on.
    conn_id: u32 = 0,
    /// The status `fx.fetch` reported.
    status: u16 = 0,
    /// The body `fx.fetch` delivered.
    body: [256]u8 = undefined,
    body_len: u16 = 0,
    /// The outcome of the fetch, as the SDK names it.
    outcome: []const u8 = "none",
    /// Whether the round trip completed.
    ok: bool = false,
    /// Whether the fetch has been issued.
    fetch_sent: bool = false,
    /// How many frames the outbox dropped.
    dropped: u32 = 0,

    /// Fields the view never binds directly. Keep this list honest: it
    /// is the boundary between "the model" and the interface.
    pub const view_unbound = .{
        "host",
        "host_len",
        "request",
        "request_len",
        "body",
        "body_len",
        "ok",
        "fetch_sent",
    };

    pub fn host_text(model: *const Model) []const u8 {
        return model.host[0..model.host_len];
    }

    pub fn request_text(model: *const Model) []const u8 {
        return model.request[0..model.request_len];
    }

    pub fn body_text(model: *const Model) []const u8 {
        return model.body[0..model.body_len];
    }

    pub fn verdict(model: *const Model) []const u8 {
        return if (model.ok) "SEAM OK" else "SEAM FAILED";
    }
};

pub const Effects = native_sdk.Effects(Msg);

/// The channel's key on the effects channel.
pub const channel_key: u64 = 1;
/// The fetch's key. Fetches share the key space with channels.
pub const fetch_key: u64 = 2;
/// The ticker's key.
pub const tick_key: u64 = 3;

/// The boot effects: open the channel, publish it to the net thread,
/// and start the ticker that paces the spike.
pub fn boot(_: *Model, fx: *Effects) void {
    // The channel is opened on the loop thread and the handle is
    // published to the net thread, which cannot post into a channel
    // that does not exist yet.
    shared.handle = fx.openChannel(.{
        .key = channel_key,
        .on_event = Effects.channelMsg(.net),
    });
    shared.handle_ready.store(true, .release);
    shared.verbose.store(true, .release);

    fx.startTimer(.{
        .key = tick_key,
        .interval_ms = 100,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .net => |event| onNet(model, event, fx),
        .fetched => |response| onFetched(model, response),
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            // Nothing to do but keep the ticker alive: the fetch is
            // issued the moment the port arrives, and the port arrives
            // as a message.
            model.dropped = shared.outbox.dropped.load(.monotonic);
        },
    }
}

/// What the net thread posted.
const Wire = union(enum) {
    /// Where the listener is: the port it bound and the host it bound
    /// it on. The host travels with the port so the app builds its own
    /// URL from the wire, and never from a second source of truth.
    listener: struct { host: []const u8, port: u16 },
    /// A request, and the connection it belongs to.
    request: struct { conn: u32, bytes: []const u8 },
};

/// Parse what the net thread posted.
///
/// The two kinds are named rather than sniffed: a request that began
/// with "PORT " would otherwise be mistaken for the control message.
fn parseWire(bytes: []const u8) ?Wire {
    if (std.mem.startsWith(u8, bytes, "PORT ")) {
        const rest = bytes["PORT ".len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, rest[0..end], " \r\n"), 10) catch return null;
        const host = std.mem.trim(u8, rest[end + 1 ..], " \r\n");
        if (host.len == 0) return null;
        return .{ .listener = .{ .host = host, .port = port } };
    }
    if (std.mem.startsWith(u8, bytes, "CONN ")) {
        const end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, bytes["CONN ".len..end], " \r"), 10) catch return null;
        return .{ .request = .{ .conn = id, .bytes = bytes[end + 1 ..] } };
    }
    return null;
}

/// A message from the net thread.
fn onNet(model: *Model, event: native_sdk.EffectChannelEvent, fx: *Effects) void {
    switch (event.kind) {
        .data => {
            // The bytes are drain scratch: valid only for this call, so
            // copy what the model keeps.
            const wire = parseWire(event.bytes) orelse return;
            switch (wire) {
                .listener => |where| {
                    model.port = where.port;
                    const len = @min(where.host.len, model.host.len);
                    @memcpy(model.host[0..len], where.host[0..len]);
                    model.host_len = @intCast(len);
                    if (shared.verbose.load(.acquire)) {
                        std.debug.print("SEAM: the net thread bound {s}:{d}\n", .{ model.host_text(), model.port });
                    }
                    if (model.port != 0 and !model.fetch_sent) {
                        model.fetch_sent = true;
                        var url_buf: [160]u8 = undefined;
                        const url = std.fmt.bufPrint(&url_buf, "http://{s}:{d}/ping", .{ model.host_text(), model.port }) catch return;
                        fx.fetch(.{
                            .key = fetch_key,
                            .url = url,
                            .on_response = Effects.responseMsg(.fetched),
                        });
                    }
                },
                .request => |req| {
                    const len = @min(req.bytes.len, model.request.len);
                    @memcpy(model.request[0..len], req.bytes[0..len]);
                    model.request_len = @intCast(len);
                    model.conn_id = req.conn;

                    // The answer. It is built here, in `update`, and
                    // written into the connection's slot for the net
                    // thread to write to the socket. This is the half
                    // the SDK has no effect for: the app to thread
                    // direction. The slot is the connection's, so an
                    // answer can never reach another peer.
                    var response: [256]u8 = undefined;
                    const body = "pong";
                    const text = std.fmt.bufPrint(
                        &response,
                        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                        .{ body.len, body },
                    ) catch return;
                    if (!shared.outbox.write(req.conn, text)) {
                        model.dropped = shared.outbox.dropped.load(.monotonic);
                    }
                },
            }
        },
        .closed, .rejected => {},
    }
}

/// The answer to our own fetch.
fn onFetched(model: *Model, response: native_sdk.EffectResponse) void {
    model.outcome = @tagName(response.outcome);
    model.status = response.status;
    const len = @min(response.body.len, model.body.len);
    @memcpy(model.body[0..len], response.body[0..len]);
    model.body_len = @intCast(len);
    model.ok = response.outcome == .ok and response.status == 200 and
        std.mem.eql(u8, model.body_text(), "pong");
    if (shared.verbose.load(.acquire)) {
        std.debug.print(
            "SEAM: fetch outcome={s} status={d} body=\"{s}\" -> {s}\n",
            .{ model.outcome, model.status, model.body_text(), model.verdict() },
        );
    }
}

// ---------------------------------------------------------------- net thread

/// Post bytes to the app, and say plainly whether they were taken.
fn postBytes(handle: native_sdk.ChannelHandle, bytes: []const u8) bool {
    return switch (handle.post(bytes)) {
        .accepted => true,
        .dropped_full, .dropped_oversized, .closed => false,
    };
}

/// Read an HTTP request head: the request line and the headers, up to
/// the blank line. The bytes are copied into `out` because the
/// reader's buffer is scratch.
fn readRequest(io: std.Io, stream: *std.Io.net.Stream, out: []u8) ?[]const u8 {
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var total: usize = 0;
    while (true) {
        // The delimiter is left in the buffer, so it is tossed after the
        // line is read.
        const line = reader.interface.takeDelimiterExclusive('\n') catch return null;
        reader.interface.toss(1);
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (total + trimmed.len + 2 > out.len) return null;
        @memcpy(out[total..][0..trimmed.len], trimmed);
        total += trimmed.len;
        out[total] = '\n';
        total += 1;
        if (trimmed.len == 0) break;
    }
    return out[0..total];
}

/// The net thread. It owns the socket and nothing else.
fn netThread(io: std.Io, bind_host: []const u8) void {
    // A loopback listener on an ephemeral port: the kernel picks the
    // port and the app is told which one, which is the same shape the
    // real protocol uses - a device advertises the port it bound.
    var address = std.Io.net.IpAddress.parseIp4(bind_host, 0) catch {
        std.debug.print("SEAM: the loopback address did not parse\n", .{});
        return;
    };
    var server = std.Io.net.IpAddress.listen(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch {
        std.debug.print("SEAM: the listener did not open\n", .{});
        return;
    };
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    shared.port.store(port, .release);

    // Wait for the loop thread to publish the channel.
    while (!shared.handle_ready.load(.acquire)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch return;
    }
    const handle = shared.handle;

    // The port, as a message. The app learns the port the way it will
    // learn everything else over the wire: as bytes.
    var port_line: [96]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_line, "PORT {d} {s}\n", .{ port, bind_host }) catch return;
    if (!postBytes(handle, port_text)) {
        std.debug.print("SEAM: the port message was refused\n", .{});
        return;
    }

    // One connection at a time: the spike is about the seam, not about
    // routing several peers at once.
    var request: [2048]u8 = undefined;
    var response: [max_frame_bytes]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var conn: u32 = 0;
    while (!stop_requested.load(.acquire)) {
        var stream = server.accept(io) catch {
            // A stop wakes `accept` by closing the listener from the
            // other side, and the error that comes back is the signal
            // to stop. Any other failure must not spin the CPU.
            if (stop_requested.load(.acquire)) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch break;
            continue;
        };
        defer stream.close(io);
        if (stop_requested.load(.acquire)) break;

        // Every connection gets a number, and the number names the
        // slot its answer goes in. Without it an answer could reach
        // the wrong peer.
        conn +%= 1;
        shared.outbox.clear(conn);

        const head = readRequest(io, &stream, &request) orelse continue;

        // The request and the connection it belongs to, as one message.
        var posted: [2200]u8 = undefined;
        const message = std.fmt.bufPrint(&posted, "CONN {d}\n{s}", .{ conn, head }) catch continue;
        if (!postBytes(handle, message)) {
            std.debug.print("SEAM: the request was refused\n", .{});
            continue;
        }

        // Wait for the app to answer. The app writes the answer into
        // this connection's slot; this thread reads it back and writes
        // it to the socket.
        var answered = false;
        var waited_ms: u32 = 0;
        while (waited_ms < 5000) {
            if (stop_requested.load(.acquire)) break;
            if (shared.outbox.read(conn, &response)) |len| {
                if (len > response.len) {
                    // The answer did not fit. Say so; a half-written
                    // response on the socket is worse than none.
                    std.debug.print("SEAM: the answer did not fit\n", .{});
                    break;
                }
                var writer = stream.writer(io, &write_buffer);
                writer.interface.writeAll(response[0..len]) catch break;
                writer.interface.flush() catch break;
                answered = true;
                break;
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch break;
            waited_ms += 2;
        }
        if (!answered and !stop_requested.load(.acquire)) {
            std.debug.print("SEAM: no answer within the timeout\n", .{});
        }
    }
}

/// Wake a listener out of `accept`.
///
/// A flag alone cannot: `accept` blocks, and the thread has to be
/// sitting in it when the app quits. Connecting to the listener is the
/// portable way to make `accept` return.
pub fn wakeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const stream = std.Io.net.IpAddress.connect(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch return;
    stream.close(io);
}

// -------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// --------------------------------------------------------------------- app

const SpikeApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try SpikeApp.create(std.heap.page_allocator, .{
        .name = "net-spike",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    // The net thread. `main` is the one place with an `Io`, and the
    // socket needs one. The bind address comes from the environment
    // so the LAN path can be exercised without a rebuild: a loopback
    // bind proves the seam, and a LAN bind proves the seam over the
    // network the three apps will actually use.
    const bind_host = init.environ_map.get("ROS_SPIKE_BIND") orelse "127.0.0.1";
    const thread = try std.Thread.spawn(.{}, netThread, .{ init.io, bind_host });
    defer {
        // Stop the net thread before joining it. The thread has no
        // exit of its own - it is in `accept` - so it is woken the way
        // the SDK's own hosts stop a loop: a signal, plus something
        // that makes the blocking call return.
        stop_requested.store(true, .release);
        wakeListener(init.io, shared.port.load(.acquire));
        thread.join();
    }

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "net-spike",
        .window_title = "Net Spike",
        .bundle_id = "dev.native_sdk.net-spike",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
