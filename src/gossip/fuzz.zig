const std = @import("std");
const GossipService = @import("gossip_service.zig").GossipService;
const Logger = @import("../trace/log.zig").Logger;

const crds = @import("crds.zig");
const LegacyContactInfo = crds.LegacyContactInfo;
const AtomicBool = std.atomic.Atomic(bool);

const SocketAddr = @import("net.zig").SocketAddr;
const UdpSocket = @import("zig-network").Socket;

const Pubkey = @import("../core/pubkey.zig").Pubkey;
const get_wallclock = @import("crds.zig").get_wallclock;

const network = @import("zig-network");
const EndPoint = network.EndPoint;
const Packet = @import("packet.zig").Packet;
const PACKET_DATA_SIZE = @import("packet.zig").PACKET_DATA_SIZE;
const NonBlockingChannel = @import("../sync/channel.zig").NonBlockingChannel;

const Thread = std.Thread;
const Tuple = std.meta.Tuple;
const _protocol = @import("protocol.zig");
const Protocol = _protocol.Protocol;
const PruneData = _protocol.PruneData;

const Mux = @import("../sync/mux.zig").Mux;
const RwMux = @import("../sync/mux.zig").RwMux;

const Ping = @import("ping_pong.zig").Ping;
const Pong = @import("ping_pong.zig").Pong;
const bincode = @import("../bincode/bincode.zig");
const CrdsValue = crds.CrdsValue;

const KeyPair = std.crypto.sign.Ed25519.KeyPair;

const _crds_table = @import("../gossip/crds_table.zig");
const CrdsTable = _crds_table.CrdsTable;
const CrdsError = _crds_table.CrdsError;
const HashTimeQueue = _crds_table.HashTimeQueue;
const CRDS_UNIQUE_PUBKEY_CAPACITY = _crds_table.CRDS_UNIQUE_PUBKEY_CAPACITY;

const pull_request = @import("../gossip/pull_request.zig");
const CrdsFilter = pull_request.CrdsFilter;
const MAX_NUM_PULL_REQUESTS = pull_request.MAX_NUM_PULL_REQUESTS;

const pull_response = @import("../gossip/pull_response.zig");
const ActiveSet = @import("../gossip/active_set.zig").ActiveSet;

const Hash = @import("../core/hash.zig").Hash;

const socket_utils = @import("socket_utils.zig");

const PacketChannel = NonBlockingChannel(Packet);
const ProtocolMessage = struct { from_endpoint: EndPoint, message: Protocol };
const ProtocolChannel = NonBlockingChannel(ProtocolMessage);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator(); // use std.testing.allocator to detect leaks

    var logger = Logger.init(gpa.allocator(), .debug);
    defer logger.deinit();
    logger.spawn();

    // setup the gossip service
    var gossip_port: u16 = 9999;
    var gossip_address = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, gossip_port);

    var my_keypair = try KeyPair.create(null);
    var exit = AtomicBool.init(false);

    // setup contact info
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, false);
    var contact_info = LegacyContactInfo.default(my_pubkey);
    contact_info.shred_version = 0;
    contact_info.gossip = gossip_address;

    // start running gossip
    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        gossip_address,
        &exit,
    );
    defer gossip_service.deinit();

    var handle = try std.Thread.spawn(
        .{},
        GossipService.run,
        .{ &gossip_service, logger },
    );
    std.debug.print("gossip service started on port {d}\n", .{gossip_port});

    // setup sending socket
    var fuzz_keypair = try KeyPair.create(null);
    var fuzz_address = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 9998);

    var fuzz_pubkey = Pubkey.fromPublicKey(&fuzz_keypair.public_key, false);
    var fuzz_contact_info = LegacyContactInfo.default(fuzz_pubkey);
    fuzz_contact_info.shred_version = 0;
    fuzz_contact_info.gossip = fuzz_address;

    var gossip_service_fuzzer = try GossipService.init(
        allocator,
        fuzz_contact_info,
        fuzz_keypair,
        fuzz_address,
        &exit,
    );
    defer gossip_service_fuzzer.deinit();
    var fuzz_handle = try std.Thread.spawn(
        .{},
        GossipService.run,
        .{ &gossip_service_fuzzer, logger },
    );

    // blast it
    var packet_buf: [PACKET_DATA_SIZE]u8 = undefined;

    // send ping
    const ping = Protocol{
        .PingMessage = try Ping.init(.{0} ** 32, fuzz_keypair),
    };
    var msg_slice = try bincode.writeToSlice(&packet_buf, ping, bincode.Params{});
    var packet = Packet.init(gossip_address.toEndpoint(), packet_buf, msg_slice.len);
    try gossip_service_fuzzer.responder_channel.send(packet);

    // wait for cancel keyboard input

    // cleanup
    std.debug.print("gossip service exiting\n", .{});
    handle.join();
    fuzz_handle.join();
    exit.store(true, std.atomic.Ordering.Unordered);

    std.debug.print("fuzzing done\n", .{});
}
