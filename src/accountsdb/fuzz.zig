const std = @import("std");
const sig = @import("../lib.zig");
const zstd = @import("zstd");

const AccountsDB = sig.accounts_db.AccountsDB;
const Logger = sig.trace.Logger;
const Account = sig.core.Account;
const Slot = sig.core.time.Slot;
const Pubkey = sig.core.pubkey.Pubkey;
const GeyserWriter = sig.geyser.GeyserWriter;
const Hash = sig.core.Hash;
const BankFields = sig.accounts_db.snapshots.BankFields;
const BankHashInfo = sig.accounts_db.snapshots.BankHashInfo;

pub const TrackedAccount = struct {
    pubkey: Pubkey,
    slot: u64,
    data: []u8,

    pub fn random(rand: std.rand.Random, slot: Slot, allocator: std.mem.Allocator) !TrackedAccount {
        return .{
            .pubkey = Pubkey.random(rand),
            .slot = slot,
            .data = try allocator.alloc(u8, 32),
        };
    }

    pub fn deinit(self: *TrackedAccount, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn toAccount(self: *const TrackedAccount, allocator: std.mem.Allocator) !Account {
        return .{
            .lamports = 19,
            .data = try allocator.dupe(u8, self.data),
            .owner = Pubkey.default(),
            .executable = false,
            .rent_epoch = 0,
        };
    }
};

pub fn run(seed: u64, args: *std.process.ArgIterator) !void {
    const maybe_max_actions_string = args.next();
    const maybe_max_actions = blk: {
        if (maybe_max_actions_string) |max_actions_str| {
            break :blk try std.fmt.parseInt(usize, max_actions_str, 10);
        } else {
            break :blk null;
        }
    };

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const logger = Logger.init(gpa, .debug);
    defer logger.deinit();
    logger.spawn();

    const use_disk = rand.boolean();

    var test_data_dir = try std.fs.cwd().makeOpenPath("test_data", .{});
    defer test_data_dir.close();

    const snapshot_dir_name = "accountsdb_fuzz";
    var snapshot_dir = try test_data_dir.makeOpenPath(snapshot_dir_name, .{});
    defer snapshot_dir.close();
    defer {
        // NOTE: sometimes this can take a long time so we print when we start and finish
        std.debug.print("deleting snapshot dir...\n", .{});
        test_data_dir.deleteTreeMinStackSize(snapshot_dir_name) catch |err| {
            std.debug.print("failed to delete snapshot dir ('{s}'): {}\n", .{ sig.utils.fmt.tryRealPath(snapshot_dir, "."), err });
        };
        std.debug.print("deleted snapshot dir\n", .{});
    }
    std.debug.print("use disk: {}\n", .{use_disk});

    // CONTEXT: we need a separate directory to unpack the snapshot
    // generated by the accountsdb that's using the main directory,
    // since otherwise the alternate accountsdb may race with the
    // main one while reading/writing/deleting account files.
    const alternative_snapshot_dir_name = "alt";
    var alternative_snapshot_dir = try snapshot_dir.makeOpenPath(alternative_snapshot_dir_name, .{});
    defer alternative_snapshot_dir.close();

    var last_full_snapshot_validated_slot: Slot = 0;
    var last_inc_snapshot_validated_slot: Slot = 0;

    var accounts_db = try AccountsDB.init(
        gpa,
        logger,
        snapshot_dir,
        .{
            .number_of_index_bins = sig.accounts_db.db.ACCOUNT_INDEX_BINS,
            .use_disk_index = use_disk,
            // TODO: other things we can fuzz (number of bins, ...)
        },
        null,
    );
    defer accounts_db.deinit(true);

    const exit = try gpa.create(std.atomic.Value(bool));
    defer gpa.destroy(exit);
    exit.* = std.atomic.Value(bool).init(false);

    const manager_handle = try std.Thread.spawn(.{}, AccountsDB.runManagerLoop, .{ &accounts_db, AccountsDB.ManagerLoopConfig{
        .exit = exit,
        .slots_per_full_snapshot = 50_000,
        .slots_per_incremental_snapshot = 5_000,
    } });
    errdefer {
        exit.store(true, .monotonic);
        manager_handle.join();
    }

    var tracked_accounts = std.AutoArrayHashMap(Pubkey, TrackedAccount).init(gpa);
    defer tracked_accounts.deinit();
    defer for (tracked_accounts.values()) |*value| {
        value.deinit(gpa);
    };
    try tracked_accounts.ensureTotalCapacity(10_000);

    var random_bank_fields = try BankFields.random(gpa, rand, 1 << 8);
    defer random_bank_fields.deinit(gpa);

    // const random_bank_hash_info = BankHashInfo.random(rand);

    const zstd_compressor = try zstd.Compressor.init(.{});
    defer zstd_compressor.deinit();

    var largest_rooted_slot: Slot = 0;
    var slot: Slot = 0;

    // get/put a bunch of accounts
    while (true) {
        if (maybe_max_actions) |max_actions| {
            if (slot >= max_actions) {
                std.debug.print("reached max actions: {}\n", .{max_actions});
                break;
            }
        }
        defer slot += 1;

        const action = rand.enumValue(enum { put, get });
        switch (action) {
            .put => {
                const N_ACCOUNTS_PER_SLOT = 10;

                var accounts: [N_ACCOUNTS_PER_SLOT]Account = undefined;
                var pubkeys: [N_ACCOUNTS_PER_SLOT]Pubkey = undefined;

                for (&accounts, &pubkeys, 0..) |*account, *pubkey, i| {
                    errdefer for (accounts[0..i]) |prev_account| prev_account.deinit(gpa);

                    var tracked_account = try TrackedAccount.random(rand, slot, gpa);

                    const existing_pubkey = rand.boolean();
                    if (existing_pubkey and tracked_accounts.count() > 0) {
                        const index = rand.intRangeAtMost(usize, 0, tracked_accounts.count() - 1);
                        const key = tracked_accounts.keys()[index];
                        tracked_account.pubkey = key;
                    }

                    account.* = try tracked_account.toAccount(gpa);
                    pubkey.* = tracked_account.pubkey;

                    const r = try tracked_accounts.getOrPut(tracked_account.pubkey);
                    if (r.found_existing) {
                        r.value_ptr.deinit(gpa);
                    }
                    // always overwrite the old slot
                    r.value_ptr.* = tracked_account;
                }
                defer for (accounts) |account| account.deinit(gpa);

                // write to accounts_db
                try accounts_db.putAccountSlice(
                    &accounts,
                    &pubkeys,
                    slot,
                );
            },
            .get => {
                const n_keys = tracked_accounts.count();
                if (n_keys == 0) {
                    continue;
                }
                const index = rand.intRangeAtMost(usize, 0, tracked_accounts.count() - 1);
                const key = tracked_accounts.keys()[index];

                const tracked_account = tracked_accounts.get(key).?;
                var account = try accounts_db.getAccount(&tracked_account.pubkey);
                defer account.deinit(gpa);

                if (!std.mem.eql(u8, tracked_account.data, account.data)) {
                    @panic("found accounts with different data");
                }
            },
        }

        const create_new_root = rand.boolean();
        if (create_new_root) {
            largest_rooted_slot = @min(slot, largest_rooted_slot + 2);
            accounts_db.largest_rooted_slot.store(largest_rooted_slot, .monotonic);
        }

        blk: {
            const allocator = std.heap.page_allocator;

            // holding the lock here means that the snapshot archive wont be deleted
            // since deletion requires a write lock
            const archive_name, const snapshot_info = full: {
                const full_snapshot_info, var full_snapshot_info_lg = accounts_db.latest_full_snapshot_info.readWithLock();
                defer full_snapshot_info_lg.unlock();

                // no snapshot yet
                if (full_snapshot_info.* == null) break :blk;

                const snapshot_info: AccountsDB.FullSnapshotGenerationInfo = full_snapshot_info.*.?;

                // already validated
                if (snapshot_info.slot <= last_full_snapshot_validated_slot) {
                    // check for a non-validated incremental snapshot
                    const maybe_inc_snapshot_info, var inc_snapshot_info_lg = accounts_db.latest_incremental_snapshot_info.readWithLock();
                    defer inc_snapshot_info_lg.unlock();
                    // no snapshot yet
                    if (maybe_inc_snapshot_info.* == null) break :blk;
                    const inc_snapshot_info = maybe_inc_snapshot_info.*.?;
                    // already validated
                    if (inc_snapshot_info.slot <= last_inc_snapshot_validated_slot) break :blk;
                    // if we get here, we have a new incremental snapshot to validate
                }
                last_full_snapshot_validated_slot = snapshot_info.slot;

                const archive_name = sig.accounts_db.snapshots.FullSnapshotFileInfo.snapshotNameStr(.{
                    .hash = snapshot_info.hash,
                    .slot = snapshot_info.slot,
                    .compression = .zstd,
                });

                // now that we have a copy, we can release the lock
                try snapshot_dir.copyFile(archive_name.slice(), alternative_snapshot_dir, archive_name.slice(), .{});
                break :full .{ archive_name, snapshot_info };
            };

            var archive_file = try alternative_snapshot_dir.openFile(archive_name.slice(), .{});
            defer archive_file.close();

            try sig.accounts_db.snapshots.parallelUnpackZstdTarBall(
                allocator,
                .noop,
                archive_file,
                alternative_snapshot_dir,
                5,
                true,
            );

            logger.infof("fuzz[validate]: unpacked full snapshot at slot: {}", .{snapshot_info.slot});
            var snapshot_files = sig.accounts_db.SnapshotFiles{
                .full_snapshot = .{
                    .hash = snapshot_info.hash,
                    .slot = snapshot_info.slot,
                    .compression = .zstd,
                },
                // is populated below
                .incremental_snapshot = null,
            };

            // the same for incremental snapshots
            const inc_result = inc: {
                const maybe_inc_snapshot_info, var inc_snapshot_info_lg = accounts_db.latest_incremental_snapshot_info.readWithLock();
                defer inc_snapshot_info_lg.unlock();
                // no snapshot yet
                if (maybe_inc_snapshot_info.* == null) break :inc null;

                const inc_snapshot_info = maybe_inc_snapshot_info.*.?;

                // already validated
                if (inc_snapshot_info.slot <= last_inc_snapshot_validated_slot) break :inc null;
                last_inc_snapshot_validated_slot = inc_snapshot_info.slot;

                const inc_archive_name = sig.accounts_db.snapshots.IncrementalSnapshotFileInfo.snapshotNameStr(.{
                    .base_slot = inc_snapshot_info.base_slot,
                    .hash = inc_snapshot_info.hash,
                    .slot = inc_snapshot_info.slot,
                    .compression = .zstd,
                });

                // now that we have a copy, we can release the lock
                try snapshot_dir.copyFile(inc_archive_name.slice(), alternative_snapshot_dir, inc_archive_name.slice(), .{});
                break :inc .{ inc_archive_name, inc_snapshot_info };
            };

            if (inc_result) |result| {
                const inc_archive_name, const inc_snapshot_info = result;

                var inc_archive_file = try alternative_snapshot_dir.openFile(inc_archive_name.slice(), .{});
                defer inc_archive_file.close();

                try sig.accounts_db.snapshots.parallelUnpackZstdTarBall(
                    allocator,
                    .noop,
                    inc_archive_file,
                    alternative_snapshot_dir,
                    5,
                    true,
                );
                logger.infof("fuzz[validate]: unpacked inc snapshot at slot: {}", .{inc_snapshot_info.slot});

                snapshot_files.incremental_snapshot = .{
                    .base_slot = inc_snapshot_info.base_slot,
                    .hash = inc_snapshot_info.hash,
                    .slot = inc_snapshot_info.slot,
                    .compression = .zstd,
                };
            }

            var snapshot_fields = try sig.accounts_db.AllSnapshotFields.fromFiles(
                allocator,
                logger,
                alternative_snapshot_dir,
                snapshot_files,
            );
            defer snapshot_fields.deinit(allocator);

            var alt_accounts_db = try AccountsDB.init(std.heap.page_allocator, .noop, alternative_snapshot_dir, accounts_db.config, null);
            defer alt_accounts_db.deinit(true);

            _ = try alt_accounts_db.loadWithDefaults(&snapshot_fields, 1, true);
            const maybe_inc_slot = if (snapshot_files.incremental_snapshot) |inc| inc.slot else null;
            logger.infof("loaded and validated snapshot at slot: {} (and inc snapshot @ slot {any})", .{ snapshot_info.slot, maybe_inc_slot });
        }
    }

    std.debug.print("fuzzing complete\n", .{});
    exit.store(true, .monotonic);
    manager_handle.join();
}
