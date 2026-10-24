//! The listening half of the wire.
//!
//! A thread owns a TCP socket and nothing else. It reads one HTTP/1.1
//! request, posts it to the app as a message, waits for the app to write
//! an answer into that connection's outbox slot, writes the answer, and
//! closes. The app is the only thing that decides what a request means.
//!
//! That split is the whole design: the thread never touches the model and
//! never touches the database. It moves bytes, and the app stays a pure
//! function of (model, message).
//!
//! The module has no dependency on the SDK - the app supplies a `Poster`
//! and an `Outbox` - so it can be tested against a real socket without an
//! app at all.

const std = @import("std");
const outbox_mod = @import("outbox.zig");
const protocol = @import("protocol.zig");

pub const Outbox = outbox_mod.Outbox;
pub const max_frame_bytes = outbox_mod.max_frame_bytes;

/// How much of a request head (and its body) one connection may send.
pub const max_request_bytes = 16 * 1024;

/// How long the thread waits for the app to answer before giving up on a
/// connection.
pub const answer_timeout_ms: u32 = 5_000;

/// How many event streams one server will hold open at once. Three apps
/// need at most a handful; the cap keeps a peer that reconnects in a
/// loop from growing threads without bound.
pub const max_event_streams: u32 = 8;

/// How often the event thread looks at the shared sequence, and how
/// often it says something on an otherwise quiet stream. The heartbeat
/// is also how a dead client is noticed: a write to a closed socket
/// fails, and the thread exits.
const event_poll_ms: u32 = 20;
const event_heartbeat_ms: u32 = 15_000;

/// The response head for a held-open NDJSON stream. Chunked framing is
/// what lets the body stay open without a `Content-Length`; the SDK's
/// fetch already understands it.
const event_stream_head =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/x-ndjson\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "Connection: keep-alive\r\n\r\n";

pub const Method = enum {
    get,
    post,
    other,

    pub fn label(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .other => "OTHER",
        };
    }
};

/// A parsed request line. `path` has no query; `query` has no `?`.
pub const Request = struct {
    method: Method,
    path: []const u8,
    query: []const u8,

    /// Parse the first line of a request. `head` is the normalised head
    /// the thread posts, so the request line ends at the first '\n'.
    pub fn parse(head: []const u8) ?Request {
        const end = std.mem.indexOfScalar(u8, head, '\n') orelse return null;
        const line = std.mem.trimEnd(u8, head[0..end], "\r");

        var fields = std.mem.splitScalar(u8, line, ' ');
        const method_text = fields.next() orelse return null;
        const target = fields.next() orelse return null;
        _ = fields.next() orelse return null; // the HTTP version

        const method: Method = if (std.mem.eql(u8, method_text, "GET"))
            .get
        else if (std.mem.eql(u8, method_text, "POST"))
            .post
        else
            .other;

        const question = std.mem.indexOfScalar(u8, target, '?');
        return .{
            .method = method,
            .path = if (question) |at| target[0..at] else target,
            .query = if (question) |at| target[at + 1 ..] else "",
        };
    }

    /// Read one query parameter. `?since=dev-1:1042` returns its value.
    pub fn param(self: Request, name: []const u8) ?[]const u8 {
        var pairs = std.mem.splitScalar(u8, self.query, '&');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..equals], name)) return pair[equals + 1 ..];
        }
        return null;
    }
};

/// The split between a request's head and its body. The head the thread
/// posts always ends with the blank line, so the body starts after the
/// first "\n\n".
pub fn splitBody(bytes: []const u8) struct { head: []const u8, body: []const u8 } {
    const at = std.mem.indexOf(u8, bytes, "\n\n") orelse return .{ .head = bytes, .body = "" };
    return .{ .head = bytes[0 .. at + 2], .body = bytes[at + 2 ..] };
}

/// Write the answer bytes for a request.
pub fn formatResponse(
    buffer: []u8,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ status, reason, content_type, body.len, body },
    );
}

// ---------------------------------------------------------------- control

