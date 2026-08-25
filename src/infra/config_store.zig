const std = @import("std");
const Paths = @import("../platform/paths.zig").Paths;
const Config = @import("../domain/config.zig").Config;
const logger = @import("logger.zig");

pub const ConfigStore = struct {
    pub fn load(allocator: std.mem.Allocator) Config {
        const cfg_dir = Paths.getXdgConfigDir(allocator) catch return .{};
        defer allocator.free(cfg_dir);
        Paths.makeDirs(cfg_dir);

        const cfg_file_path = std.fmt.allocPrint(allocator, "{s}\\config.json", .{cfg_dir}) catch return .{};
        defer allocator.free(cfg_file_path);

        const json_bytes = Paths.readSmallFile(allocator, cfg_file_path, 64 * 1024) catch {
            Paths.writeFile(cfg_file_path, Config.default_json) catch {};
            return .{};
        };
        defer allocator.free(json_bytes);

        return Config.loadFromJson(allocator, json_bytes);
    }

    pub fn save(allocator: std.mem.Allocator, config: *const Config) void {
        const cfg_dir = Paths.getXdgConfigDir(allocator) catch return;
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
