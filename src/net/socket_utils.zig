const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

const sig = @import("../sig.zig");
const Packet = sig.net.Packet;
const PACKET_DATA_SIZE = sig.net.PACKET_DATA_SIZE;
const Channel = sig.sync.Channel;
const Logger = sig.trace.Logger;
const ExitCondition = sig.sync.ExitCondition;

const UdpSocket = @import("zig-network").Socket;

pub const SOCKET_TIMEOUT_US: usize = 1 * std.time.us_per_s;
pub const PACKETS_PER_BATCH: usize = 64;

// The identifier for the scoped logger used in this file.
const LOG_SCOPE: []const u8 = "socket_utils";

pub fn readSocket(
    socket_: UdpSocket,
    incoming_channel: *Channel(Packet),
    logger_: Logger,
    exit: ExitCondition,
) !void {
    const logger = logger_.withScope(LOG_SCOPE);
    defer {
        exit.afterExit();
        logger.info().log("readSocket loop closed");
    }

    // NOTE: we set to non-blocking to periodically check if we should exit
    var socket = socket_;
    try socket.setReadTimeout(SOCKET_TIMEOUT_US);

    while (exit.shouldRun()) {
        var packet: Packet = Packet.default();
        const recv_meta = socket.receiveFrom(&packet.data) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |e| {
                logger.err().logf("readSocket error: {s}", .{@errorName(e)});
                return e;
            },
        };
        const bytes_read = recv_meta.numberOfBytes;
        if (bytes_read == 0) return error.SocketClosed;
        packet.addr = recv_meta.sender;
        packet.size = bytes_read;
        try incoming_channel.send(packet);
    }
}

pub fn sendSocket(
    socket: UdpSocket,
    outgoing_channel: *Channel(Packet),
    logger_: Logger,
    exit: ExitCondition,
) !void {
    const logger = logger_.withScope(LOG_SCOPE);
    defer {
        // empty the channel
        while (outgoing_channel.tryReceive()) |_| {}
        exit.afterExit();
        logger.debug().log("sendSocket loop closed");
    }

    while (exit.shouldRun()) {
        while (outgoing_channel.tryReceive()) |p| {
            const bytes_sent = socket.sendTo(p.addr, p.data[0..p.size]) catch |e| {
                logger.err().logf("sendSocket error: {s}", .{@errorName(e)});
                continue;
            };
            std.debug.assert(bytes_sent == p.size);
        }
    }
}

/// A thread that is dedicated to either sending or receiving data over a socket.
/// The included channel can be used communicate with that thread.
///
/// The channel only supports one: either sending or receiving, depending how it
/// was initialized. While you *could* send data to the channel for a "receiver"
/// socket, the underlying thread won't actually read the data from the channel.
pub const SocketThread = struct {
    channel: *Channel(Packet),
    exit: *Atomic(bool),
    handle: std.Thread,

    const Self = @This();

    pub fn initSender(
        allocator: Allocator,
        logger: Logger,
        socket: UdpSocket,
        exit: *Atomic(bool),
    ) !Self {
        const channel = try Channel(Packet).create(allocator);
        return .{
            .channel = channel,
            .exit = exit,
            .handle = try std.Thread.spawn(
                .{},
                sendSocket,
                .{ socket, channel, logger, .{ .unordered = exit } },
            ),
        };
    }

    pub fn initReceiver(
        allocator: Allocator,
        logger: Logger,
        socket: UdpSocket,
        exit: *Atomic(bool),
    ) !Self {
        const channel = try Channel(Packet).create(allocator);
        return .{
            .channel = channel,
            .exit = exit,
            .handle = try std.Thread.spawn(
                .{},
                readSocket,
                .{ socket, channel, logger, .{ .unordered = exit } },
            ),
        };
    }

    pub fn deinit(self: Self, allocator: Allocator) void {
        self.handle.join();
        self.channel.deinit();
        allocator.destroy(self.channel);
    }
};

pub const BenchmarkPacketProcessing = struct {
    pub const min_iterations = 1;
    pub const max_iterations = 20;

    pub const BenchmarkArgs = struct {
        n_packets: usize,
        name: []const u8 = "",
    };

    pub const args = [_]BenchmarkArgs{
        BenchmarkArgs{
            .n_packets = 100_000,
            .name = "100k_msgs",
        },
    };

    pub fn benchmarkReadSocket(bench_args: BenchmarkArgs) !sig.time.Duration {
        const n_packets = bench_args.n_packets;
        const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

        var channel = try Channel(Packet).init(allocator);
        defer channel.deinit();

        var socket = try UdpSocket.create(.ipv4, .udp);
        try socket.bindToPort(0);
        try socket.setReadTimeout(std.time.us_per_s); // 1 second

        const to_endpoint = try socket.getLocalEndPoint();

        var exit_flag = std.atomic.Value(bool).init(false);
        const exit_condition = ExitCondition{
            .unordered = &exit_flag,
        };
        var handle = try std.Thread.spawn(
            .{},
            readSocket,
            .{ socket, &channel, .noop, exit_condition },
        );
        defer {
            exit_condition.setExit();
            handle.join();
        }
        var recv_handle = try std.Thread.spawn(
            .{},
            benchmarkChannelRecv,
            .{ &channel, n_packets },
        );

        var prng = std.rand.DefaultPrng.init(0);
        var packet_buf: [PACKET_DATA_SIZE]u8 = undefined;
        var timer = try sig.time.Timer.start();

        // NOTE: send more packets than we need because UDP drops some
        for (1..(n_packets * 2 + 1)) |i| {
            prng.fill(&packet_buf);
            _ = try socket.sendTo(to_endpoint, &packet_buf);

            // 10Kb per second
            // each packet is 1k bytes
            // = 10 packets per second
            if (i % 10 == 0) {
                const elapsed = timer.read();
                if (elapsed.asNanos() < std.time.ns_per_s) {
                    std.time.sleep(std.time.ns_per_s - elapsed.asNanos());
                }
            }
        }

        recv_handle.join();
        return timer.read();
    }
};

pub fn benchmarkChannelRecv(
    channel: *Channel(Packet),
    n_values_to_receive: usize,
) !void {
    var count: usize = 0;
    while (count < n_values_to_receive) {
        if (channel.tryReceive()) |i| {
            std.mem.doNotOptimizeAway(i);
            count += 1;
        }
    }
}

test "benchmark packet processing" {
    _ = try BenchmarkPacketProcessing.benchmarkReadSocket(.{
        .n_packets = 100_000,
    });
}