/// The two things the net thread tells the app.
///
/// They are named rather than sniffed: a request that began with
/// "PORT " would otherwise be mistaken for the listener message.
pub const Control = union(enum) {
    listener: struct { host: []const u8, port: u16 },
    request: struct { conn: u32, bytes: []const u8 },
    /// A hello card heard on the UDP beacon, as its JSON line.
    beacon: []const u8,

    pub fn formatListener(buffer: []u8, host: []const u8, port: u16) ![]const u8 {
        return std.fmt.bufPrint(buffer, "PORT {d} {s}\n", .{ port, host });
    }

    pub fn formatRequest(buffer: []u8, conn: u32, bytes: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "CONN {d}\n{s}", .{ conn, bytes });
    }

    pub fn formatBeacon(buffer: []u8, hello_json: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "BEACON {s}\n", .{hello_json});
    }

    pub fn parse(bytes: []const u8) ?Control {
        if (std.mem.startsWith(u8, bytes, "BEACON ")) {
            const json = std.mem.trim(u8, bytes["BEACON ".len..], " \r\n");
            if (json.len == 0) return null;
            return .{ .beacon = json };
        }
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
};

// ----------------------------------------------------------------- server

/// How the thread reaches the app. The app wraps a channel handle; a
/// test wraps a buffer.
pub const Poster = struct {
    context: *anyopaque,
    post: *const fn (context: *anyopaque, bytes: []const u8) bool,
};

pub const Config = struct {
    /// The address to bind. `127.0.0.1` on a development machine, the
    /// LAN address in service. Port 0 lets the kernel choose, and the
    /// chosen port is reported - the same shape the protocol uses.
    bind_host: []const u8,
    port: u16 = 0,
    poster: Poster,
    /// Print the seam's progress. Off in tests.
    verbose: bool = false,
};

/// The state the two threads share. One per server.
pub const Shared = struct {
    outbox: Outbox = .{},
    port: std.atomic.Value(u16) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    bound: std.atomic.Value(bool) = .init(false),
    /// Set by the app once its channel exists. The thread waits for it
    /// before its first message: it cannot post into a channel that does
    /// not exist yet.
    app_ready: std.atomic.Value(bool) = .init(false),
    /// Connections accepted, for the record.
    accepted: std.atomic.Value(u32) = .init(0),
    /// The op log moved. The event threads watch this counter and write
    /// a line when it changes; they do not carry state themselves.
    event_seq: std.atomic.Value(u64) = .init(0),
    /// The event threads currently holding a socket open.
    event_streams: std.atomic.Value(u32) = .init(0),

    /// Wake every held-open event stream. This is a notification, not
    /// the op: a missed line costs the receiver one poll, never an op.
    pub fn notify(self: *Shared) void {
        _ = self.event_seq.fetchAdd(1, .release);
    }
};

