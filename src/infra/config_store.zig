const std = @import("std");
const Paths = @import("../platform/paths.zig").Paths;
const Config = @import("../domain/config.zig").Config;
const logger = @import("logger.zig");

pub const ConfigStore = struct {
    pub fn load(allocator: std.mem.Allocator) Config {
        const cfg_dir = Paths.getConfigDir(allocator) catch return .{};
        defer allocator.free(cfg_dir);
        Paths.makeDirs(cfg_dir);

        const cfg_file_path = std.fmt.allocPrint(allocator, "{s}\\config.json", .{cfg_dir}) catch return .{};
        defer allocator.free(cfg_file_path);

        const json_bytes = Paths.readSmallFile(allocator, cfg_file_path, 64 * 1024) catch |err| {
            // Only seed defaults when the file genuinely does not exist yet.
            // A sharing conflict (old process still flushing during relaunch)
            // or any other read failure must NEVER overwrite the user's file.
            if (err == error.FileNotFound) {
                Paths.writeFile(cfg_file_path, Config.default_json) catch {};
            } else {
                logger.warn("Config", "read config failed err={s}, using defaults in memory only", .{@errorName(err)});
            }
            return .{};
        };
        defer allocator.free(json_bytes);

        return Config.loadFromJson(allocator, json_bytes);
    }

    pub fn save(allocator: std.mem.Allocator, config: *const Config) void {
        const cfg_dir = Paths.getConfigDir(allocator) catch return;
        defer allocator.free(cfg_dir);

        const cfg_file_path = std.fmt.allocPrint(allocator, "{s}\\config.json", .{cfg_dir}) catch return;
        defer allocator.free(cfg_file_path);

        const json_content = config.serializeToJson(allocator) catch return;
        defer allocator.free(json_content);

        Paths.writeFile(cfg_file_path, json_content) catch |err| {
            logger.err("Config", "save failed err={s}", .{@errorName(err)});
        };
    }
};
