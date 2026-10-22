const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const Effects = main.Effects;

/// A fresh effects channel in fake-executor mode: requests are
/// recorded for assertions instead of touching the OS.
fn fakeFx() !Effects {
    var fx = Effects.init(testing.allocator);
    errdefer fx.deinit();
    fx.executor = .fake;
    return fx;
}

/// The outbox is a process-wide singleton, because the net thread and
/// the loop thread both reach it. A test that used a different one
/// would be testing nothing.
fn outbox() *main.Outbox {
    return &main.shared.outbox;
}

test "an answer written for a connection is read back from that connection" {
    const box = outbox();
    box.reset();

    try testing.expect(box.write(1, "answer for one"));
    try testing.expect(box.write(2, "answer for two"));

    var buffer: [64]u8 = undefined;
    const first = box.read(1, &buffer).?;
    try testing.expectEqualStrings("answer for one", buffer[0..first]);
    const second = box.read(2, &buffer).?;
    try testing.expectEqualStrings("answer for two", buffer[0..second]);
}

test "an answer never crosses to another connection" {
    const box = outbox();
    box.reset();

    // Only connection 1 has an answer.
    try testing.expect(box.write(1, "for one"));

    var buffer: [64]u8 = undefined;
    // Connection 2 must see nothing, however long it waits.
    try testing.expectEqual(@as(?usize, null), box.read(2, &buffer));
    try testing.expectEqual(@as(?usize, null), box.read(3, &buffer));
    // And connection 1 still has its own.
    const len = box.read(1, &buffer).?;
    try testing.expectEqualStrings("for one", buffer[0..len]);
}

test "an answer is read once, and a second read finds nothing new" {
    const box = outbox();
    box.reset();

    try testing.expect(box.write(1, "once"));
    var buffer: [64]u8 = undefined;
    const len = box.read(1, &buffer).?;
    try testing.expectEqualStrings("once", buffer[0..len]);
    try testing.expectEqual(@as(?usize, null), box.read(1, &buffer));
}

test "a leftover answer does not reach the connection that reuses its slot" {
    const box = outbox();
    box.reset();

    // Connection 1 writes an answer that nobody ever reads - the
    // shape a timed-out connection leaves behind.
    try testing.expect(box.write(1, "stale"));

    // The slot is reused by connection 1 + max_conns.
    const reused = 1 + main.max_conns;
    box.clear(reused);
    var spare: [64]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), box.read(reused, &spare));
}

test "an answer that does not fit is refused, and the refusal is counted" {
    const box = outbox();
    box.reset();

    const too_big = "x" ** (main.max_frame_bytes + 1);
    try testing.expect(!box.write(1, too_big));
    // The refusal is counted: an answer that vanishes without a
    // number is a bug nobody finds.
    try testing.expectEqual(@as(u32, 1), box.dropped.load(.monotonic));

    // And the connection still has no answer.
    var spare: [64]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), box.read(1, &spare));
}

test "a read that does not fit reports the full length, not a short one" {
    const box = outbox();
    box.reset();

    try testing.expect(box.write(1, "0123456789"));

    // A buffer too small for the answer: the length reported is the
    // answer's real length, so the caller can tell it did not fit
    // rather than writing half a response to the socket.
    var small: [4]u8 = undefined;
    const len = box.read(1, &small).?;
    try testing.expectEqual(@as(usize, 10), len);
}

test "a request from the net thread becomes an HTTP answer in its slot" {
    const box = outbox();
    box.reset();

    var fx = try fakeFx();
    defer fx.deinit();
    var model = main.initialModel();

    // The net thread posts the request and the connection it belongs
    // to, as one message.
    main.update(&model, .{ .net = .{
        .key = main.channel_key,
        .kind = .data,
        .bytes = "CONN 7\nGET /ping HTTP/1.1\nHost: 127.0.0.1\n\n",
    } }, &fx);

    // The app copied the request, because the channel's bytes are drain
    // scratch: valid only for the call that receives them.
    try testing.expectEqualStrings("GET /ping HTTP/1.1\nHost: 127.0.0.1\n\n", model.request_text());
    try testing.expectEqual(@as(u32, 7), model.conn_id);

    // And it answered, into the connection's own slot.
    var buffer: [512]u8 = undefined;
    const len = box.read(7, &buffer).?;
    const answer = buffer[0..len];
    try testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, answer, "Content-Length: 4") != null);
    try testing.expect(std.mem.endsWith(u8, answer, "\r\n\r\npong"));

    // No other connection has an answer.
    try testing.expectEqual(@as(?usize, null), box.read(8, &buffer));
}