/// Run the listener until `Shared.stop` is set.
///
/// Short requests are handled one at a time: the thread reads a request,
/// waits for the answer, writes it and closes before accepting the next.
/// `GET /v1/events` is the exception: it is held open, so it gets its own
/// thread and the listener keeps accepting. That is the whole reason the
/// event stream is a separate path rather than another answer.
pub fn run(io: std.Io, config: Config, shared: *Shared) void {
    var address = std.Io.net.IpAddress.parseIp4(config.bind_host, config.port) catch {
        if (config.verbose) std.debug.print("net: {s} did not parse\n", .{config.bind_host});
        return;
    };
    var listener = std.Io.net.IpAddress.listen(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch {
        if (config.verbose) std.debug.print("net: the listener did not open on {s}\n", .{config.bind_host});
        return;
    };
    defer listener.deinit(io);

    const port = listener.socket.address.getPort();
    shared.port.store(port, .release);
    shared.bound.store(true, .release);

    // The app opens its channel on `boot`, which runs after the app is
    // constructed - and this thread may already be here. Wait for it
    // rather than posting into nothing.
    var waited: u32 = 0;
    while (!shared.app_ready.load(.acquire)) {
        if (shared.stop.load(.acquire)) return;
        if (waited >= 10_000) return;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch return;
        waited += 2;
    }

    var port_line: [128]u8 = undefined;
    const listener_text = Control.formatListener(&port_line, config.bind_host, port) catch return;
    if (!config.poster.post(config.poster.context, listener_text)) return;
    if (config.verbose) std.debug.print("net: listening on {s}:{d}\n", .{ config.bind_host, port });

    var request: [max_request_bytes]u8 = undefined;
    var posted: [max_request_bytes + 32]u8 = undefined;
    var response: [max_frame_bytes]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var conn: u32 = 0;

    while (!shared.stop.load(.acquire)) {
        var stream = listener.accept(io) catch {
            if (shared.stop.load(.acquire)) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch break;
            continue;
        };
        if (shared.stop.load(.acquire)) {
            stream.close(io);
            break;
        }

        // The event thread takes ownership of the socket on the one
        // branch that hands it over; every other branch closes it here.
        var close_stream = true;
        defer {
            if (close_stream) stream.close(io);
        }

        conn +%= 1;
        shared.outbox.clear(conn);
        _ = shared.accepted.fetchAdd(1, .monotonic);

        const bytes = readRequest(io, &stream, &request) orelse continue;

        const split = splitBody(bytes);
        const parsed = Request.parse(split.head) orelse continue;
        if (parsed.method == .get and std.mem.eql(u8, parsed.path, protocol.endpoints.events)) {
            if (shared.event_streams.load(.acquire) >= max_event_streams) {
                refuseEventStream(io, &stream);
                continue;
            }
            _ = shared.event_streams.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{}, streamEvents, .{ io, stream, shared }) catch {
                _ = shared.event_streams.fetchSub(1, .acq_rel);
                continue;
            };
            _ = thread; // the thread closes the socket and decrements the count
            close_stream = false;
            continue;
        }

        const message = Control.formatRequest(&posted, conn, bytes) catch continue;
        if (!config.poster.post(config.poster.context, message)) {
            if (config.verbose) std.debug.print("net: the request was refused\n", .{});
            continue;
        }

        var answered = false;
        var waited_ms: u32 = 0;
        while (waited_ms < answer_timeout_ms) {
            if (shared.stop.load(.acquire)) break;
            if (shared.outbox.read(conn, &response)) |len| {
                if (len > response.len) {
                    if (config.verbose) std.debug.print("net: the answer did not fit\n", .{});
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
        if (!answered and !shared.stop.load(.acquire)) {
            if (config.verbose) std.debug.print("net: no answer within the timeout\n", .{});
        }
    }
}

/// Hold one `/v1/events` connection open and write a line whenever the
/// shared sequence moves.
///
/// The line is deliberately just a notification: `{"seq":N}` says the op
/// log moved, not what it now contains. The receiver pulls the ops from
/// the cursor it holds, so a line that never arrives costs latency and
/// never correctness. Coalescing follows from that: if ten ops land
/// before this thread wakes, it writes the newest sequence once.
fn streamEvents(io: std.Io, stream: std.Io.net.Stream, shared: *Shared) void {
    defer _ = shared.event_streams.fetchSub(1, .acq_rel);
    defer stream.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(event_stream_head) catch return;
    writer.interface.flush() catch return;

    // The first line makes a connection that arrives after an op useful:
    // the receiver polls immediately instead of waiting for the next
    // change.
    var last = shared.event_seq.load(.acquire);
    writeEventChunk(&writer, last) catch return;

    var idle_ms: u32 = 0;
    while (!shared.stop.load(.acquire)) {
        const seq = shared.event_seq.load(.acquire);
        if (seq != last) {
            writeEventChunk(&writer, seq) catch return;
            last = seq;
            idle_ms = 0;
        } else {
            idle_ms += event_poll_ms;
            if (idle_ms >= event_heartbeat_ms) {
                writeChunk(&writer, "{\"heartbeat\":true}\n") catch return;
                idle_ms = 0;
            }
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(event_poll_ms), .awake) catch return;
    }

    // A chunked body ends with a zero-length chunk. The client sees a
    // normal close and the poll path takes over immediately.
    writer.interface.writeAll("0\r\n\r\n") catch {};
    writer.interface.flush() catch {};
}

fn writeEventChunk(writer: anytype, seq: u64) !void {
    var line_buffer: [64]u8 = undefined;
    const line = try protocol.formatEvent(&line_buffer, seq);
    try writeChunk(writer, line);
}

fn writeChunk(writer: anytype, line: []const u8) !void {
    var size_buffer: [24]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buffer, "{x}\r\n", .{line.len});
    try writer.interface.writeAll(size);
    try writer.interface.writeAll(line);
    try writer.interface.writeAll("\r\n");
    try writer.interface.flush();
}

fn refuseEventStream(io: std.Io, stream: *std.Io.net.Stream) void {
    var response_buffer: [512]u8 = undefined;
    const body = "{\"error\":\"too many event streams\"}\n";
    const text = formatResponse(
        &response_buffer,
        503,
        "Service Unavailable",
        "application/json",
        body,
    ) catch return;
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(text) catch return;
    writer.interface.flush() catch {};
}

/// Read a request: the head, plus the body `Content-Length` announces.
///
/// The bytes are copied into `out` because the reader's buffer is
/// scratch. The head ends with the blank line, so a body - if there is
/// one - starts right after it and `splitBody` finds it.
fn readRequest(io: std.Io, stream: *std.Io.net.Stream, out: []u8) ?[]const u8 {
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var total: usize = 0;
    var content_length: usize = 0;
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

        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            content_length = std.fmt.parseInt(
                usize,
                std.mem.trim(u8, trimmed["content-length:".len..], " \t"),
                10,
            ) catch 0;
        }
        if (trimmed.len == 0) break;
    }

    if (content_length > 0) {
        if (total + content_length > out.len) return null;
        const read = reader.interface.readSliceShort(out[total..][0..content_length]) catch return null;
        total += read;
    }
    return out[0..total];
}

/// Wake a listener out of `accept`.
///
/// A flag alone cannot: `accept` blocks, and the thread has to be sitting
/// in it when the app quits. Connecting to the listener is the portable
/// way to make `accept` return.
pub fn wake(io: std.Io, port: u16) void {
    if (port == 0) return;
    var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const stream = std.Io.net.IpAddress.connect(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch return;
    stream.close(io);
}

/// Ask the thread to stop, and make its blocking `accept` return.
///
/// Event streams are detached because they outlive the request loop, so
/// this waits for them to notice the flag and close. The wait is bounded:
/// a client that has stopped reading must not keep the app from quitting.
pub fn stop(io: std.Io, shared: *Shared) void {
    shared.stop.store(true, .release);
    wake(io, shared.port.load(.acquire));

    var waited_ms: u32 = 0;
    while (shared.event_streams.load(.acquire) != 0 and waited_ms < 1_000) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch break;
        waited_ms += 2;
    }
}

// ------------------------------------------------------------------ tests

test "a request line is parsed without guessing" {
    const request = Request.parse("GET /v1/ops?since=dev-1:1042,dev-3:87 HTTP/1.1\r\nHost: x\r\n\r\n").?;
    try std.testing.expectEqual(Method.get, request.method);
    try std.testing.expectEqualStrings("/v1/ops", request.path);
    try std.testing.expectEqualStrings("dev-1:1042,dev-3:87", request.param("since").?);
    try std.testing.expect(request.param("after") == null);

    const post = Request.parse("POST /v1/ops HTTP/1.1\r\n\r\n").?;
    try std.testing.expectEqual(Method.post, post.method);
    try std.testing.expectEqualStrings("", post.query);

    try std.testing.expect(Request.parse("garbage") == null);
}

test "a beacon control carries the hello line unchanged" {
    var buffer: [128]u8 = undefined;
    const hello = "{\"proto\":\"ros/1\",\"device\":\"dev-1\"}";
    const text = try Control.formatBeacon(&buffer, hello);
    const control = Control.parse(text).?;
    try std.testing.expectEqualStrings(hello, control.beacon);
}