test "the port arrives as bytes, and the fetch is issued to it" {
    const box = outbox();
    box.reset();

    var fx = try fakeFx();
    defer fx.deinit();
    var model = main.initialModel();

    // The port is a message like any other: the app learns it from the
    // wire, not from a shared variable.
    main.update(&model, .{ .net = .{
        .key = main.channel_key,
        .kind = .data,
        .bytes = "PORT 45123\n",
    } }, &fx);

    try testing.expectEqual(@as(u16, 45123), model.port);

    // And the fetch went out to that port.
    try testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    const request = fx.pendingFetchAt(0).?;
    try testing.expectEqualStrings("http://127.0.0.1:45123/ping", request.url);
    try testing.expectEqual(main.fetch_key, request.key);

    // A second port message does not start a second fetch: the fetch
    // key is occupied until its answer arrives.
    main.update(&model, .{ .net = .{
        .key = main.channel_key,
        .kind = .data,
        .bytes = "PORT 45124\n",
    } }, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
}

test "the fetch answer is recorded, and a 200 with pong is the seam" {
    const box = outbox();
    box.reset();

    var fx = try fakeFx();
    defer fx.deinit();
    var model = main.initialModel();

    main.update(&model, .{ .fetched = .{
        .key = main.fetch_key,
        .outcome = .ok,
        .status = 200,
        .body = "pong",
    } }, &fx);

    try testing.expect(model.ok);
    try testing.expectEqualStrings("pong", model.body_text());
    try testing.expectEqual(@as(u16, 200), model.status);
    try testing.expectEqualStrings("SEAM OK", model.verdict());
}

test "a failed fetch is not the seam, and says so" {
    const box = outbox();
    box.reset();

    var fx = try fakeFx();
    defer fx.deinit();
    var model = main.initialModel();

    // A connection refused is a real outcome, not a crash: the fetch
    // classified it and the answer came back as a Msg.
    main.update(&model, .{ .fetched = .{
        .key = main.fetch_key,
        .outcome = .connect_failed,
        .status = 0,
    } }, &fx);

    try testing.expect(!model.ok);
    try testing.expectEqualStrings("SEAM FAILED", model.verdict());
}

test "a wrong body is not the seam" {
    const box = outbox();
    box.reset();

    var fx = try fakeFx();
    defer fx.deinit();
    var model = main.initialModel();

    // A 200 that is not the answer we wrote is still a failure: the
    // round trip proved the transport, not the application.
    main.update(&model, .{ .fetched = .{
        .key = main.fetch_key,
        .outcome = .ok,
        .status = 200,
        .body = "nope",
    } }, &fx);

    try testing.expect(!model.ok);
    try testing.expectEqualStrings("SEAM FAILED", model.verdict());
}

test "a listener is woken out of accept by a connection" {
    // The net thread has no exit of its own - it sits in `accept` - so
    // the app's quit path has to make that call return. This is the
    // mechanism, proved on its own: a flag, plus a connection to the
    // listener.
    const io = std.testing.io;

    var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch |err| {
        std.debug.print("the loopback address did not parse: {t}\n", .{err});
        return err;
    };
    var server = std.Io.net.IpAddress.listen(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    }) catch |err| {
        std.debug.print("the listener did not open: {t}\n", .{err});
        return err;
    };
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // The thread under test: accept, and stop when the flag says so.
    var stop = std.atomic.Value(bool).init(false);
    const Stopper = struct {
        fn run(io_: std.Io, srv: *std.Io.net.Server, flag: *std.atomic.Value(bool)) void {
            while (!flag.load(.acquire)) {
                var stream = srv.accept(io_) catch {
                    if (flag.load(.acquire)) break;
                    std.Io.sleep(io_, std.Io.Duration.fromMilliseconds(5), .awake) catch break;
                    continue;
                };
                stream.close(io_);
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Stopper.run, .{ io, &server, &stop });
    var joined = false;
    defer if (!joined) thread.join();

    // The app's quit path: the flag, then the wake-up.
    stop.store(true, .release);
    main.wakeListener(io, port);

    // If the wake-up did not work, the join below would block forever
    // and the test would hang rather than fail - which is the point of
    // running it.
    thread.join();
    joined = true;
}