test "the body is split from the head the thread posts" {
    const bytes = "POST /v1/ops HTTP/1.1\nContent-Length: 5\n\nhello";
    const split = splitBody(bytes);
    try std.testing.expectEqualStrings("POST /v1/ops HTTP/1.1\nContent-Length: 5\n\n", split.head);
    try std.testing.expectEqualStrings("hello", split.body);

    const head_only = splitBody("GET /v1/hello HTTP/1.1\n\n");
    try std.testing.expectEqualStrings("", head_only.body);
}

test "a response carries its length and closes" {
    var buffer: [512]u8 = undefined;
    const text = try formatResponse(&buffer, 200, "OK", "application/x-ndjson", "{\"a\":1}\n");
    try std.testing.expect(std.mem.startsWith(u8, text, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "Content-Length: 8") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\r\n\r\n{\"a\":1}\n"));
}

/// A test peer: records what the thread posts and answers requests with
/// a canned response. It stands in for the app, so the socket is real
/// and the model is not.
const TestPeer = struct {
    shared: *Shared,
    /// The NDJSON body `/v1/ops` answers with.
    ops: []const u8,
    listener_port: u16 = 0,
    requests: u32 = 0,

    fn post(context: *anyopaque, bytes: []const u8) bool {
        const self: *TestPeer = @ptrCast(@alignCast(context));
        const control = Control.parse(bytes) orelse return false;
        switch (control) {
            .listener => |where| self.listener_port = where.port,
            .beacon => {},
            .request => |request| {
                self.requests += 1;
                const split = splitBody(request.bytes);
                const parsed = Request.parse(split.head) orelse return false;

                const text = switch (parsed.method) {
                    .get => if (std.mem.eql(u8, parsed.path, "/v1/ops"))
                        self.ops
                    else
                        "{\"proto\":\"ros/1\",\"device\":\"probe\",\"role\":\"admin\",\"host\":\"127.0.0.1\",\"tcp\":1}\n",
                    .post => "{\"accepted\":1}\n",
                    .other => "",
                };
                var response: [4096]u8 = undefined;
                const answer = formatResponse(&response, 200, "OK", "application/x-ndjson", text) catch return false;
                return self.shared.outbox.write(request.conn, answer);
            },
        }
        return true;
    }
};

fn startPeer(io: std.Io, shared: *Shared, peer: *TestPeer, ops: []const u8) !std.Thread {
    peer.* = .{ .shared = shared, .ops = ops };
    shared.app_ready.store(true, .release);
    const thread = try std.Thread.spawn(.{}, run, .{
        io,
        Config{
            .bind_host = "127.0.0.1",
            .poster = .{ .context = peer, .post = TestPeer.post },
        },
        shared,
    });
    // The listener reports its port as a message; wait for it to land.
    var waited: u32 = 0;
    while (!shared.bound.load(.acquire) and waited < 4000) : (waited += 2) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch break;
    }
    return thread;
}

fn httpRequest(io: std.Io, port: u16, method: []const u8, target: []const u8, body: []const u8, out: []u8) ![]const u8 {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try std.Io.net.IpAddress.connect(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(io);

    var write_buffer: [2048]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ method, target, body.len, body },
    );
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var total: usize = 0;
    while (total < out.len) {
        const read = try reader.interface.readSliceShort(out[total..]);
        if (read == 0) break;
        total += read;
    }
    return out[0..total];
}

fn readEventHeaders(reader: *std.Io.Reader) !void {
    while (true) {
        const line = try reader.takeDelimiterExclusive('\n');
        reader.toss(1);
        if (std.mem.trimEnd(u8, line, "\r").len == 0) return;
    }
}

/// Read one chunked-body chunk. A zero-length chunk is the terminal and
/// returns an empty slice.
fn readEventChunk(reader: *std.Io.Reader, out: []u8) ![]const u8 {
    const size_line = try reader.takeDelimiterExclusive('\n');
    reader.toss(1);
    const size = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, size_line, "\r"), 16);
    if (size == 0) return out[0..0];
    if (size > out.len) return error.ChunkTooLarge;

    var total: usize = 0;
    while (total < size) {
        const read = try reader.readSliceShort(out[total..size]);
        if (read == 0) return error.EndOfStream;
        total += read;
    }

    // The chunk's trailing CRLF.
    _ = try reader.takeDelimiterExclusive('\n');
    reader.toss(1);
    return out[0..size];
}

fn eventSeq(line: []const u8) ?u64 {
    const key = "\"seq\":";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const start = at + key.len;
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, line[start..end], 10) catch null;
}

test "a real socket: a request goes in and an answer comes out" {
    const io = std.testing.io;
    var shared: Shared = .{};
    var peer: TestPeer = undefined;
    const thread = try startPeer(io, &shared, &peer, "");
    defer {
        stop(io, &shared);
        thread.join();
    }

    const port = shared.port.load(.acquire);
    try std.testing.expect(port != 0);

    var response: [2048]u8 = undefined;
    const text = try httpRequest(io, port, "GET", "/v1/hello", "", &response);
    try std.testing.expect(std.mem.indexOf(u8, text, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"proto\":\"ros/1\"") != null);
    try std.testing.expectEqual(@as(u32, 1), peer.requests);
}

test "two instances exchange an op over a real socket" {
    const io = std.testing.io;
    const order_line =
        \\{"id":"dev-a:10:1","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":10,"device_id":"dev-a","created_at":1,"data":{"status":"pending"}}
    ;

    var a_shared: Shared = .{};
    var b_shared: Shared = .{};
    var a_peer: TestPeer = undefined;
    var b_peer: TestPeer = undefined;
    // A holds one op; B holds none yet.
    const a_thread = try startPeer(io, &a_shared, &a_peer, order_line ++ "\n");
    defer {
        stop(io, &a_shared);
        a_thread.join();
    }
    const b_thread = try startPeer(io, &b_shared, &b_peer, "");
    defer {
        stop(io, &b_shared);
        b_thread.join();
    }

    // B pushes its op to A, and then pulls A's ops with an empty cursor.
    var response: [4096]u8 = undefined;
    const pushed = try httpRequest(io, a_shared.port.load(.acquire), "POST", "/v1/ops", order_line, &response);
    try std.testing.expect(std.mem.indexOf(u8, pushed, "200 OK") != null);

    const pulled = try httpRequest(io, a_shared.port.load(.acquire), "GET", "/v1/ops?since=", "", &response);
    try std.testing.expect(std.mem.indexOf(u8, pulled, "\"id\":\"dev-a:10:1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pulled, "\"logical_clock\":10") != null);
}

test "the event stream is held open, and a normal request still gets through" {
    const io = std.testing.io;
    var shared: Shared = .{};
    var peer: TestPeer = undefined;
    const thread = try startPeer(io, &shared, &peer, "");
    defer {
        stop(io, &shared);
        thread.join();
    }

    const port = shared.port.load(.acquire);
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try std.Io.net.IpAddress.connect(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    try readEventHeaders(&reader.interface);

    var line_buffer: [256]u8 = undefined;
    const first = try readEventChunk(&reader.interface, &line_buffer);
    const first_seq = eventSeq(first) orelse return error.MissingSequence;

    // The listener is still accepting while the stream is open. This is
    // the property the single-connection loop could not offer.
    var response: [2048]u8 = undefined;
    const hello = try httpRequest(io, port, "GET", "/v1/hello", "", &response);
    try std.testing.expect(std.mem.indexOf(u8, hello, "200 OK") != null);
    try std.testing.expectEqual(@as(u32, 1), peer.requests);

    // The app says the op log moved; the held-open stream writes the
    // new sequence without a request from the client. The event thread
    // looks every 20ms; the bound below leaves room for scheduling but
    // still proves the wake is not waiting for a five-second poll.
    const wake_start = std.Io.Clock.awake.now(io);
    shared.notify();
    const second = try readEventChunk(&reader.interface, &line_buffer);
    const wake_elapsed = wake_start.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(wake_elapsed.toMilliseconds() < 250);
    const second_seq = eventSeq(second) orelse return error.MissingSequence;
    try std.testing.expect(second_seq > first_seq);

    // The event request was not posted to the app; it is the stream
    // path, not an answer.
    try std.testing.expectEqual(@as(u32, 1), peer.requests);
    try std.testing.expectEqual(@as(u32, 1), shared.event_streams.load(.acquire));
}
