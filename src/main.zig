const std = @import("std");
const json = std.json;
const Sha1 = std.crypto.hash.Sha1;
const Md5 = std.crypto.hash.Md5;
const fs = std.Io.Dir;
const process = std.process;
const path = std.fs.path;

const McDir = ".minecraft";
const DownloadBatchSize = 64;
const DownloadParallelism = 32;
const AssetDownloadParallelism = 16;
const ModrinthDownloadParallelism = 8;
const MaxPackEntries: u64 = 100_000;
const MaxPackUncompressedBytes: u64 = 16 * 1024 * 1024 * 1024;
const DefaultNeoForgeMavenUrl = "https://neoforged.forgecdn.net/releases";
const DownloadUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const ModLoader = enum {
    forge,
    neoforge,
    fabric,
};

pub fn main(init: process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const neo_forge_maven_url = init.environ_map.get("NEOFORGED_MAVEN_URL") orelse DefaultNeoForgeMavenUrl;
    try useExistingMinecraftDirectory(allocator, io);
    var args = try process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    const executable = args.next() orelse "zig-mc";
    const first_arg = args.next() orelse {
        printUsage(executable);
        return;
    };
    if (std.mem.eql(u8, first_arg, "--import-pack")) {
        const archive_path = args.next() orelse {
            std.debug.print("用法: {s} --import-pack <整合包.zip> [Minecraft版本] [--forge|--neoforge|--fabric <版本>]\n", .{executable});
            return error.InvalidArguments;
        };
        var minecraft_version: ?[]const u8 = null;
        var loader: ?ModLoader = null;
        var loader_version: ?[]const u8 = null;
        if (args.next()) |argument| {
            if (parseLoaderOption(argument)) |selected_loader| {
                loader = selected_loader;
                loader_version = args.next() orelse {
                    std.debug.print("缺少加载器版本。\n", .{});
                    return error.InvalidArguments;
                };
            } else {
                minecraft_version = argument;
                if (args.next()) |option| {
                    loader = parseLoaderOption(option) orelse {
                        printUsage(executable);
                        return error.InvalidArguments;
                    };
                    loader_version = args.next() orelse {
                        std.debug.print("缺少加载器版本。\n", .{});
                        return error.InvalidArguments;
                    };
                }
            }
        }
        if (args.next() != null) {
            printUsage(executable);
            return error.InvalidArguments;
        }
        try importModpack(allocator, io, archive_path, minecraft_version, loader, loader_version, neo_forge_maven_url);
        return;
    }
    if (std.mem.eql(u8, first_arg, "--list-versions")) {
        if (args.next() != null) return error.InvalidArguments;
        try listInstalledVersions(allocator, io);
        return;
    }
    if (std.mem.eql(u8, first_arg, "--delete-version")) {
        const version_to_delete = args.next() orelse {
            std.debug.print("用法: {s} --delete-version <版本ID>\n", .{executable});
            return error.InvalidArguments;
        };
        if (args.next() != null) return error.InvalidArguments;
        try deleteInstalledVersion(allocator, io, version_to_delete);
        return;
    }
    if (std.mem.eql(u8, first_arg, "--list-mods")) {
        const instance_id = args.next() orelse {
            std.debug.print("用法: {s} --list-mods <加载器实例ID>\n", .{executable});
            return error.InvalidArguments;
        };
        if (args.next() != null) return error.InvalidArguments;
        try listInstanceMods(allocator, io, instance_id);
        return;
    }
    if (std.mem.eql(u8, first_arg, "--install-mod")) {
        const instance_id = args.next() orelse {
            std.debug.print("用法: {s} --install-mod <加载器实例ID> <mod.jar路径>\n", .{executable});
            return error.InvalidArguments;
        };
        const mod_path = args.next() orelse {
            std.debug.print("用法: {s} --install-mod <加载器实例ID> <mod.jar路径>\n", .{executable});
            return error.InvalidArguments;
        };
        if (args.next() != null) return error.InvalidArguments;
        try installInstanceMod(allocator, io, instance_id, mod_path);
        return;
    }
    if (std.mem.eql(u8, first_arg, "--delete-mod")) {
        const instance_id = args.next() orelse {
            std.debug.print("用法: {s} --delete-mod <加载器实例ID> <mod文件名.jar>\n", .{executable});
            return error.InvalidArguments;
        };
        const mod_name = args.next() orelse {
            std.debug.print("用法: {s} --delete-mod <加载器实例ID> <mod文件名.jar>\n", .{executable});
            return error.InvalidArguments;
        };
        if (args.next() != null) return error.InvalidArguments;
        try deleteInstanceMod(allocator, io, instance_id, mod_name);
        return;
    }

    const version_arg = first_arg;
    if (!isValidVersionId(version_arg)) {
        std.debug.print("无效的 Minecraft 版本 ID。\n", .{});
        return error.InvalidVersionId;
    }
    const version_id = try allocator.dupe(u8, version_arg);
    defer allocator.free(version_id);

    const player_name = if (args.next()) |name|
        try allocator.dupe(u8, name)
    else
        try allocator.dupe(u8, "Steve");
    defer allocator.free(player_name);

    var loader: ?ModLoader = null;
    var requested_loader_version: ?[]const u8 = null;
    if (args.next()) |option| {
        loader = parseLoaderOption(option);
        if (loader == null) {
            std.debug.print("未知参数: {s}\n", .{option});
            printUsage(executable);
            return error.InvalidArguments;
        }
        requested_loader_version = args.next();
        if (args.next() != null) {
            printUsage(executable);
            return error.InvalidArguments;
        }
    }
    if (!isValidPlayerName(player_name)) {
        std.debug.print("离线用户名必须为 3 到 16 位英文字母、数字或下划线。\n", .{});
        return error.InvalidPlayerName;
    }
    if (loader == .forge and !isForgeMinecraftSupported(version_id)) {
        std.debug.print("Forge 启动目前支持 Minecraft 1.13 及以上版本；旧版使用不同的启动参数格式。\n", .{});
        return error.UnsupportedForgeVersion;
    }
    if (loader == .neoforge and !isNeoForgeMinecraftSupported(version_id)) {
        std.debug.print("NeoForge 启动目前支持 Minecraft 1.20.1 及以上版本。\n", .{});
        return error.UnsupportedNeoForgeVersion;
    }
    if (requested_loader_version) |loader_version| {
        if (!isValidForgeVersion(loader_version)) {
            std.debug.print("加载器版本只能包含数字、字母、点和连字符。\n", .{});
            return error.InvalidForgeVersion;
        }
    }
    const player_uuid = try offlineUuid(allocator, player_name);
    defer allocator.free(player_uuid);

    std.debug.print("=== Zig 极简 MC 启动器 ===\n", .{});
    std.debug.print("目标版本: {s}\n", .{version_id});
    std.debug.print("离线玩家: {s} ({s})\n", .{ player_name, player_uuid });

    // 先下载并解析目标版本 JSON
    var version_json = try fetchVersionJson(allocator, io, version_id);
    defer version_json.deinit();

    const selected_loader_version: ?[]u8 = if (loader) |selected_loader| blk: {
        break :blk if (requested_loader_version) |value|
            try allocator.dupe(u8, value)
        else switch (selected_loader) {
            .forge => try fetchRecommendedForgeVersion(allocator, io, version_id),
            .neoforge => try fetchRecommendedNeoForgeVersion(allocator, io, version_id, neo_forge_maven_url),
            .fabric => try fetchRecommendedFabricVersion(allocator, io, version_id),
        };
    } else null;
    defer if (selected_loader_version) |value| allocator.free(value);

    const instance_id = try makeLoaderInstanceId(allocator, version_id, loader, selected_loader_version);
    defer allocator.free(instance_id);
    const instance_dir = try path.join(allocator, &.{ McDir, "instances", instance_id });
    defer allocator.free(instance_dir);
    try ensureDir(init.io, instance_dir);

    // Installers may need the vanilla client JAR to build the loader profile.
    std.debug.print("\n[准备] 检查并下载 Client Jar...\n", .{});
    try downloadClientJar(allocator, io, version_id, version_json.value);

    var loader_json: ?json.Parsed(json.Value) = null;
    defer if (loader_json) |*profile| profile.deinit();
    if (loader) |selected_loader| {
        std.debug.print("\n[{s}] 安装 {s} {s}...\n", .{
            loaderName(selected_loader),
            loaderName(selected_loader),
            selected_loader_version.?,
        });
        loader_json = switch (selected_loader) {
            .forge => try installForge(allocator, io, version_id, selected_loader_version.?),
            .neoforge => try installNeoForge(allocator, io, version_id, selected_loader_version.?, neo_forge_maven_url),
            .fabric => try fetchFabricProfile(allocator, io, version_id, selected_loader_version.?),
        };
        const mods_path = try path.join(allocator, &.{ instance_dir, "mods" });
        defer allocator.free(mods_path);
        try ensureDir(io, mods_path);
    }

    // 4. 下载 Libraries
    std.debug.print("\n[1/2] 检查并下载 Libraries...\n", .{});
    try downloadLibraries(allocator, io, version_json.value, neo_forge_maven_url);
    if (loader_json) |profile| try downloadLibraries(allocator, io, profile.value, neo_forge_maven_url);

    // 5. 下载 Assets
    std.debug.print("\n[2/2] 检查并下载 Assets...\n", .{});
    try downloadAssets(allocator, io, instance_dir, version_json.value);

    // 6. 启动游戏
    std.debug.print("\n[启动] 正在构建 JVM 参数并启动游戏...\n", .{});
    try launchGame(allocator, io, version_id, instance_dir, player_name, player_uuid, version_json.value, if (loader_json) |profile| profile.value else null);
}

fn useExistingMinecraftDirectory(allocator: std.mem.Allocator, io: std.Io) !void {
    var candidate = try process.currentPathAlloc(io, allocator);
    errdefer allocator.free(candidate);

    while (true) {
        const minecraft_dir = try path.join(allocator, &.{ candidate, McDir });
        const directory = fs.cwd().openDir(io, minecraft_dir, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
        allocator.free(minecraft_dir);
        if (directory) |dir| {
            dir.close(io);
            try process.setCurrentPath(io, candidate);
            allocator.free(candidate);
            return;
        }

        const parent = path.dirname(candidate) orelse {
            allocator.free(candidate);
            return;
        };
        if (std.mem.eql(u8, parent, candidate)) {
            allocator.free(candidate);
            return;
        }
        const parent_copy = try allocator.dupeZ(u8, parent);
        allocator.free(candidate);
        candidate = parent_copy;
    }
}

fn isValidPlayerName(name: []const u8) bool {
    if (name.len < 3 or name.len > 16) return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return true;
}

fn printUsage(executable: []const u8) void {
    std.debug.print(
        \\用法:
        \\  {s} <版本号> [离线用户名] [--forge [版本] | --neoforge [版本] | --fabric [版本]]
        \\  {s} --import-pack <整合包.zip> [Minecraft版本] [--forge|--neoforge|--fabric <版本>]
        \\  {s} --list-versions
        \\  {s} --delete-version <版本ID>
        \\  {s} --list-mods <加载器实例ID>
        \\  {s} --install-mod <加载器实例ID> <mod.jar路径>
        \\  {s} --delete-mod <加载器实例ID> <mod文件名.jar>
        \\每个版本的数据保存在 .minecraft/instances/<版本ID> 中。
        \\mod 存放在各加载器实例独立的 mods 目录中。
        \\Forge 支持范围: Minecraft 1.13+（仅限 Forge 官方发布的版本）
        \\NeoForge 支持范围: Minecraft 1.20.1+
        \\Fabric 支持 Fabric Loader 官方元数据提供的 Minecraft 版本。
        \\整合包支持 .zip 目录包及 CurseForge、MultiMC、Modrinth 清单。
        \\示例: {s} 1.20.1 Steve --neoforge 21.1.172
        \\
    , .{ executable, executable, executable, executable, executable, executable, executable, executable });
}

fn parseLoaderOption(option: []const u8) ?ModLoader {
    if (std.mem.eql(u8, option, "--forge")) return .forge;
    if (std.mem.eql(u8, option, "--neoforge")) return .neoforge;
    if (std.mem.eql(u8, option, "--fabric")) return .fabric;
    return null;
}

fn loaderName(loader: ModLoader) []const u8 {
    return switch (loader) {
        .forge => "Forge",
        .neoforge => "NeoForge",
        .fabric => "Fabric",
    };
}

fn loaderIdSegment(loader: ModLoader) []const u8 {
    return switch (loader) {
        .forge => "forge",
        .neoforge => "neoforge",
        .fabric => "fabric",
    };
}

const PackMetadata = struct {
    minecraft_version: ?[]u8 = null,
    loader: ?ModLoader = null,
    loader_version: ?[]u8 = null,
    unsupported_loader: ?[]u8 = null,
    has_external_files: bool = false,
    has_curseforge_external_files: bool = false,

    fn deinit(self: *PackMetadata, allocator: std.mem.Allocator) void {
        if (self.minecraft_version) |value| allocator.free(value);
        if (self.loader_version) |value| allocator.free(value);
        if (self.unsupported_loader) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn setUnsupportedLoader(allocator: std.mem.Allocator, metadata: *PackMetadata, loader: []const u8) !void {
    try replacePackString(allocator, &metadata.unsupported_loader, loader);
}

fn replacePackString(allocator: std.mem.Allocator, field: *?[]u8, value: []const u8) !void {
    if (field.*) |previous| {
        allocator.free(previous);
        field.* = null;
    }
    field.* = try allocator.dupe(u8, value);
}

fn parseCurseForgeMetadata(allocator: std.mem.Allocator, value: json.Value) !PackMetadata {
    if (value != .object) return error.InvalidPackManifest;
    var metadata: PackMetadata = .{};
    errdefer metadata.deinit(allocator);

    const minecraft = value.object.get("minecraft") orelse return metadata;
    if (minecraft != .object) return error.InvalidPackManifest;
    if (minecraft.object.get("version")) |version| {
        if (version != .string or !isValidVersionId(version.string)) return error.InvalidPackManifest;
        metadata.minecraft_version = try allocator.dupe(u8, version.string);
    }
    if (minecraft.object.get("modLoaders")) |loaders| {
        if (loaders != .array) return error.InvalidPackManifest;
        for (loaders.array.items) |loader_entry| {
            if (loader_entry != .object) return error.InvalidPackManifest;
            const id = loader_entry.object.get("id") orelse return error.InvalidPackManifest;
            if (id != .string) return error.InvalidPackManifest;
            if (std.mem.startsWith(u8, id.string, "forge-") or
                std.mem.startsWith(u8, id.string, "neoforge-") or
                std.mem.startsWith(u8, id.string, "fabric-"))
            {
                const selected_loader: ModLoader = if (std.mem.startsWith(u8, id.string, "forge-"))
                    .forge
                else if (std.mem.startsWith(u8, id.string, "neoforge-"))
                    .neoforge
                else
                    .fabric;
                const prefix = switch (selected_loader) {
                    .forge => "forge-",
                    .neoforge => "neoforge-",
                    .fabric => "fabric-",
                };
                const version = id.string[prefix.len..];
                if (!isValidForgeVersion(version)) return error.InvalidPackManifest;
                metadata.loader = selected_loader;
                try replacePackString(allocator, &metadata.loader_version, version);
            } else if (std.mem.startsWith(u8, id.string, "quilt-")) {
                try setUnsupportedLoader(allocator, &metadata, id.string);
            } else {
                try setUnsupportedLoader(allocator, &metadata, id.string);
            }
        }
    }
    if (value.object.get("files")) |files| {
        if (files != .array) return error.InvalidPackManifest;
        metadata.has_external_files = files.array.items.len > 0;
        metadata.has_curseforge_external_files = metadata.has_external_files;
    }
    return metadata;
}

fn parseMmcPackMetadata(allocator: std.mem.Allocator, value: json.Value) !PackMetadata {
    if (value != .object) return error.InvalidPackManifest;
    var metadata: PackMetadata = .{};
    errdefer metadata.deinit(allocator);

    const components = value.object.get("components") orelse return metadata;
    if (components != .array) return error.InvalidPackManifest;
    for (components.array.items) |component| {
        if (component != .object) return error.InvalidPackManifest;
        const uid = component.object.get("uid") orelse continue;
        const version = component.object.get("version") orelse continue;
        if (uid != .string or version != .string) return error.InvalidPackManifest;
        if (std.mem.eql(u8, uid.string, "net.minecraft")) {
            if (!isValidVersionId(version.string)) return error.InvalidPackManifest;
            try replacePackString(allocator, &metadata.minecraft_version, version.string);
        } else if (std.mem.eql(u8, uid.string, "net.minecraftforge") or
            std.mem.eql(u8, uid.string, "net.neoforged") or
            std.mem.eql(u8, uid.string, "net.fabricmc.fabric-loader"))
        {
            if (!isValidForgeVersion(version.string)) return error.InvalidPackManifest;
            metadata.loader = if (std.mem.eql(u8, uid.string, "net.minecraftforge"))
                .forge
            else if (std.mem.eql(u8, uid.string, "net.neoforged"))
                .neoforge
            else
                .fabric;
            try replacePackString(allocator, &metadata.loader_version, version.string);
        } else if (std.mem.eql(u8, uid.string, "org.quiltmc.quilt-loader")) {
            try setUnsupportedLoader(allocator, &metadata, uid.string);
        }
    }
    return metadata;
}

fn parseModrinthMetadata(allocator: std.mem.Allocator, value: json.Value) !PackMetadata {
    if (value != .object) return error.InvalidPackManifest;
    var metadata: PackMetadata = .{};
    errdefer metadata.deinit(allocator);

    const dependencies = value.object.get("dependencies") orelse return metadata;
    if (dependencies != .object) return error.InvalidPackManifest;
    if (dependencies.object.get("minecraft")) |version| {
        if (version != .string or !isValidVersionId(version.string)) return error.InvalidPackManifest;
        try replacePackString(allocator, &metadata.minecraft_version, version.string);
    }
    if (dependencies.object.get("forge")) |version| {
        if (version != .string or !isValidForgeVersion(version.string)) return error.InvalidPackManifest;
        metadata.loader = .forge;
        try replacePackString(allocator, &metadata.loader_version, version.string);
    } else if (dependencies.object.get("neoforge")) |version| {
        if (version != .string or !isValidForgeVersion(version.string)) return error.InvalidPackManifest;
        metadata.loader = .neoforge;
        try replacePackString(allocator, &metadata.loader_version, version.string);
    } else if (dependencies.object.get("fabric")) |version| {
        if (version != .string or !isValidForgeVersion(version.string)) return error.InvalidPackManifest;
        metadata.loader = .fabric;
        try replacePackString(allocator, &metadata.loader_version, version.string);
    }
    if (dependencies.object.get("quilt")) |version| {
        if (version != .string) return error.InvalidPackManifest;
        try setUnsupportedLoader(allocator, &metadata, "quilt");
    }
    if (value.object.get("files")) |files| {
        if (files != .array) return error.InvalidPackManifest;
        metadata.has_external_files = files.array.items.len > 0;
    }
    return metadata;
}

fn readPackJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    filename: []const u8,
) !?json.Parsed(json.Value) {
    const file_path = try path.join(allocator, &.{ root, filename });
    defer allocator.free(file_path);
    const contents = fs.cwd().readFileAlloc(io, file_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(contents);
    return try json.parseFromSlice(json.Value, allocator, contents, .{});
}

fn isSafeModrinthPackPath(pack_path: []const u8) bool {
    if (pack_path.len == 0 or pack_path[0] == '/' or pack_path[pack_path.len - 1] == '/') return false;
    var segments = std.mem.splitScalar(u8, pack_path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |char| {
            if (char == '\\' or char == ':' or char == 0 or char < 0x20) return false;
        }
    }
    return true;
}

fn isValidModrinthDownloadUrl(url: []const u8) bool {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return false;
    const authority = url[scheme.len..];
    var authority_end: usize = 0;
    while (authority_end < authority.len and authority[authority_end] != '/' and authority[authority_end] != '?' and authority[authority_end] != '#') : (authority_end += 1) {
        const char = authority[authority_end];
        if (char == '@' or char == '\\' or char <= 0x20 or char == 0x7f) return false;
    }
    return authority_end > 0;
}

fn chooseModrinthDownloadUrl(downloads: json.Value) ![]const u8 {
    if (downloads != .array) return error.InvalidPackManifest;
    var first_valid: ?[]const u8 = null;
    for (downloads.array.items) |entry| {
        if (entry != .string or !isValidModrinthDownloadUrl(entry.string)) continue;
        if (first_valid == null) first_valid = entry.string;
        if (std.mem.startsWith(u8, entry.string, "https://cdn.modrinth.com/")) return entry.string;
    }
    return first_valid orelse error.InvalidPackDownloadUrl;
}

fn shouldDownloadModrinthClientFile(file: json.Value) !bool {
    if (file != .object) return error.InvalidPackManifest;
    const env = file.object.get("env") orelse return true;
    if (env != .object) return error.InvalidPackManifest;
    const client = env.object.get("client") orelse return true;
    if (client != .string) return error.InvalidPackManifest;
    if (std.mem.eql(u8, client.string, "unsupported")) return false;
    if (std.mem.eql(u8, client.string, "required") or std.mem.eql(u8, client.string, "optional")) return true;
    return error.InvalidPackManifest;
}

fn isValidSha1Hex(value: []const u8) bool {
    if (value.len != Sha1.digest_length * 2) return false;
    for (value) |char| {
        if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f') and !(char >= 'A' and char <= 'F')) return false;
    }
    return true;
}

fn downloadModrinthPackFiles(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const manifest = (try readPackJson(allocator, io, root, "modrinth.index.json")) orelse return;
    defer manifest.deinit();
    if (manifest.value != .object) return error.InvalidPackManifest;
    const files_value = manifest.value.object.get("files") orelse return error.InvalidPackManifest;
    if (files_value != .array) return error.InvalidPackManifest;
    if (files_value.array.items.len > MaxPackEntries) return error.PackHasTooManyEntries;

    var pending: std.ArrayList(DownloadItem) = .empty;
    defer freePendingDownloads(allocator, &pending);
    var client_file_count: usize = 0;
    for (files_value.array.items) |entry| {
        if (!try shouldDownloadModrinthClientFile(entry)) continue;
        const file_path_value = entry.object.get("path") orelse return error.InvalidPackManifest;
        if (file_path_value != .string or !isSafeModrinthPackPath(file_path_value.string)) return error.InvalidPackPath;

        const hashes = entry.object.get("hashes") orelse return error.InvalidPackManifest;
        if (hashes != .object) return error.InvalidPackManifest;
        const sha1_value = hashes.object.get("sha1") orelse return error.InvalidPackManifest;
        if (sha1_value != .string or !isValidSha1Hex(sha1_value.string)) return error.InvalidPackManifest;

        const downloads = entry.object.get("downloads") orelse return error.InvalidPackManifest;
        const download_url = try chooseModrinthDownloadUrl(downloads);
        const local_path = try path.join(allocator, &.{ root, file_path_value.string });
        defer allocator.free(local_path);

        if (fs.cwd().access(io, local_path, .{})) |_| {
            if (!try verifySha1(io, local_path, sha1_value.string)) {
                std.debug.print("整合包已包含文件，但 SHA-1 与 Modrinth 清单不符: {s}\n", .{file_path_value.string});
                return error.PackFileHashMismatch;
            }
        } else |err| switch (err) {
            error.FileNotFound => try queueDownload(allocator, io, &pending, download_url, local_path, sha1_value.string),
            else => return err,
        }
        client_file_count += 1;
    }

    std.debug.print("Modrinth 客户端文件: {}，待下载: {}，并发数: {}\n", .{
        client_file_count,
        pending.items.len,
        ModrinthDownloadParallelism,
    });
    try downloadPending(allocator, io, pending.items, ModrinthDownloadParallelism);
}

fn detectPackMetadata(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !PackMetadata {
    var metadata: PackMetadata = .{};
    errdefer metadata.deinit(allocator);

    if (try readPackJson(allocator, io, root, "manifest.json")) |manifest| {
        defer manifest.deinit();
        metadata = try parseCurseForgeMetadata(allocator, manifest.value);
    }
    if (try readPackJson(allocator, io, root, "mmc-pack.json")) |manifest| {
        defer manifest.deinit();
        var detected = try parseMmcPackMetadata(allocator, manifest.value);
        defer detected.deinit(allocator);
        if (metadata.minecraft_version == null) {
            metadata.minecraft_version = detected.minecraft_version;
            detected.minecraft_version = null;
        }
        if (metadata.loader_version == null) {
            metadata.loader = detected.loader;
            metadata.loader_version = detected.loader_version;
            detected.loader_version = null;
        }
        if (detected.unsupported_loader) |loader| {
            try setUnsupportedLoader(allocator, &metadata, loader);
        }
        metadata.has_external_files = metadata.has_external_files or detected.has_external_files;
        metadata.has_curseforge_external_files = metadata.has_curseforge_external_files or detected.has_curseforge_external_files;
    }
    if (try readPackJson(allocator, io, root, "modrinth.index.json")) |manifest| {
        defer manifest.deinit();
        var detected = try parseModrinthMetadata(allocator, manifest.value);
        defer detected.deinit(allocator);
        if (metadata.minecraft_version == null) {
            metadata.minecraft_version = detected.minecraft_version;
            detected.minecraft_version = null;
        }
        if (metadata.loader_version == null) {
            metadata.loader = detected.loader;
            metadata.loader_version = detected.loader_version;
            detected.loader_version = null;
        }
        if (detected.unsupported_loader) |loader| {
            try setUnsupportedLoader(allocator, &metadata, loader);
        }
        metadata.has_external_files = metadata.has_external_files or detected.has_external_files;
        metadata.has_curseforge_external_files = metadata.has_curseforge_external_files or detected.has_curseforge_external_files;
    }
    return metadata;
}

fn findSingleTopLevelDirectory(allocator: std.mem.Allocator, io: std.Io, directory_path: []const u8) !?[]u8 {
    const directory = try fs.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);

    var iterator = directory.iterate();
    var only_directory: ?[]u8 = null;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory or only_directory != null) {
            if (only_directory) |name| allocator.free(name);
            return null;
        }
        if (isPackContentDirectory(entry.name)) return null;
        only_directory = try allocator.dupe(u8, entry.name);
    }
    return only_directory;
}

fn isPackContentDirectory(name: []const u8) bool {
    const content_directories = [_][]const u8{
        "mods", "config", "resourcepacks", "shaderpacks", "scripts", "kubejs", "saves",
    };
    for (content_directories) |directory| {
        if (std.mem.eql(u8, name, directory)) return true;
    }
    return false;
}

fn moveDirectoryContents(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    const source_dir = try fs.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        names.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
    }
    for (names.items) |name| {
        const source = try path.join(allocator, &.{ source_path, name });
        defer allocator.free(source);
        const destination = try path.join(allocator, &.{ destination_path, name });
        defer allocator.free(destination);
        if (fs.cwd().access(io, destination, .{})) |_| {
            return error.PackPathCollision;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try fs.cwd().rename(source, fs.cwd(), destination, io);
    }
}

fn hasAnyPackContent(allocator: std.mem.Allocator, io: std.Io, instance_path: []const u8) !bool {
    const expected = [_][]const u8{
        "mods",        "config",      "resourcepacks", "shaderpacks", "scripts", "kubejs", "saves",
        "options.txt", "servers.dat",
    };
    for (expected) |name| {
        const candidate = try path.join(allocator, &.{ instance_path, name });
        defer allocator.free(candidate);
        if (fs.cwd().access(io, candidate, .{})) |_| {
            return true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    return false;
}

fn validatePackArchive(reader: *std.Io.File.Reader) !void {
    var iterator = try std.zip.Iterator.init(reader);
    var entry_count: u64 = 0;
    var total_uncompressed: u64 = 0;
    while (try iterator.next()) |entry| {
        entry_count += 1;
        if (entry_count > MaxPackEntries) return error.PackHasTooManyEntries;
        if (entry.uncompressed_size > MaxPackUncompressedBytes - total_uncompressed) {
            return error.PackTooLarge;
        }
        total_uncompressed += entry.uncompressed_size;
    }
    try reader.seekTo(0);
}

fn importModpack(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    requested_version: ?[]const u8,
    requested_loader: ?ModLoader,
    requested_loader_version: ?[]const u8,
    neo_forge_maven_url: []const u8,
) !void {
    if (requested_version) |version| {
        if (!isValidVersionId(version)) {
            std.debug.print("无效 Minecraft 版本 ID。\n", .{});
            return error.InvalidVersionId;
        }
    }
    if (requested_loader_version) |version| {
        if (!isValidForgeVersion(version)) {
            std.debug.print("Forge 版本只能包含数字、字母、点和连字符。\n", .{});
            return error.InvalidForgeVersion;
        }
    }

    const instances_path = try path.join(allocator, &.{ McDir, "instances" });
    defer allocator.free(instances_path);
    try ensureDir(io, instances_path);

    const stage_id = try std.fmt.allocPrint(allocator, ".import-{x}", .{std.hash.Wyhash.hash(0, archive_path)});
    defer allocator.free(stage_id);
    const staging_path = try path.join(allocator, &.{ instances_path, stage_id });
    defer allocator.free(staging_path);
    if (fs.cwd().access(io, staging_path, .{})) |_| {
        std.debug.print("发现同名未完成的导入目录，请先检查并移除: {s}\n", .{staging_path});
        return error.ImportAlreadyInProgress;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try ensureDir(io, staging_path);
    var staging_exists = true;
    defer if (staging_exists) {
        _ = deleteDirectoryIfExists(io, staging_path) catch |err| {
            std.debug.print("清理整合包临时目录失败: {s}\n", .{@errorName(err)});
        };
    };

    const archive = fs.cwd().openFile(io, archive_path, .{}) catch |err| {
        std.debug.print("无法打开整合包 ZIP {s}: {s}\n", .{ archive_path, @errorName(err) });
        return err;
    };
    defer archive.close(io);
    var zip_buffer: [4096]u8 = undefined;
    var zip_reader = archive.reader(io, &zip_buffer);
    try validatePackArchive(&zip_reader);
    const staging_dir = try fs.cwd().openDir(io, staging_path, .{});
    defer staging_dir.close(io);
    std.zip.extract(staging_dir, &zip_reader, .{}) catch |err| {
        std.debug.print("整合包 ZIP 解压失败: {s}\n", .{@errorName(err)});
        return err;
    };

    if (try findSingleTopLevelDirectory(allocator, io, staging_path)) |wrapper| {
        defer allocator.free(wrapper);
        const wrapper_path = try path.join(allocator, &.{ staging_path, wrapper });
        defer allocator.free(wrapper_path);
        try moveDirectoryContents(allocator, io, wrapper_path, staging_path);
        _ = try deleteDirectoryIfExists(io, wrapper_path);
    }

    const overrides_path = try path.join(allocator, &.{ staging_path, "overrides" });
    defer allocator.free(overrides_path);
    if (fs.cwd().openDir(io, overrides_path, .{})) |overrides_dir| {
        overrides_dir.close(io);
        try moveDirectoryContents(allocator, io, overrides_path, staging_path);
        _ = try deleteDirectoryIfExists(io, overrides_path);
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    var metadata = try detectPackMetadata(allocator, io, staging_path);
    defer metadata.deinit(allocator);
    if (metadata.unsupported_loader) |loader| {
        std.debug.print("该整合包使用 {s}，当前启动器仅支持 Vanilla/Forge/NeoForge/Fabric；已取消导入。\n", .{loader});
        return error.UnsupportedPackLoader;
    }
    const minecraft_version = requested_version orelse metadata.minecraft_version orelse {
        std.debug.print("未能从 ZIP 清单识别 Minecraft 版本。请补充版本后重试：\n  zig-mc --import-pack \"{s}\" <Minecraft版本>\n", .{archive_path});
        return error.PackMinecraftVersionRequired;
    };
    if (metadata.minecraft_version) |detected_version| {
        if (requested_version != null and !std.mem.eql(u8, requested_version.?, detected_version)) {
            std.debug.print("提示：使用指定版本 {s}（ZIP 清单版本为 {s}）。\n", .{ minecraft_version, detected_version });
        }
    }

    const selected_loader = requested_loader orelse metadata.loader;
    if (selected_loader == .forge and !isForgeMinecraftSupported(minecraft_version)) {
        std.debug.print("Forge 整合包目前要求 Minecraft 1.13 或更高版本。\n", .{});
        return error.UnsupportedForgeVersion;
    }
    if (selected_loader == .neoforge and !isNeoForgeMinecraftSupported(minecraft_version)) {
        std.debug.print("NeoForge 整合包目前要求 Minecraft 1.20.1 或更高版本。\n", .{});
        return error.UnsupportedNeoForgeVersion;
    }
    if (requested_loader) |requested| {
        if (metadata.loader) |detected| {
            if (requested != detected) {
                std.debug.print("提示：使用指定加载器 {s}（ZIP 清单中为 {s}）。\n", .{ loaderName(requested), loaderName(detected) });
            }
        }
    }
    if (requested_loader_version) |requested| {
        if (metadata.loader_version) |detected| {
            if (!std.mem.eql(u8, requested, detected)) {
                std.debug.print("提示：使用指定加载器版本 {s}（ZIP 清单版本为 {s}）。\n", .{ requested, detected });
            }
        }
    }
    const loader_version: ?[]u8 = if (selected_loader) |active_loader| blk: {
        const manifest_version = if (metadata.loader == active_loader) metadata.loader_version else null;
        if (requested_loader_version orelse manifest_version) |version| {
            break :blk try allocator.dupe(u8, version);
        }
        break :blk switch (active_loader) {
            .forge => try fetchRecommendedForgeVersion(allocator, io, minecraft_version),
            .neoforge => try fetchRecommendedNeoForgeVersion(allocator, io, minecraft_version, neo_forge_maven_url),
            .fabric => try fetchRecommendedFabricVersion(allocator, io, minecraft_version),
        };
    } else null;
    defer if (loader_version) |version| allocator.free(version);
    const instance_id = try makeLoaderInstanceId(allocator, minecraft_version, selected_loader, loader_version);
    defer allocator.free(instance_id);
    const instance_path = try path.join(allocator, &.{ instances_path, instance_id });
    defer allocator.free(instance_path);
    if (fs.cwd().access(io, instance_path, .{})) |_| {
        std.debug.print("目标实例已存在，为避免覆盖未导入: {s}\n", .{instance_path});
        return error.PackInstanceAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try downloadModrinthPackFiles(allocator, io, staging_path);
    if (!try hasAnyPackContent(allocator, io, staging_path)) {
        std.debug.print("ZIP 中没有找到 mods、config、resourcepacks 等整合包目录。\n", .{});
        return error.PackContentNotFound;
    }

    try fs.cwd().rename(staging_path, fs.cwd(), instance_path, io);
    staging_exists = false;
    std.debug.print("整合包已导入到实例: {s}\n", .{instance_id});
    std.debug.print("Minecraft 版本: {s}\n", .{minecraft_version});
    if (selected_loader) |active_loader| {
        std.debug.print("{s} 版本: {s}\n", .{ loaderName(active_loader), loader_version.? });
        if (loader_version) |selected_version| {
            std.debug.print("启动命令: zig-mc {s} Steve --{s} {s}\n", .{
                minecraft_version,
                loaderIdSegment(active_loader),
                selected_version,
            });
        } else {
            std.debug.print("启动命令: zig-mc {s} Steve --{s}\n", .{
                minecraft_version,
                loaderIdSegment(active_loader),
            });
        }
    } else {
        std.debug.print("启动命令: zig-mc {s} Steve\n", .{minecraft_version});
    }
    if (metadata.has_curseforge_external_files) {
        std.debug.print("注意：CurseForge 清单引用但未打包的文件不会自动下载。\n", .{});
    }
}

fn isValidVersionId(version_id: []const u8) bool {
    if (version_id.len == 0 or std.mem.eql(u8, version_id, ".") or std.mem.eql(u8, version_id, "..")) return false;
    for (version_id) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '_' and char != '-') return false;
    }
    return true;
}

fn isForgeInstanceId(instance_id: []const u8) bool {
    return isLoaderInstanceId(instance_id, .forge);
}

fn isNeoForgeInstanceId(instance_id: []const u8) bool {
    return isLoaderInstanceId(instance_id, .neoforge);
}

fn isFabricInstanceId(instance_id: []const u8) bool {
    return isLoaderInstanceId(instance_id, .fabric);
}

fn isLoaderInstanceId(instance_id: []const u8, loader: ModLoader) bool {
    if (!isValidVersionId(instance_id)) return false;
    const separator = switch (loader) {
        .forge => "-forge-",
        .neoforge => "-neoforge-",
        .fabric => "-fabric-",
    };
    const index = std.mem.indexOf(u8, instance_id, separator) orelse return false;
    return index > 0 and index + separator.len < instance_id.len;
}

fn isValidModFileName(name: []const u8) bool {
    if (name.len <= 4 or !std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".jar")) return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '_' and char != '-') return false;
    }
    return !std.mem.eql(u8, name, ".jar");
}

fn instanceModsPath(allocator: std.mem.Allocator, instance_id: []const u8) ![]u8 {
    if (!isForgeInstanceId(instance_id) and !isNeoForgeInstanceId(instance_id) and !isFabricInstanceId(instance_id)) {
        std.debug.print("无效加载器实例 ID；请使用类似 1.20.1-forge-47.4.10、1.21.1-neoforge-21.1.172 或 1.21.1-fabric-0.16.5 的 ID。\n", .{});
        return error.InvalidLoaderInstanceId;
    }
    return try path.join(allocator, &.{ McDir, "instances", instance_id, "mods" });
}

fn listInstanceMods(allocator: std.mem.Allocator, io: std.Io, instance_id: []const u8) !void {
    const mods_path = try instanceModsPath(allocator, instance_id);
    defer allocator.free(mods_path);

    const mods_dir = fs.cwd().openDir(io, mods_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("实例 {s} 尚未安装 mod。\n", .{instance_id});
            return;
        },
        else => return err,
    };
    defer mods_dir.close(io);

    var iterator = mods_dir.iterate();
    var found = false;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !isValidModFileName(entry.name)) continue;
        std.debug.print("{s}\n", .{entry.name});
        found = true;
    }
    if (!found) std.debug.print("实例 {s} 尚未安装 mod。\n", .{instance_id});
}

fn installInstanceMod(allocator: std.mem.Allocator, io: std.Io, instance_id: []const u8, source_path: []const u8) !void {
    const mod_name = path.basename(source_path);
    if (!isValidModFileName(mod_name)) {
        std.debug.print("只支持文件名有效且扩展名为 .jar 的 mod 文件。\n", .{});
        return error.InvalidModFile;
    }

    const source_file = fs.cwd().openFile(io, source_path, .{}) catch |err| {
        std.debug.print("无法打开 mod 文件 {s}: {s}\n", .{ source_path, @errorName(err) });
        return err;
    };
    defer source_file.close(io);

    const mods_path = try instanceModsPath(allocator, instance_id);
    defer allocator.free(mods_path);
    try ensureDir(io, mods_path);
    const destination_path = try path.join(allocator, &.{ mods_path, mod_name });
    defer allocator.free(destination_path);

    const destination_file = fs.cwd().createFile(io, destination_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("该实例已存在同名 mod: {s}\n", .{mod_name});
            return error.ModAlreadyInstalled;
        },
        else => return err,
    };
    copyModFileContents(io, source_file, destination_file) catch |err| {
        destination_file.close(io);
        fs.cwd().deleteFile(io, destination_path) catch |cleanup_err| switch (cleanup_err) {
            error.FileNotFound => {},
            else => std.debug.print("清理未完成的 mod 文件失败: {s}\n", .{@errorName(cleanup_err)}),
        };
        return err;
    };
    destination_file.close(io);
    std.debug.print("已安装 mod: {s} -> {s}\n", .{ mod_name, instance_id });
}

fn copyModFileContents(io: std.Io, source_file: std.Io.File, destination_file: std.Io.File) !void {
    var read_buffer: [8192]u8 = undefined;
    var reader = source_file.reader(io, &read_buffer);
    var write_buffer: [8192]u8 = undefined;
    var writer = destination_file.writer(io, &write_buffer);
    while (true) {
        const bytes_read = try reader.interface.readSliceShort(&read_buffer);
        if (bytes_read == 0) break;
        try writer.interface.writeAll(read_buffer[0..bytes_read]);
    }
    try writer.interface.flush();
}

fn deleteInstanceMod(allocator: std.mem.Allocator, io: std.Io, instance_id: []const u8, mod_name: []const u8) !void {
    if (!isValidModFileName(mod_name)) {
        std.debug.print("无效 mod 文件名；只能删除 .jar 文件。\n", .{});
        return error.InvalidModFile;
    }

    const mods_path = try instanceModsPath(allocator, instance_id);
    defer allocator.free(mods_path);
    const mod_path = try path.join(allocator, &.{ mods_path, mod_name });
    defer allocator.free(mod_path);
    fs.cwd().deleteFile(io, mod_path) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("该实例中没有此 mod: {s}\n", .{mod_name});
            return error.ModNotFound;
        },
        else => return err,
    };
    std.debug.print("已从实例 {s} 删除 mod: {s}\n", .{ instance_id, mod_name });
}

fn isForgeMinecraftSupported(version_id: []const u8) bool {
    var parts = std.mem.splitScalar(u8, version_id, '.');
    const major_text = parts.next() orelse return false;
    const minor_text = parts.next() orelse return false;
    const major = std.fmt.parseInt(u32, major_text, 10) catch return false;
    const minor = std.fmt.parseInt(u32, minor_text, 10) catch return false;
    return major > 1 or (major == 1 and minor >= 13);
}

fn isNeoForgeMinecraftSupported(version_id: []const u8) bool {
    var parts = std.mem.splitScalar(u8, version_id, '.');
    const major_text = parts.next() orelse return false;
    const minor_text = parts.next() orelse return false;
    const major = std.fmt.parseInt(u32, major_text, 10) catch return false;
    const minor = std.fmt.parseInt(u32, minor_text, 10) catch return false;
    if (major != 1) return major > 1;
    if (minor != 20) return minor > 20;
    const patch_text = parts.next() orelse return false;
    const patch = std.fmt.parseInt(u32, patch_text, 10) catch return false;
    return patch >= 1;
}

fn makeInstanceId(allocator: std.mem.Allocator, version_id: []const u8, forge_version: ?[]const u8) ![]u8 {
    if (forge_version) |version| {
        return makeLoaderInstanceId(allocator, version_id, .forge, version);
    }
    return allocator.dupe(u8, version_id);
}

fn makeLoaderInstanceId(
    allocator: std.mem.Allocator,
    version_id: []const u8,
    loader: ?ModLoader,
    loader_version: ?[]const u8,
) ![]u8 {
    if (loader) |selected_loader| {
        const version = loader_version orelse return error.LoaderVersionRequired;
        return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
            version_id,
            loaderIdSegment(selected_loader),
            version,
        });
    }
    return allocator.dupe(u8, version_id);
}

fn listInstalledVersions(allocator: std.mem.Allocator, io: std.Io) !void {
    const versions_path = try path.join(allocator, &.{ McDir, "versions" });
    defer allocator.free(versions_path);

    const versions_dir = fs.cwd().openDir(io, versions_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("尚无已安装版本。\n", .{});
            return;
        },
        else => return err,
    };
    defer versions_dir.close(io);

    var iterator = versions_dir.iterate();
    var found = false;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        std.debug.print("{s}\n", .{entry.name});
        found = true;
    }
    if (!found) std.debug.print("尚无已安装版本。\n", .{});
}

fn deleteInstalledVersion(allocator: std.mem.Allocator, io: std.Io, version_id: []const u8) !void {
    if (!isValidVersionId(version_id)) {
        std.debug.print("无效版本 ID，只能使用字母、数字、点、下划线和连字符。\n", .{});
        return error.InvalidVersionId;
    }

    const version_path = try path.join(allocator, &.{ McDir, "versions", version_id });
    defer allocator.free(version_path);
    const instance_path = try path.join(allocator, &.{ McDir, "instances", version_id });
    defer allocator.free(instance_path);

    const version_removed = try deleteDirectoryIfExists(io, version_path);
    const instance_removed = try deleteDirectoryIfExists(io, instance_path);
    if (!version_removed and !instance_removed) {
        std.debug.print("版本及其实例不存在: {s}\n", .{version_id});
        return error.VersionNotFound;
    }
    std.debug.print("已删除版本及其实例数据: {s}\n", .{version_id});
}

fn deleteDirectoryIfExists(io: std.Io, directory_path: []const u8) !bool {
    const dir = fs.cwd().openDir(io, directory_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    dir.close(io);
    try fs.cwd().deleteTree(io, directory_path);
    return true;
}

fn isValidForgeVersion(version: []const u8) bool {
    if (version.len == 0) return false;
    for (version) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '-') return false;
    }
    return true;
}

fn offlineUuid(allocator: std.mem.Allocator, player_name: []const u8) ![]u8 {
    const source = try std.fmt.allocPrint(allocator, "OfflinePlayer:{s}", .{player_name});
    defer allocator.free(source);

    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(source, &digest, .{});
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;

    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn replaceInPlace(allocator: std.mem.Allocator, value: *[]u8, needle: []const u8, replacement: []const u8) !void {
    const updated = try std.mem.replaceOwned(u8, allocator, value.*, needle, replacement);
    allocator.free(value.*);
    value.* = updated;
}

// ================= HTTP & 下载辅助 (基于 curl) =================

/// 使用系统 curl 下载文件内容 (解决 Zig std http 不支持 HTTPS 的问题)
fn fetchUrl(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "curl",
        "--http1.1",
        "--user-agent",
        DownloadUserAgent,
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--retry",
        "8",
        "--retry-all-errors",
        "--retry-delay",
        "2",
        "--retry-max-time",
        "300",
        "--connect-timeout",
        "20",
        "--max-time",
        "300",
        url,
    };
    const result = try process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(200 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            std.debug.print("curl 下载失败: {s} (exit code {}): {s}\n", .{ url, code, result.stderr });
            allocator.free(result.stderr);
            return error.DownloadFailed;
        },
        else => {
            allocator.free(result.stdout);
            std.debug.print("curl 下载进程异常: {s}: {s}\n", .{ url, result.stderr });
            allocator.free(result.stderr);
            return error.CurlCrashed;
        },
    }

    allocator.free(result.stderr);
    return result.stdout;
}

fn fetchVersionJson(allocator: std.mem.Allocator, io: std.Io, version_id: []const u8) !json.Parsed(json.Value) {
    // 获取 manifest
    const manifest_str = try fetchUrl(allocator, io, "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json");
    defer allocator.free(manifest_str);

    const manifest = try json.parseFromSlice(json.Value, allocator, manifest_str, .{});
    defer manifest.deinit();

    // 查找对应版本的 URL
    const versions = manifest.value.object.get("versions").?.array;
    var version_url: ?[]const u8 = null;
    for (versions.items) |v| {
        if (std.mem.eql(u8, v.object.get("id").?.string, version_id)) {
            version_url = v.object.get("url").?.string;
            break;
        }
    }

    const v_url = version_url orelse return error.VersionNotFound;

    // 获取具体版本 JSON
    const version_str = try fetchUrl(allocator, io, v_url);
    defer allocator.free(version_str);

    return try json.parseFromSlice(json.Value, allocator, version_str, .{});
}

fn fetchRecommendedForgeVersion(allocator: std.mem.Allocator, io: std.Io, minecraft_version: []const u8) ![]u8 {
    const promotions_url = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json";
    const body = try fetchUrl(allocator, io, promotions_url);
    defer allocator.free(body);

    const promotions = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer promotions.deinit();

    return try selectForgeVersion(allocator, promotions.value, minecraft_version);
}

fn selectForgeVersion(allocator: std.mem.Allocator, promotions: json.Value, minecraft_version: []const u8) ![]u8 {
    const promos = promotions.object.get("promos") orelse return error.InvalidForgePromotions;
    const recommended_key = try std.fmt.allocPrint(allocator, "{s}-recommended", .{minecraft_version});
    defer allocator.free(recommended_key);
    if (promos.object.get(recommended_key)) |version| {
        return allocator.dupe(u8, version.string);
    }

    const latest_key = try std.fmt.allocPrint(allocator, "{s}-latest", .{minecraft_version});
    defer allocator.free(latest_key);
    if (promos.object.get(latest_key)) |version| {
        std.debug.print("未找到 Forge 推荐版，使用最新版本 {s}。\n", .{version.string});
        return allocator.dupe(u8, version.string);
    }
    return error.ForgeVersionNotFound;
}

fn selectFabricLoaderVersion(allocator: std.mem.Allocator, versions: json.Value) ![]u8 {
    if (versions != .array or versions.array.items.len == 0) return error.FabricLoaderVersionNotFound;
    var latest: ?[]const u8 = null;
    for (versions.array.items) |entry| {
        if (entry != .object) return error.InvalidFabricMetadata;
        const loader = entry.object.get("loader") orelse return error.InvalidFabricMetadata;
        if (loader != .object) return error.InvalidFabricMetadata;
        const version = loader.object.get("version") orelse return error.InvalidFabricMetadata;
        if (version != .string or !isValidForgeVersion(version.string)) return error.InvalidFabricMetadata;
        if (latest == null) latest = version.string;
        if (loader.object.get("stable")) |stable| {
            if (stable == .bool and stable.bool) return allocator.dupe(u8, version.string);
        }
    }
    return allocator.dupe(u8, latest.?);
}

fn fetchRecommendedFabricVersion(allocator: std.mem.Allocator, io: std.Io, minecraft_version: []const u8) ![]u8 {
    if (!isValidVersionId(minecraft_version)) return error.InvalidVersionId;
    const url = try std.fmt.allocPrint(
        allocator,
        "https://meta.fabricmc.net/v2/versions/loader/{s}",
        .{minecraft_version},
    );
    defer allocator.free(url);
    const body = try fetchUrl(allocator, io, url);
    defer allocator.free(body);
    const versions = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer versions.deinit();
    return try selectFabricLoaderVersion(allocator, versions.value);
}

fn isUsableFabricProfile(profile: json.Value, minecraft_version: []const u8, loader_version: []const u8) bool {
    if (profile != .object) return false;
    const id = profile.object.get("id") orelse return false;
    if (id != .string) return false;
    const id_prefix = "fabric-loader-";
    if (!std.mem.startsWith(u8, id.string, id_prefix)) return false;
    const id_suffix = id.string[id_prefix.len..];
    if (!std.mem.startsWith(u8, id_suffix, loader_version) or
        id_suffix.len <= loader_version.len or id_suffix[loader_version.len] != '-' or
        !std.mem.eql(u8, id_suffix[loader_version.len + 1 ..], minecraft_version)) return false;
    const parent = profile.object.get("inheritsFrom") orelse return false;
    if (parent != .string or !std.mem.eql(u8, parent.string, minecraft_version)) return false;
    const main_class = profile.object.get("mainClass") orelse return false;
    if (main_class != .string or !std.mem.eql(u8, main_class.string, "net.fabricmc.loader.impl.launch.knot.KnotClient")) return false;
    const libraries = profile.object.get("libraries") orelse return false;
    if (libraries != .array or libraries.array.items.len == 0) return false;
    const arguments = profile.object.get("arguments") orelse return false;
    if (arguments != .object) return false;
    const game_arguments = arguments.object.get("game") orelse return false;
    return game_arguments == .array;
}

fn fetchFabricProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    minecraft_version: []const u8,
    loader_version: []const u8,
) !json.Parsed(json.Value) {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://meta.fabricmc.net/v2/versions/loader/{s}/{s}/profile/json",
        .{ minecraft_version, loader_version },
    );
    defer allocator.free(url);
    const body = try fetchUrl(allocator, io, url);
    defer allocator.free(body);
    const profile = try json.parseFromSlice(json.Value, allocator, body, .{});
    if (!isUsableFabricProfile(profile.value, minecraft_version, loader_version)) {
        profile.deinit();
        return error.InvalidFabricProfile;
    }
    return profile;
}

fn neoForgeVersionMatchesMinecraft(version: []const u8, minecraft_version: []const u8) bool {
    if (std.mem.startsWith(u8, version, minecraft_version) and
        version.len > minecraft_version.len and version[minecraft_version.len] == '-')
    {
        return true;
    }

    var parts = std.mem.splitScalar(u8, minecraft_version, '.');
    const major_text = parts.next() orelse return false;
    const minor_text = parts.next() orelse return false;
    const major = std.fmt.parseInt(u32, major_text, 10) catch return false;
    const minor = std.fmt.parseInt(u32, minor_text, 10) catch return false;
    const patch = if (parts.next()) |patch_text|
        std.fmt.parseInt(u32, patch_text, 10) catch return false
    else
        0;
    const neo_major = if (major == 1) minor else major;
    const neo_minor = if (major == 1) patch else minor;
    var prefix_buffer: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "{d}.{d}.", .{ neo_major, neo_minor }) catch return false;
    return std.mem.startsWith(u8, version, prefix);
}

fn selectNeoForgeVersion(allocator: std.mem.Allocator, metadata_xml: []const u8, minecraft_version: []const u8) ![]u8 {
    const open_tag = "<version>";
    const close_tag = "</version>";
    var remaining = metadata_xml;
    var selected: ?[]u8 = null;
    errdefer if (selected) |version| allocator.free(version);
    while (std.mem.indexOf(u8, remaining, open_tag)) |open_index| {
        remaining = remaining[open_index + open_tag.len ..];
        const close_index = std.mem.indexOf(u8, remaining, close_tag) orelse return error.InvalidNeoForgeMetadata;
        const candidate = remaining[0..close_index];
        remaining = remaining[close_index + close_tag.len ..];
        if (!isValidForgeVersion(candidate) or !neoForgeVersionMatchesMinecraft(candidate, minecraft_version)) continue;
        if (selected) |previous| allocator.free(previous);
        selected = try allocator.dupe(u8, candidate);
    }
    return selected orelse error.NeoForgeVersionNotFound;
}

fn fetchRecommendedNeoForgeVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    minecraft_version: []const u8,
    maven_base_url: []const u8,
) ![]u8 {
    const metadata_url = try neoForgeArtifactUrl(
        allocator,
        maven_base_url,
        "net/neoforged/neoforge/maven-metadata.xml",
    );
    defer allocator.free(metadata_url);
    const metadata_xml = try fetchUrl(allocator, io, metadata_url);
    defer allocator.free(metadata_xml);
    return try selectNeoForgeVersion(allocator, metadata_xml, minecraft_version);
}

fn neoForgeArtifactUrl(allocator: std.mem.Allocator, base_url: []const u8, artifact_path: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, base_url, "https://") or base_url.len <= "https://".len) {
        return error.InvalidNeoForgeMavenUrl;
    }
    const trimmed_base = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed_base.len <= "https://".len) return error.InvalidNeoForgeMavenUrl;
    if (std.mem.indexOfAny(u8, artifact_path, "\\:?*\"<>|")) |_| return error.InvalidNeoForgeArtifactPath;
    if (std.mem.startsWith(u8, artifact_path, "/") or std.mem.indexOf(u8, artifact_path, "..") != null) {
        return error.InvalidNeoForgeArtifactPath;
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_base, artifact_path });
}

fn installForge(allocator: std.mem.Allocator, io: std.Io, minecraft_version: []const u8, forge_version: []const u8) !json.Parsed(json.Value) {
    const forge_coordinate = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ minecraft_version, forge_version });
    defer allocator.free(forge_coordinate);
    const installer_name = try std.fmt.allocPrint(allocator, "forge-{s}-installer.jar", .{forge_coordinate});
    defer allocator.free(installer_name);
    const installer_path = try path.join(allocator, &.{ McDir, installer_name });
    defer allocator.free(installer_path);
    const installer_url = try std.fmt.allocPrint(allocator, "https://maven.minecraftforge.net/net/minecraftforge/forge/{s}/forge-{s}-installer.jar", .{ forge_coordinate, forge_coordinate });
    defer allocator.free(installer_url);
    const profile_id = try std.fmt.allocPrint(allocator, "{s}-forge-{s}", .{ minecraft_version, forge_version });
    defer allocator.free(profile_id);
    const profile_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{profile_id});
    defer allocator.free(profile_filename);
    const profile_path = try path.join(allocator, &.{ McDir, "versions", profile_id, profile_filename });
    defer allocator.free(profile_path);

    try ensureDir(io, McDir);
    try ensureDir(io, path.dirname(installer_path) orelse McDir);
    try ensureForgeLauncherProfile(allocator, io);

    if (fs.cwd().access(io, profile_path, .{})) |_| {
        const profile_text = try fs.cwd().readFileAlloc(io, profile_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(profile_text);
        const cached_profile = try json.parseFromSlice(json.Value, allocator, profile_text, .{});
        if (try forgeArtifactsExist(allocator, io, minecraft_version, forge_version, cached_profile.value)) {
            return cached_profile;
        }
        cached_profile.deinit();
        std.debug.print("Forge profile 存在但客户端产物缺失，将重新运行安装器。\n", .{});
    } else |_| {}

    const installer_data = try fetchUrl(allocator, io, installer_url);
    defer allocator.free(installer_data);
    const installer_file = try fs.cwd().createFile(io, installer_path, .{});
    defer installer_file.close(io);
    var writer_buffer: [4096]u8 = undefined;
    var installer_writer = installer_file.writer(io, &writer_buffer);
    try installer_writer.interface.writeAll(installer_data);
    try installer_writer.interface.flush();

    const current_path = try process.currentPathAlloc(io, allocator);
    defer allocator.free(current_path);
    const mc_path = try path.join(allocator, &.{ current_path, McDir });
    defer allocator.free(mc_path);
    const installer_args = [_][]const u8{ "java", "-jar", installer_path, "--installClient", mc_path };
    const result = try process.run(allocator, io, .{
        .argv = &installer_args,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("Forge 安装器失败（退出码 {}）。\nstdout:\n{s}\nstderr:\n{s}\n", .{ code, result.stdout, result.stderr });
            return error.ForgeInstallFailed;
        },
        else => {
            std.debug.print("Forge 安装器进程异常。\nstdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
            return error.ForgeInstallFailed;
        },
    }

    const profile_text = try fs.cwd().readFileAlloc(io, profile_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(profile_text);
    const profile = try json.parseFromSlice(json.Value, allocator, profile_text, .{});
    if (!try forgeArtifactsExist(allocator, io, minecraft_version, forge_version, profile.value)) {
        profile.deinit();
        std.debug.print("Forge 安装器未生成完整客户端文件，请检查网络连接及安装器日志。\n", .{});
        return error.ForgeInstallIncomplete;
    }
    return profile;
}

fn isUsableNeoForgeProfile(profile: json.Value, expected_id: []const u8) bool {
    if (profile != .object) return false;
    const id = profile.object.get("id") orelse return false;
    if (id != .string or !std.mem.eql(u8, id.string, expected_id)) return false;
    const main_class = profile.object.get("mainClass") orelse return false;
    if (main_class != .string or main_class.string.len == 0) return false;
    const libraries = profile.object.get("libraries") orelse return false;
    if (libraries != .array) return false;
    const arguments = profile.object.get("arguments") orelse return false;
    if (arguments != .object) return false;
    const game_arguments = arguments.object.get("game") orelse return false;
    return game_arguments == .array;
}

fn isUsableForgeProfile(profile: json.Value, expected_id: []const u8) bool {
    if (profile != .object) return false;
    const id = profile.object.get("id") orelse return false;
    if (id != .string or !std.mem.eql(u8, id.string, expected_id)) return false;
    const main_class = profile.object.get("mainClass") orelse return false;
    if (main_class != .string or main_class.string.len == 0) return false;
    const libraries = profile.object.get("libraries") orelse return false;
    if (libraries != .array) return false;
    const arguments = profile.object.get("arguments") orelse return false;
    if (arguments != .object) return false;
    const game_arguments = arguments.object.get("game") orelse return false;
    return game_arguments == .array;
}

fn neoForgeMappingsVersion(profile: json.Value) ?[]const u8 {
    if (profile != .object) return null;
    const arguments = profile.object.get("arguments") orelse return null;
    if (arguments != .object) return null;
    const game_arguments = arguments.object.get("game") orelse return null;
    if (game_arguments != .array) return null;

    const items = game_arguments.array.items;
    for (items, 0..) |argument, index| {
        if (argument == .string and std.mem.eql(u8, argument.string, "--fml.neoFormVersion") and index + 1 < items.len) {
            if (items[index + 1] == .string) return items[index + 1].string;
        }
    }
    return null;
}

fn neoForgeArtifactsExist(
    allocator: std.mem.Allocator,
    io: std.Io,
    minecraft_version: []const u8,
    neoforge_version: []const u8,
    profile: json.Value,
) !bool {
    const mappings_version = neoForgeMappingsVersion(profile) orelse return false;
    const minecraft_coordinate = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ minecraft_version, mappings_version });
    defer allocator.free(minecraft_coordinate);
    const client_extra_name = try std.fmt.allocPrint(allocator, "client-{s}-extra.jar", .{minecraft_coordinate});
    defer allocator.free(client_extra_name);
    const client_srg_name = try std.fmt.allocPrint(allocator, "client-{s}-srg.jar", .{minecraft_coordinate});
    defer allocator.free(client_srg_name);
    const patched_client_name = try std.fmt.allocPrint(allocator, "neoforge-{s}-client.jar", .{neoforge_version});
    defer allocator.free(patched_client_name);
    const client_extra_path = try path.join(allocator, &.{
        McDir, "libraries", "net", "minecraft", "client", minecraft_coordinate, client_extra_name,
    });
    defer allocator.free(client_extra_path);
    const client_srg_path = try path.join(allocator, &.{
        McDir, "libraries", "net", "minecraft", "client", minecraft_coordinate, client_srg_name,
    });
    defer allocator.free(client_srg_path);
    const patched_client_path = try path.join(allocator, &.{
        McDir, "libraries", "net", "neoforged", "neoforge", neoforge_version, patched_client_name,
    });
    defer allocator.free(patched_client_path);

    const required_artifacts = [_][]const u8{ client_extra_path, client_srg_path, patched_client_path };
    for (required_artifacts) |artifact_path| {
        fs.cwd().access(io, artifact_path, .{}) catch return false;
    }
    return true;
}

fn readNeoForgeInstallerProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    installer_path: []const u8,
    neoforge_version: []const u8,
) !json.Parsed(json.Value) {
    const temp_directory_name = try std.fmt.allocPrint(allocator, ".neoforge-installer-profile-{s}", .{neoforge_version});
    defer allocator.free(temp_directory_name);
    const temp_directory = try path.join(allocator, &.{ McDir, temp_directory_name });
    defer allocator.free(temp_directory);
    if (fs.cwd().access(io, temp_directory, .{})) |_| {
        return error.NeoForgeInstallerProfileExtractionAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try ensureDir(io, temp_directory);
    defer {
        _ = deleteDirectoryIfExists(io, temp_directory) catch |err| {
            std.debug.print("清理 NeoForge 安装器 profile 临时目录失败: {s}\n", .{@errorName(err)});
        };
    }

    const installer = try fs.cwd().openFile(io, installer_path, .{});
    defer installer.close(io);
    var zip_buffer: [4096]u8 = undefined;
    var reader = installer.reader(io, &zip_buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var profile_found = false;
    while (try iterator.next()) |entry| {
        if (entry.filename_len != "install_profile.json".len) continue;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(filename_buffer[0..entry.filename_len]);
        if (!std.mem.eql(u8, filename_buffer[0..entry.filename_len], "install_profile.json")) continue;
        if (entry.uncompressed_size > 16 * 1024 * 1024) return error.NeoForgeInstallerProfileTooLarge;
        const temp_dir = try fs.cwd().openDir(io, temp_directory, .{});
        defer temp_dir.close(io);
        try entry.extract(&reader, .{}, &filename_buffer, temp_dir);
        profile_found = true;
        break;
    }
    if (!profile_found) return error.NeoForgeInstallerProfileNotFound;

    const profile_path = try path.join(allocator, &.{ temp_directory, "install_profile.json" });
    defer allocator.free(profile_path);
    const profile_text = try fs.cwd().readFileAlloc(io, profile_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(profile_text);
    return try json.parseFromSlice(json.Value, allocator, profile_text, .{});
}

fn installNeoForge(
    allocator: std.mem.Allocator,
    io: std.Io,
    minecraft_version: []const u8,
    neoforge_version: []const u8,
    maven_base_url: []const u8,
) !json.Parsed(json.Value) {
    const installer_name = try std.fmt.allocPrint(allocator, "neoforge-{s}-installer.jar", .{neoforge_version});
    defer allocator.free(installer_name);
    const installer_path = try path.join(allocator, &.{ McDir, installer_name });
    defer allocator.free(installer_path);
    const installer_relative_path = try std.fmt.allocPrint(
        allocator,
        "net/neoforged/neoforge/{s}/neoforge-{s}-installer.jar",
        .{ neoforge_version, neoforge_version },
    );
    defer allocator.free(installer_relative_path);
    const installer_url = try neoForgeArtifactUrl(allocator, maven_base_url, installer_relative_path);
    defer allocator.free(installer_url);
    const profile_id = try std.fmt.allocPrint(allocator, "neoforge-{s}", .{neoforge_version});
    defer allocator.free(profile_id);
    const profile_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{profile_id});
    defer allocator.free(profile_filename);
    const profile_path = try path.join(allocator, &.{ McDir, "versions", profile_id, profile_filename });
    defer allocator.free(profile_path);

    try ensureDir(io, McDir);
    try ensureDir(io, path.dirname(installer_path) orelse McDir);
    try ensureForgeLauncherProfile(allocator, io);

    if (fs.cwd().access(io, profile_path, .{})) |_| {
        const profile_text = try fs.cwd().readFileAlloc(io, profile_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(profile_text);
        const cached_profile = try json.parseFromSlice(json.Value, allocator, profile_text, .{});
        if (isUsableNeoForgeProfile(cached_profile.value, profile_id) and
            try neoForgeArtifactsExist(allocator, io, minecraft_version, neoforge_version, cached_profile.value))
        {
            return cached_profile;
        }
        cached_profile.deinit();
        std.debug.print("NeoForge 客户端安装产物缺失或 profile 不完整，将重新运行安装器。\n", .{});
    } else |_| {}

    try downloadNeoForgeInstaller(allocator, io, installer_url, installer_path);

    std.debug.print("下载 NeoForge 安装器处理器依赖...\n", .{});
    var installer_profile = try readNeoForgeInstallerProfile(allocator, io, installer_path, neoforge_version);
    defer installer_profile.deinit();
    try downloadLibraries(allocator, io, installer_profile.value, maven_base_url);

    const current_path = try process.currentPathAlloc(io, allocator);
    defer allocator.free(current_path);
    const mc_path = try path.join(allocator, &.{ current_path, McDir });
    defer allocator.free(mc_path);
    const installer_args = [_][]const u8{
        "java",
        "-jar",
        installer_path,
        "--installClient",
        mc_path,
        "--mirror",
        maven_base_url,
    };
    const result = try process.run(allocator, io, .{
        .argv = &installer_args,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("NeoForge 安装器失败（退出码 {}）。\nstdout:\n{s}\nstderr:\n{s}\n", .{ code, result.stdout, result.stderr });
            return error.NeoForgeInstallFailed;
        },
        else => {
            std.debug.print("NeoForge 安装器进程异常。\nstdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
            return error.NeoForgeInstallFailed;
        },
    }

    const profile_text = try fs.cwd().readFileAlloc(io, profile_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(profile_text);
    const profile = try json.parseFromSlice(json.Value, allocator, profile_text, .{});
    if (!isUsableNeoForgeProfile(profile.value, profile_id) or
        !try neoForgeArtifactsExist(allocator, io, minecraft_version, neoforge_version, profile.value))
    {
        profile.deinit();
        std.debug.print("NeoForge 安装器未生成完整客户端文件，请检查安装器日志。\n", .{});
        return error.NeoForgeInstallIncomplete;
    }
    return profile;
}

fn isZipHeader(header: []const u8) bool {
    if (header.len < 4 or header[0] != 'P' or header[1] != 'K') return false;
    return (header[2] == 3 and header[3] == 4) or
        (header[2] == 5 and header[3] == 6) or
        (header[2] == 7 and header[3] == 8);
}

fn isZipFile(io: std.Io, file_path: []const u8) !bool {
    const file = fs.cwd().openFile(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    var buffer: [4]u8 = undefined;
    var reader = file.reader(io, &buffer);
    reader.interface.readSliceAll(&buffer) catch |err| switch (err) {
        error.EndOfStream => return false,
        error.ReadFailed => return reader.err orelse return error.InstallerReadFailed,
    };
    return isZipHeader(&buffer);
}

fn downloadNeoForgeInstaller(
    allocator: std.mem.Allocator,
    io: std.Io,
    installer_url: []const u8,
    installer_path: []const u8,
) !void {
    if (try isZipFile(io, installer_path)) {
        std.debug.print("复用已下载的 NeoForge 安装器。\n", .{});
        return;
    }
    fs.cwd().deleteFile(io, installer_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const partial_path = try std.fmt.allocPrint(allocator, "{s}.part", .{installer_path});
    defer allocator.free(partial_path);
    if (try isZipFile(io, partial_path)) {
        try fs.cwd().rename(partial_path, fs.cwd(), installer_path, io);
        std.debug.print("复用已完整下载的 NeoForge 安装器。\n", .{});
        return;
    }

    std.debug.print("下载 NeoForge 安装器（支持断点续传）。\n", .{});
    const argv = [_][]const u8{
        "curl",
        "--http1.1",
        "--user-agent",
        DownloadUserAgent,
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--retry",
        "8",
        "--retry-all-errors",
        "--retry-connrefused",
        "--retry-delay",
        "2",
        "--retry-max-time",
        "300",
        "--connect-timeout",
        "30",
        "--max-time",
        "1800",
        "--continue-at",
        "-",
        "--output",
        partial_path,
        installer_url,
    };
    const result = process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        std.debug.print(
            "无法启动 curl 下载 NeoForge 安装器: {s}。部分文件保留在 {s}，修复网络后可续传。\n",
            .{ @errorName(err), partial_path },
        );
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print(
                "NeoForge 下载失败（退出码 {}）: {s}\n请检查网络/代理，或配置 NEOFORGED_MAVEN_URL。部分文件保留在 {s}，重试可续传。\n",
                .{ code, result.stderr, partial_path },
            );
            return error.NeoForgeDownloadFailed;
        },
        else => {
            std.debug.print(
                "NeoForge 下载进程异常（{s}）: {s}\n请检查网络/代理，或配置 NEOFORGED_MAVEN_URL。部分文件保留在 {s}，重试可续传。\n",
                .{ @tagName(result.term), result.stderr, partial_path },
            );
            return error.NeoForgeDownloadFailed;
        },
    }

    if (!try isZipFile(io, partial_path)) {
        fs.cwd().deleteFile(io, partial_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        std.debug.print("下载结果不是有效的 ZIP/JAR 安装器，已删除无效文件。\n", .{});
        return error.InvalidNeoForgeInstaller;
    }
    try fs.cwd().rename(partial_path, fs.cwd(), installer_path, io);
}

fn forgeArtifactsExist(
    allocator: std.mem.Allocator,
    io: std.Io,
    minecraft_version: []const u8,
    forge_version: []const u8,
    profile: json.Value,
) !bool {
    const profile_id = try std.fmt.allocPrint(allocator, "{s}-forge-{s}", .{ minecraft_version, forge_version });
    defer allocator.free(profile_id);
    if (!isUsableForgeProfile(profile, profile_id)) return false;

    const forge_coordinate = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ minecraft_version, forge_version });
    defer allocator.free(forge_coordinate);
    const forge_library_prefix = try std.fmt.allocPrint(allocator, "net.minecraftforge:forge:{s}:", .{forge_coordinate});
    defer allocator.free(forge_library_prefix);
    var forge_artifact_found = false;
    const libraries = profile.object.get("libraries").?.array;
    for (libraries.items) |library| {
        if (library != .object) return false;
        const name = library.object.get("name") orelse return false;
        if (name != .string) return false;
        const downloads = library.object.get("downloads") orelse continue;
        if (downloads != .object) return false;
        const artifact = downloads.object.get("artifact") orelse continue;
        if (artifact != .object) return false;
        const relative_path_value = artifact.object.get("path") orelse return false;
        if (relative_path_value != .string or !isSafeModrinthPackPath(relative_path_value.string)) return false;
        if (std.mem.startsWith(u8, name.string, forge_library_prefix)) forge_artifact_found = true;

        const local_path = try path.join(allocator, &.{ McDir, "libraries", relative_path_value.string });
        defer allocator.free(local_path);
        fs.cwd().access(io, local_path, .{}) catch return false;
    }
    return forge_artifact_found;
}

fn ensureForgeLauncherProfile(allocator: std.mem.Allocator, io: std.Io) !void {
    const standard_profile = try path.join(allocator, &.{ McDir, "launcher_profiles.json" });
    defer allocator.free(standard_profile);
    const microsoft_profile = try path.join(allocator, &.{ McDir, "launcher_profiles_microsoft_store.json" });
    defer allocator.free(microsoft_profile);

    if (fs.cwd().access(io, standard_profile, .{})) |_| return else |_| {}
    if (fs.cwd().access(io, microsoft_profile, .{})) |_| return else |_| {}

    const file = fs.cwd().createFile(io, standard_profile, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.close(io);

    const initial_profile = "{\"profiles\":{},\"settings\":{},\"version\":3}\n";
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(initial_profile);
    try writer.interface.flush();
}

fn ensureDir(io: std.Io, dir_path: []const u8) !void {
    try fs.cwd().createDirPath(io, dir_path);
}

fn checkAndDownload(allocator: std.mem.Allocator, io: std.Io, url: []const u8, local_path: []const u8, expected_sha1: []const u8) !void {
    // 检查本地文件是否存在且 SHA1 匹配
    if (fs.cwd().access(io, local_path, .{})) |_| {
        if (expected_sha1.len > 0) {
            if (try verifySha1(io, local_path, expected_sha1)) {
                return; // 文件已存在且校验通过
            }
        } else {
            return; // 不需要校验，存在即跳过
        }
    } else |_| {}

    // 确保父目录存在
    const dir = path.dirname(local_path) orelse ".";
    try ensureDir(io, dir);

    // 下载
    std.debug.print("  下载: {s}\n", .{path.basename(local_path)});
    const data = try fetchUrl(allocator, io, url);
    defer allocator.free(data);

    if (expected_sha1.len > 0 and !sha1Matches(data, expected_sha1)) {
        std.debug.print("  SHA-1 校验失败，文件未保存: {s}\n", .{path.basename(local_path)});
        return error.DownloadHashMismatch;
    }

    // 写入文件
    const file = try fs.cwd().createFile(io, local_path, .{});
    defer file.close(io);
    var file_writer_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &file_writer_buffer);
    try file_writer.interface.writeAll(data);
    try file_writer.interface.flush();
}

fn sha1Matches(data: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != Sha1.digest_length * 2) return false;

    var digest: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(data, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&actual_hex, expected_hex);
}

fn verifySha1(io: std.Io, file_path: []const u8, expected_hex: []const u8) !bool {
    const file = try fs.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    var hasher = Sha1.init(.{});
    var buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    while (true) {
        const bytes_read = try file_reader.interface.readSliceShort(&buffer);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
    }

    var digest: [Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    return expected_hex.len == actual_hex.len and std.ascii.eqlIgnoreCase(&actual_hex, expected_hex);
}

fn queueDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    pending: *std.ArrayList(DownloadItem),
    url: []const u8,
    local_path: []const u8,
    sha1: []const u8,
) !void {
    if (fs.cwd().access(io, local_path, .{})) |_| {
        if (try verifySha1(io, local_path, sha1)) return;
    } else |_| {}

    const dir = path.dirname(local_path) orelse ".";
    try ensureDir(io, dir);
    const owned_url = try allocator.dupe(u8, url);
    errdefer allocator.free(owned_url);
    const owned_path = try allocator.dupe(u8, local_path);
    errdefer allocator.free(owned_path);
    const owned_sha1 = try allocator.dupe(u8, sha1);
    errdefer allocator.free(owned_sha1);
    try pending.append(allocator, .{
        .url = owned_url,
        .local_path = owned_path,
        .sha1 = owned_sha1,
    });
}

fn freePendingDownloads(allocator: std.mem.Allocator, pending: *std.ArrayList(DownloadItem)) void {
    for (pending.items) |item| {
        allocator.free(item.url);
        allocator.free(item.local_path);
        allocator.free(item.sha1);
    }
    pending.deinit(allocator);
}

fn downloadPending(allocator: std.mem.Allocator, io: std.Io, pending: []const DownloadItem, parallelism: usize) !void {
    var start: usize = 0;
    while (start < pending.len) {
        const end = @min(start + DownloadBatchSize, pending.len);
        try downloadBatch(allocator, io, pending[start..end], parallelism);
        start = end;
    }
}

fn downloadFileWithResume(allocator: std.mem.Allocator, io: std.Io, asset: DownloadItem) !void {
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.part", .{asset.local_path});
    defer allocator.free(temp_path);
    const argv = [_][]const u8{
        "curl",
        "--http1.1",
        "--user-agent",
        DownloadUserAgent,
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--retry",
        "8",
        "--retry-all-errors",
        "--retry-connrefused",
        "--retry-delay",
        "2",
        "--retry-max-time",
        "900",
        "--connect-timeout",
        "20",
        "--max-time",
        "1800",
        "--continue-at",
        "-",
        "--output",
        temp_path,
        asset.url,
    };

    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        const result = process.run(allocator, io, .{
            .argv = &argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| {
            std.debug.print("  下载启动失败（第 {}/3 次）: {s}\n", .{ attempt + 1, @errorName(err) });
            if (attempt == 2) return err;
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const succeeded = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (succeeded and (try verifySha1(io, temp_path, asset.sha1))) {
            fs.cwd().deleteFile(io, asset.local_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try fs.cwd().rename(temp_path, fs.cwd(), asset.local_path, io);
            return;
        }

        if (!succeeded) {
            switch (result.term) {
                .exited => |code| std.debug.print("  下载失败（第 {}/3 次，退出码 {}），保留部分文件以便续传: {s}\n", .{
                    attempt + 1,
                    code,
                    result.stderr,
                }),
                else => std.debug.print("  下载进程异常（第 {}/3 次），保留部分文件以便续传: {s}\n", .{
                    attempt + 1,
                    result.stderr,
                }),
            }
            if (attempt == 2) return error.DownloadFailed;
            continue;
        }

        std.debug.print("  下载文件 SHA-1 校验失败（第 {}/3 次），重新下载。\n", .{attempt + 1});
        fs.cwd().deleteFile(io, temp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (attempt == 2) return error.DownloadHashMismatch;
    }
    return error.DownloadFailed;
}

fn neoForgeLibraryDownloadUrl(allocator: std.mem.Allocator, url: []const u8, maven_base_url: []const u8) ![]u8 {
    const official_prefix = "https://maven.neoforged.net/releases/";
    if (!std.mem.startsWith(u8, url, official_prefix)) return try allocator.dupe(u8, url);
    const artifact_path = url[official_prefix.len..];
    if (std.mem.startsWith(u8, artifact_path, "net/minecraftforge/")) {
        return try neoForgeArtifactUrl(allocator, "https://maven.minecraftforge.net", artifact_path);
    }
    return try neoForgeArtifactUrl(allocator, maven_base_url, artifact_path);
}

fn downloadLibraries(
    allocator: std.mem.Allocator,
    io: std.Io,
    version_json: json.Value,
    neo_forge_maven_url: []const u8,
) !void {
    const libraries_value = version_json.object.get("libraries") orelse return;
    const libraries = libraries_value.array;
    var pending: std.ArrayList(DownloadItem) = .empty;
    defer freePendingDownloads(allocator, &pending);

    for (libraries.items) |lib| {
        if (lib != .object) return error.InvalidLibraryMetadata;
        var allocated_url: ?[]u8 = null;
        defer if (allocated_url) |value| allocator.free(value);
        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |value| allocator.free(value);
        var url: ?[]const u8 = null;
        var sha1: []const u8 = "";
        var lib_path: ?[]const u8 = null;
        if (lib.object.get("downloads")) |downloads| {
            if (downloads.object.get("artifact")) |artifact| {
                if (artifact != .object) return error.InvalidLibraryMetadata;
                const artifact_url = artifact.object.get("url") orelse return error.InvalidLibraryMetadata;
                const artifact_path = artifact.object.get("path") orelse return error.InvalidLibraryMetadata;
                if (artifact_url != .string or artifact_path != .string) return error.InvalidLibraryMetadata;
                url = artifact_url.string;
                lib_path = artifact_path.string;
                if (artifact.object.get("sha1")) |hash| {
                    if (hash != .string or !isValidSha1Hex(hash.string)) return error.InvalidLibraryMetadata;
                    sha1 = hash.string;
                }
            }
        }
        if (lib_path == null) {
            const coordinate = lib.object.get("name") orelse return error.InvalidLibraryMetadata;
            if (coordinate != .string) return error.InvalidLibraryMetadata;
            const repository = lib.object.get("url") orelse return error.InvalidLibraryMetadata;
            if (repository != .string or !isValidModrinthDownloadUrl(repository.string)) return error.InvalidLibraryMetadata;
            allocated_path = try mavenCoordinatePath(allocator, coordinate.string) orelse continue;
            lib_path = allocated_path.?;
            const url_path = if (path.sep == '\\')
                try std.mem.replaceOwned(u8, allocator, allocated_path.?, "\\", "/")
            else
                try allocator.dupe(u8, allocated_path.?);
            defer allocator.free(url_path);
            allocated_url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
                std.mem.trimEnd(u8, repository.string, "/"),
                url_path,
            });
            url = allocated_url.?;
            if (lib.object.get("sha1")) |hash| {
                if (hash != .string or !isValidSha1Hex(hash.string)) return error.InvalidLibraryMetadata;
                sha1 = hash.string;
            }
        }

        const safe_relative_path = lib_path orelse continue;
        const normalized_path = if (path.sep == '\\')
            try std.mem.replaceOwned(u8, allocator, safe_relative_path, "\\", "/")
        else
            try allocator.dupe(u8, safe_relative_path);
        defer allocator.free(normalized_path);
        if (!isSafeModrinthPackPath(normalized_path)) return error.InvalidLibraryMetadata;
        const local_path = try path.join(allocator, &.{ McDir, "libraries", safe_relative_path });
        defer allocator.free(local_path);

        const download_url = try neoForgeLibraryDownloadUrl(allocator, url orelse return error.InvalidLibraryMetadata, neo_forge_maven_url);
        defer allocator.free(download_url);
        if (sha1.len == 0) {
            try checkAndDownload(allocator, io, download_url, local_path, "");
        } else {
            try queueDownload(allocator, io, &pending, download_url, local_path, sha1);
        }
    }
    std.debug.print("  待下载 Libraries: {}，并发数: {}\n", .{ pending.items.len, DownloadParallelism });
    try downloadPending(allocator, io, pending.items, DownloadParallelism);
}

fn downloadAssets(allocator: std.mem.Allocator, io: std.Io, instance_dir: []const u8, version_json: json.Value) !void {
    const asset_index_name = version_json.object.get("assets").?.string;
    const asset_index_url = version_json.object.get("assetIndex").?.object.get("url").?.string;
    const assets_dir = try path.join(allocator, &.{ instance_dir, "assets" });
    defer allocator.free(assets_dir);

    // 下载 asset index json
    const index_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{asset_index_name});
    defer allocator.free(index_filename);
    const index_local_path = try path.join(allocator, &.{ assets_dir, "indexes", index_filename });
    defer allocator.free(index_local_path);

    const asset_index_sha1 = version_json.object.get("assetIndex").?.object.get("sha1").?.string;
    try checkAndDownload(allocator, io, asset_index_url, index_local_path, asset_index_sha1);

    // 解析 asset index
    const index_str = try fs.cwd().readFileAlloc(io, index_local_path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(index_str);

    const index_json = try json.parseFromSlice(json.Value, allocator, index_str, .{});
    defer index_json.deinit();

    const objects = index_json.value.object.get("objects").?.object;
    var pending: std.ArrayList(DownloadItem) = .empty;
    defer freePendingDownloads(allocator, &pending);

    var it = objects.iterator();
    while (it.next()) |entry| {
        const hash = entry.value_ptr.object.get("hash").?.string;
        if (hash.len != Sha1.digest_length * 2) return error.InvalidAssetHash;
        const prefix = hash[0..2];

        const local_path = try path.join(allocator, &.{ assets_dir, "objects", prefix, hash });
        defer allocator.free(local_path);
        const url = try std.fmt.allocPrint(allocator, "https://resources.download.minecraft.net/{s}/{s}", .{ prefix, hash });
        defer allocator.free(url);
        try queueDownload(allocator, io, &pending, url, local_path, hash);
    }

    std.debug.print("  资源文件总数: {}，待下载: {}，并发数: {}\n", .{
        objects.count(),
        pending.items.len,
        AssetDownloadParallelism,
    });
    try downloadPending(allocator, io, pending.items, AssetDownloadParallelism);
}

const DownloadItem = struct {
    url: []u8,
    local_path: []u8,
    sha1: []u8,
};

fn downloadBatch(allocator: std.mem.Allocator, io: std.Io, assets: []const DownloadItem, parallelism_limit: usize) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    const parallelism = try std.fmt.allocPrint(allocator, "{d}", .{parallelism_limit});
    defer allocator.free(parallelism);
    const common_args = [_][]const u8{
        "curl",
        "--parallel",
        "--parallel-immediate",
        "--parallel-max",
        "--http1.1",
        "--user-agent",
        DownloadUserAgent,
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--retry",
        "5",
        "--retry-all-errors",
        "--retry-delay",
        "2",
        "--retry-max-time",
        "120",
        "--connect-timeout",
        "20",
        "--max-time",
        "300",
        "--continue-at",
        "-",
    };
    try argv.appendSlice(allocator, common_args[0..4]);
    try argv.append(allocator, parallelism);
    try argv.appendSlice(allocator, common_args[4..]);

    var temp_paths = try allocator.alloc([]u8, assets.len);
    defer {
        for (temp_paths) |temp_path| allocator.free(temp_path);
        allocator.free(temp_paths);
    }

    for (assets, 0..) |asset, index| {
        temp_paths[index] = try std.fmt.allocPrint(allocator, "{s}.part", .{asset.local_path});
        try argv.append(allocator, "--output");
        try argv.append(allocator, temp_paths[index]);
        try argv.append(allocator, asset.url);
    }

    std.debug.print("  并行下载 {}/{} 个资源...\n", .{ assets.len, assets.len });
    const result = process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        std.debug.print("curl 并行下载启动失败 ({s})，改为逐个断点续传。\n", .{@errorName(err)});
        for (assets) |asset| {
            try downloadFileWithResume(allocator, io, asset);
        }
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("curl 并行批次有下载失败 (exit code {})，验证文件并重试失败项。\n", .{code});
        },
        else => std.debug.print("curl 并行进程异常，验证文件并重试失败项。\n", .{}),
    }

    for (assets, temp_paths) |asset, temp_path| {
        if (fs.cwd().access(io, temp_path, .{})) |_| {
            if (try verifySha1(io, temp_path, asset.sha1)) {
                fs.cwd().deleteFile(io, asset.local_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                try fs.cwd().rename(temp_path, fs.cwd(), asset.local_path, io);
                continue;
            }
            try fs.cwd().deleteFile(io, temp_path);
        } else |_| {}

        try downloadFileWithResume(allocator, io, asset);
    }
}

fn downloadClientJar(allocator: std.mem.Allocator, io: std.Io, version_id: []const u8, version_json: json.Value) !void {
    const client_dl = version_json.object.get("downloads").?.object.get("client").?;
    const url = client_dl.object.get("url").?.string;
    const sha1 = client_dl.object.get("sha1").?.string;

    const filename = try std.fmt.allocPrint(allocator, "{s}.jar", .{version_id});
    defer allocator.free(filename);
    const local_path = try path.join(allocator, &.{ McDir, "versions", version_id, filename });
    defer allocator.free(local_path);

    if (fs.cwd().access(io, local_path, .{})) |_| {
        if (try verifySha1(io, local_path, sha1)) return;
    } else |_| {}

    const dir = path.dirname(local_path) orelse ".";
    try ensureDir(io, dir);

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.part", .{local_path});
    defer allocator.free(temp_path);

    std.debug.print("  下载 Client JAR: {s}（支持断点续传）\n", .{path.basename(local_path)});
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        const argv = [_][]const u8{
            "curl",
            "--http1.1",
            "--user-agent",
            DownloadUserAgent,
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--retry",
            "5",
            "--retry-all-errors",
            "--retry-connrefused",
            "--retry-delay",
            "1",
            "--retry-max-time",
            "120",
            "--connect-timeout",
            "20",
            "--max-time",
            "1800",
            "--continue-at",
            "-",
            "--output",
            temp_path,
            url,
        };

        const result = process.run(allocator, io, .{
            .argv = &argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| {
            std.debug.print("  Client JAR curl 启动失败（第 {}/3 次）: {s}\n", .{ attempt + 1, @errorName(err) });
            if (attempt == 2) return err;
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const curl_succeeded = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!curl_succeeded) {
            switch (result.term) {
                .exited => |code| std.debug.print("  Client JAR curl 失败（第 {}/3 次，退出码 {}）: {s}\n", .{
                    attempt + 1,
                    code,
                    result.stderr,
                }),
                else => std.debug.print("  Client JAR curl 进程异常（第 {}/3 次，状态 {s}）: {s}\n", .{
                    attempt + 1,
                    @tagName(result.term),
                    result.stderr,
                }),
            }
            continue;
        }

        if (!try verifySha1(io, temp_path, sha1)) {
            std.debug.print("  Client JAR SHA-1 不匹配（第 {}/3 次），删除临时文件后重试。\n", .{attempt + 1});
            fs.cwd().deleteFile(io, temp_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            continue;
        }

        fs.cwd().deleteFile(io, local_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try fs.cwd().rename(temp_path, fs.cwd(), local_path, io);
        return;
    }

    return error.ClientJarDownloadFailed;
}

fn launchGame(allocator: std.mem.Allocator, io: std.Io, version_id: []const u8, instance_dir: []const u8, player_name: []const u8, player_uuid: []const u8, version_json: json.Value, forge_json: ?json.Value) !void {
    // 1. 构建 Classpath
    var cp: std.ArrayList(u8) = .empty;
    defer cp.deinit(allocator);

    const cp_sep = if (@import("builtin").os.tag == .windows) ";" else ":";

    // 添加 client jar
    const client_jar_filename = try std.fmt.allocPrint(allocator, "{s}.jar", .{version_id});
    defer allocator.free(client_jar_filename);
    const client_jar_path = try path.join(allocator, &.{ McDir, "versions", version_id, client_jar_filename });
    defer allocator.free(client_jar_path);
    try cp.appendSlice(allocator, client_jar_path);

    try appendLibrariesToClasspath(allocator, &cp, cp_sep, version_json);
    if (forge_json) |profile| try appendLibrariesToClasspath(allocator, &cp, cp_sep, profile);

    const main_class = if (forge_json) |profile|
        profile.object.get("mainClass").?.string
    else
        version_json.object.get("mainClass").?.string;
    const base_arguments = version_json.object.get("arguments").?.object;
    const profile_arguments = if (forge_json) |profile| profile.object.get("arguments") else null;
    const base_game_args = base_arguments.get("game").?.array;
    const forge_game_args = if (profile_arguments) |arguments|
        arguments.object.get("game")
    else
        null;
    const launch_version_id = if (forge_json) |profile|
        (profile.object.get("id") orelse version_json.object.get("id").?).string
    else
        version_id;
    const jvm_args = if (profile_arguments) |arguments|
        arguments.object.get("jvm")
    else
        null;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var owned_argv_args: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_argv_args.items) |argument| allocator.free(argument);
        owned_argv_args.deinit(allocator);
    }

    try argv.append(allocator, "java");
    if (jvm_args) |args| {
        // Forge's ignoreList uses version_name + ".jar" to exclude the inherited vanilla client jar.
        const jvm_version_name = if (forge_json != null)
            version_json.object.get("id").?.string
        else
            launch_version_id;
        try appendLaunchArguments(allocator, &argv, &owned_argv_args, args.array, jvm_version_name, instance_dir, player_name, player_uuid, cp.items, version_json);
    }
    try argv.append(allocator, "-cp");
    try argv.append(allocator, cp.items);
    try argv.append(allocator, main_class);

    // 3. 解析并替换游戏参数
    try appendLaunchArguments(allocator, &argv, &owned_argv_args, base_game_args, launch_version_id, instance_dir, player_name, player_uuid, cp.items, version_json);
    if (forge_game_args) |arguments| {
        try appendLaunchArguments(allocator, &argv, &owned_argv_args, arguments.array, launch_version_id, instance_dir, player_name, player_uuid, cp.items, version_json);
    }

    // Keep the launcher's working directory so relative classpath entries remain valid.
    var child = try process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("Java 进程退出，状态码: {}\n", .{code});
            return error.JavaLaunchFailed;
        },
        else => return error.JavaLaunchFailed,
    }
}

fn appendLibrariesToClasspath(allocator: std.mem.Allocator, cp: *std.ArrayList(u8), cp_sep: []const u8, version_json: json.Value) !void {
    const libraries = version_json.object.get("libraries") orelse return;
    for (libraries.array.items) |library| {
        var relative_path: ?[]const u8 = null;
        if (library.object.get("downloads")) |downloads| {
            if (downloads.object.get("artifact")) |artifact| {
                relative_path = artifact.object.get("path").?.string;
            }
        }

        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |value| allocator.free(value);
        if (relative_path == null) {
            const coordinate = library.object.get("name") orelse continue;
            allocated_path = try mavenCoordinatePath(allocator, coordinate.string);
            relative_path = allocated_path;
        }
        if (try isLibraryOnModulePath(allocator, version_json, relative_path.?)) continue;

        const full_path = try path.join(allocator, &.{ McDir, "libraries", relative_path.? });
        defer allocator.free(full_path);
        try appendClasspathEntry(allocator, cp, cp_sep, full_path);
    }
}

fn appendClasspathEntry(
    allocator: std.mem.Allocator,
    classpath: *std.ArrayList(u8),
    separator: []const u8,
    entry: []const u8,
) !void {
    if (classpath.items.len > 0) {
        var entries = std.mem.splitScalar(u8, classpath.items, separator[0]);
        while (entries.next()) |existing| {
            if (std.mem.eql(u8, existing, entry)) return;
        }
        try classpath.appendSlice(allocator, separator);
    }
    try classpath.appendSlice(allocator, entry);
}

fn isLibraryOnModulePath(allocator: std.mem.Allocator, version_json: json.Value, relative_path: []const u8) !bool {
    const arguments = version_json.object.get("arguments") orelse return false;
    if (arguments != .object) return false;
    const jvm_arguments = arguments.object.get("jvm") orelse return false;
    if (jvm_arguments != .array) return false;

    const normalized_path = if (path.sep == '\\')
        try std.mem.replaceOwned(u8, allocator, relative_path, "\\", "/")
    else
        try allocator.dupe(u8, relative_path);
    defer allocator.free(normalized_path);
    const module_entry = try std.fmt.allocPrint(allocator, "${{library_directory}}/{s}", .{normalized_path});
    defer allocator.free(module_entry);

    const args = jvm_arguments.array.items;
    for (args, 0..) |argument, index| {
        if (argument != .string or (!std.mem.eql(u8, argument.string, "-p") and
            !std.mem.eql(u8, argument.string, "--module-path"))) continue;
        if (index + 1 >= args.len or args[index + 1] != .string) continue;
        var module_paths = std.mem.splitSequence(u8, args[index + 1].string, "${classpath_separator}");
        while (module_paths.next()) |module_path| {
            if (std.mem.eql(u8, module_path, module_entry)) return true;
        }
    }
    return false;
}

fn mavenCoordinatePath(allocator: std.mem.Allocator, coordinate: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, coordinate, ':');
    const group = parts.next() orelse return null;
    const artifact = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    const classifier = parts.next();
    if (parts.next() != null) return null;

    const group_path = try std.mem.replaceOwned(u8, allocator, group, ".", path.sep_str);
    defer allocator.free(group_path);
    if (classifier) |value| {
        return try std.fmt.allocPrint(allocator, "{s}{c}{s}{c}{s}{c}{s}-{s}-{s}.jar", .{
            group_path, path.sep, artifact, path.sep, version, path.sep, artifact, version, value,
        });
    }
    return try std.fmt.allocPrint(allocator, "{s}{c}{s}{c}{s}{c}{s}-{s}.jar", .{
        group_path, path.sep, artifact, path.sep, version, path.sep, artifact, version,
    });
}

fn appendLaunchArguments(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_argv_args: *std.ArrayList([]u8),
    arguments: json.Array,
    version_id: []const u8,
    instance_dir: []const u8,
    player_name: []const u8,
    player_uuid: []const u8,
    classpath: []const u8,
    version_json: json.Value,
) !void {
    const assets_root = try path.join(allocator, &.{ instance_dir, "assets" });
    defer allocator.free(assets_root);
    const libraries_root = try path.join(allocator, &.{ McDir, "libraries" });
    defer allocator.free(libraries_root);
    const version_type = if (version_json.object.get("type")) |value| value.string else "release";

    for (arguments.items) |argument| {
        if (argument != .string) continue;
        var replaced = try allocator.dupe(u8, argument.string);
        defer allocator.free(replaced);

        try replaceInPlace(allocator, &replaced, "${auth_player_name}", player_name);
        try replaceInPlace(allocator, &replaced, "${version_name}", version_id);
        try replaceInPlace(allocator, &replaced, "${game_directory}", instance_dir);
        try replaceInPlace(allocator, &replaced, "${assets_root}", assets_root);
        if (version_json.object.get("assets")) |assets|
            try replaceInPlace(allocator, &replaced, "${assets_index_name}", assets.string);
        try replaceInPlace(allocator, &replaced, "${auth_uuid}", player_uuid);
        try replaceInPlace(allocator, &replaced, "${auth_access_token}", "0");
        try replaceInPlace(allocator, &replaced, "${user_properties}", "{}");
        try replaceInPlace(allocator, &replaced, "${auth_xuid}", "0");
        try replaceInPlace(allocator, &replaced, "${clientid}", "0");
        try replaceInPlace(allocator, &replaced, "${user_type}", "legacy");
        try replaceInPlace(allocator, &replaced, "${version_type}", version_type);
        try replaceInPlace(allocator, &replaced, "${classpath}", classpath);
        try replaceInPlace(allocator, &replaced, "${classpath_separator}", if (@import("builtin").os.tag == .windows) ";" else ":");
        try replaceInPlace(allocator, &replaced, "${library_directory}", libraries_root);

        const owned_argument = try allocator.dupe(u8, replaced);
        errdefer allocator.free(owned_argument);
        try argv.append(allocator, owned_argument);
        try owned_argv_args.append(allocator, owned_argument);
    }
}

test "offline UUID uses Minecraft's Java-compatible name UUID" {
    const uuid = try offlineUuid(std.testing.allocator, "Notch");
    defer std.testing.allocator.free(uuid);
    try std.testing.expectEqualStrings("b50ad385829d3141a2167e7d7539ba7f", uuid);
}

test "offline player names use Minecraft username characters" {
    try std.testing.expect(isValidPlayerName("Steve_123"));
    try std.testing.expect(!isValidPlayerName("ab"));
    try std.testing.expect(!isValidPlayerName("name with space"));
}

test "asset SHA-1 validation rejects corrupt downloads" {
    try std.testing.expect(sha1Matches("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"));
    try std.testing.expect(!sha1Matches("abd", "a9993e364706816aba3e25717850c26c9cd0d89d"));
    try std.testing.expect(!sha1Matches("abc", "invalid"));
}

test "Forge version argument rejects path characters" {
    try std.testing.expect(isValidForgeVersion("47.4.10"));
    try std.testing.expect(!isValidForgeVersion("../installer"));
}

test "version IDs reject path traversal and separators" {
    try std.testing.expect(isValidVersionId("1.20.1"));
    try std.testing.expect(isValidVersionId("1.20.1-forge-47.4.10"));
    try std.testing.expect(!isValidVersionId("../libraries"));
    try std.testing.expect(!isValidVersionId("nested/version"));
    try std.testing.expect(!isValidVersionId(".."));
}

test "mod management accepts Forge, NeoForge, Fabric instances and safe jar names" {
    try std.testing.expect(isForgeInstanceId("1.20.1-forge-47.4.10"));
    try std.testing.expect(isNeoForgeInstanceId("1.21.1-neoforge-21.1.172"));
    try std.testing.expect(isFabricInstanceId("1.21.1-fabric-0.16.5"));
    try std.testing.expect(!isForgeInstanceId("1.20.1"));
    try std.testing.expect(!isForgeInstanceId("../forge-47.4.10"));
    try std.testing.expect(!isNeoForgeInstanceId("../neoforge-21.1.172"));
    try std.testing.expect(!isFabricInstanceId("../fabric-0.16.5"));
    try std.testing.expect(isValidModFileName("example-mod_1.0.jar"));
    try std.testing.expect(isValidModFileName("EXAMPLE.JAR"));
    try std.testing.expect(!isValidModFileName("../example.jar"));
    try std.testing.expect(!isValidModFileName("example.zip"));
}

test "NeoForge supports Minecraft 1.20.1 and newer" {
    try std.testing.expect(!isNeoForgeMinecraftSupported("1.20"));
    try std.testing.expect(!isNeoForgeMinecraftSupported("1.20.0"));
    try std.testing.expect(isNeoForgeMinecraftSupported("1.20.1"));
    try std.testing.expect(isNeoForgeMinecraftSupported("1.21"));
    try std.testing.expect(isNeoForgeMinecraftSupported("1.21.1"));
    try std.testing.expect(!isNeoForgeMinecraftSupported("invalid"));
}

test "NeoForge Maven versions are selected for their Minecraft version" {
    const xml =
        \\<metadata><versioning><versions>
        \\<version>20.4.237</version>
        \\<version>21.1.172</version>
        \\<version>1.20.1-47.1.106</version>
        \\</versions></versioning></metadata>
    ;
    const latest_1211 = try selectNeoForgeVersion(std.testing.allocator, xml, "1.21.1");
    defer std.testing.allocator.free(latest_1211);
    try std.testing.expectEqualStrings("21.1.172", latest_1211);

    const legacy_1201 = try selectNeoForgeVersion(std.testing.allocator, xml, "1.20.1");
    defer std.testing.allocator.free(legacy_1201);
    try std.testing.expectEqualStrings("1.20.1-47.1.106", legacy_1201);

    try std.testing.expectError(
        error.NeoForgeVersionNotFound,
        selectNeoForgeVersion(std.testing.allocator, xml, "1.19.4"),
    );
}

test "NeoForge profiles are accepted only with required launch metadata" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"id\":\"neoforge-21.1.172\",\"mainClass\":\"cpw.mods.bootstraplauncher.BootstrapLauncher\",\"libraries\":[],\"arguments\":{\"game\":[\"--fml.neoForgeVersion\",\"21.1.172\"]}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(isUsableNeoForgeProfile(parsed.value, "neoforge-21.1.172"));
    try std.testing.expect(!isUsableNeoForgeProfile(parsed.value, "neoforge-21.1.173"));
}

test "Forge profiles accept bootstrap profiles with launch metadata and libraries" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"id\":\"26.3-forge-66.0.13\",\"mainClass\":\"net.minecraftforge.bootstrap.ForgeBootstrap\",\"libraries\":[{\"name\":\"net.minecraftforge:forge:26.3-66.0.13:client\"}],\"arguments\":{\"game\":[\"--launchTarget\",\"forge_client\"]}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(isUsableForgeProfile(parsed.value, "26.3-forge-66.0.13"));
    try std.testing.expect(!isUsableForgeProfile(parsed.value, "26.3-forge-66.0.14"));

    const incomplete = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"id\":\"26.3-forge-66.0.13\",\"mainClass\":\"net.minecraftforge.bootstrap.ForgeBootstrap\",\"arguments\":{\"game\":[]}}",
        .{},
    );
    defer incomplete.deinit();
    try std.testing.expect(!isUsableForgeProfile(incomplete.value, "26.3-forge-66.0.13"));
}

test "NeoForge client profile exposes its NeoForm mapping version" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"arguments\":{\"game\":[\"--fml.neoForgeVersion\",\"21.1.249\",\"--fml.neoFormVersion\",\"20240808.144430\"]}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("20240808.144430", neoForgeMappingsVersion(parsed.value).?);

    const incomplete = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"arguments\":{\"game\":[\"--fml.neoForgeVersion\",\"21.1.249\"]}}",
        .{},
    );
    defer incomplete.deinit();
    try std.testing.expect(neoForgeMappingsVersion(incomplete.value) == null);
}

test "NeoForge installer cache accepts ZIP/JAR signatures only" {
    try std.testing.expect(isZipHeader("PK\x03\x04"));
    try std.testing.expect(isZipHeader("PK\x05\x06"));
    try std.testing.expect(isZipHeader("PK\x07\x08"));
    try std.testing.expect(!isZipHeader("PK\x03\x06"));
    try std.testing.expect(!isZipHeader("HTML"));
    try std.testing.expect(!isZipHeader("PK"));
}

test "NeoForge artifact URLs honor a secure configurable Maven base" {
    const allocator = std.testing.allocator;
    const default_url = try neoForgeArtifactUrl(
        allocator,
        DefaultNeoForgeMavenUrl,
        "net/neoforged/neoforge/21.1.249/neoforge-21.1.249-installer.jar",
    );
    defer allocator.free(default_url);
    try std.testing.expectEqualStrings(
        "https://neoforged.forgecdn.net/releases/net/neoforged/neoforge/21.1.249/neoforge-21.1.249-installer.jar",
        default_url,
    );

    const mirror_url = try neoForgeArtifactUrl(
        allocator,
        "https://mirror.example/maven/",
        "net/neoforged/neoforge/maven-metadata.xml",
    );
    defer allocator.free(mirror_url);
    try std.testing.expectEqualStrings(
        "https://mirror.example/maven/net/neoforged/neoforge/maven-metadata.xml",
        mirror_url,
    );
    try std.testing.expectError(
        error.InvalidNeoForgeMavenUrl,
        neoForgeArtifactUrl(allocator, "http://insecure.example/maven", "artifact.jar"),
    );
    try std.testing.expectError(
        error.InvalidNeoForgeArtifactPath,
        neoForgeArtifactUrl(allocator, DefaultNeoForgeMavenUrl, "../installer.jar"),
    );
}

test "NeoForge library URLs use the configured Maven mirror" {
    const allocator = std.testing.allocator;
    const forge_url = try neoForgeLibraryDownloadUrl(
        allocator,
        "https://maven.neoforged.net/releases/net/minecraftforge/srgutils/0.4.15/srgutils-0.4.15.jar",
        DefaultNeoForgeMavenUrl,
    );
    defer allocator.free(forge_url);
    try std.testing.expectEqualStrings(
        "https://maven.minecraftforge.net/net/minecraftforge/srgutils/0.4.15/srgutils-0.4.15.jar",
        forge_url,
    );

    const mirrored_url = try neoForgeLibraryDownloadUrl(
        allocator,
        "https://maven.neoforged.net/releases/net/neoforged/fancymodloader/earlydisplay/4.0.44/earlydisplay-4.0.44.jar",
        DefaultNeoForgeMavenUrl,
    );
    defer allocator.free(mirrored_url);
    try std.testing.expectEqualStrings(
        "https://neoforged.forgecdn.net/releases/net/neoforged/fancymodloader/earlydisplay/4.0.44/earlydisplay-4.0.44.jar",
        mirrored_url,
    );

    const unrelated_url = try neoForgeLibraryDownloadUrl(
        allocator,
        "https://libraries.minecraft.net/com/example/library.jar",
        DefaultNeoForgeMavenUrl,
    );
    defer allocator.free(unrelated_url);
    try std.testing.expectEqualStrings(
        "https://libraries.minecraft.net/com/example/library.jar",
        unrelated_url,
    );
}

test "libraries on the NeoForge module path are excluded from classpath" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"arguments\":{\"jvm\":[\"-p\",\"${library_directory}/cpw/mods/bootstraplauncher/2.0.2/bootstraplauncher-2.0.2.jar${classpath_separator}${library_directory}/cpw/mods/securejarhandler/3.0.8/securejarhandler-3.0.8.jar\",\"--add-modules\",\"ALL-MODULE-PATH\"]}}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expect(try isLibraryOnModulePath(
        std.testing.allocator,
        parsed.value,
        "cpw/mods/bootstraplauncher/2.0.2/bootstraplauncher-2.0.2.jar",
    ));
    try std.testing.expect(try isLibraryOnModulePath(
        std.testing.allocator,
        parsed.value,
        "cpw/mods/securejarhandler/3.0.8/securejarhandler-3.0.8.jar",
    ));
    try std.testing.expect(!try isLibraryOnModulePath(
        std.testing.allocator,
        parsed.value,
        "net/neoforged/fancymodloader/loader/4.0.44/loader-4.0.44.jar",
    ));
}

test "duplicate library paths are added to the classpath only once" {
    const allocator = std.testing.allocator;
    var classpath: std.ArrayList(u8) = .empty;
    defer classpath.deinit(allocator);

    try appendClasspathEntry(allocator, &classpath, ";", "client.jar");
    try appendClasspathEntry(allocator, &classpath, ";", "libraries/gson.jar");
    try appendClasspathEntry(allocator, &classpath, ";", "libraries/gson.jar");
    try appendClasspathEntry(allocator, &classpath, ";", "libraries/loader.jar");

    try std.testing.expectEqualStrings(
        "client.jar;libraries/gson.jar;libraries/loader.jar",
        classpath.items,
    );
}

test "Forge supports Minecraft versions from 1.13 when present in its release list" {
    try std.testing.expect(!isForgeMinecraftSupported("1.12.2"));
    try std.testing.expect(!isForgeMinecraftSupported("1.7.10"));
    try std.testing.expect(isForgeMinecraftSupported("1.13"));
    try std.testing.expect(isForgeMinecraftSupported("1.20.1"));
    try std.testing.expect(isForgeMinecraftSupported("26.1"));
    try std.testing.expect(!isForgeMinecraftSupported("invalid"));
}

test "Forge version selection prefers recommended and falls back to latest" {
    const allocator = std.testing.allocator;
    const promotions = try json.parseFromSlice(
        json.Value,
        allocator,
        "{\"promos\":{\"1.20.1-recommended\":\"47.4.10\",\"1.20.1-latest\":\"47.4.26\",\"1.20.4-latest\":\"49.2.8\"}}",
        .{},
    );
    defer promotions.deinit();

    const recommended = try selectForgeVersion(allocator, promotions.value, "1.20.1");
    defer allocator.free(recommended);
    try std.testing.expectEqualStrings("47.4.10", recommended);

    const latest = try selectForgeVersion(allocator, promotions.value, "1.20.4");
    defer allocator.free(latest);
    try std.testing.expectEqualStrings("49.2.8", latest);

    try std.testing.expectError(error.ForgeVersionNotFound, selectForgeVersion(allocator, promotions.value, "1.20.5"));
}

test "Forge Maven coordinates map to library jar paths" {
    const plain = (try mavenCoordinatePath(std.testing.allocator, "net.minecraftforge:forge:1.20.1-47.4.10")).?;
    defer std.testing.allocator.free(plain);
    const expected_plain = try std.fmt.allocPrint(std.testing.allocator, "net{c}minecraftforge{c}forge{c}1.20.1-47.4.10{c}forge-1.20.1-47.4.10.jar", .{ path.sep, path.sep, path.sep, path.sep });
    defer std.testing.allocator.free(expected_plain);
    try std.testing.expectEqualStrings(expected_plain, plain);

    const classified = (try mavenCoordinatePath(std.testing.allocator, "org.example:sample:1.0:natives-windows")).?;
    defer std.testing.allocator.free(classified);
    const expected_classified = try std.fmt.allocPrint(std.testing.allocator, "org{c}example{c}sample{c}1.0{c}sample-1.0-natives-windows.jar", .{ path.sep, path.sep, path.sep, path.sep });
    defer std.testing.allocator.free(expected_classified);
    try std.testing.expectEqualStrings(expected_classified, classified);
}

test "Forge launch arguments retain required vanilla arguments" {
    const allocator = std.testing.allocator;
    const vanilla = try json.parseFromSlice(json.Value, allocator, "[\"--accessToken\", \"${auth_access_token}\", \"--version\", \"${version_name}\", \"--gameDir\", \"${game_directory}\", \"--assetsDir\", \"${assets_root}\"]", .{});
    defer vanilla.deinit();
    const forge = try json.parseFromSlice(json.Value, allocator, "[\"--launchTarget\", \"forgeclient\"]", .{});
    defer forge.deinit();
    const metadata = try json.parseFromSlice(json.Value, allocator, "{\"type\":\"release\",\"assets\":\"1.20.1\"}", .{});
    defer metadata.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var owned_args: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_args.items) |argument| allocator.free(argument);
        owned_args.deinit(allocator);
    }

    try appendLaunchArguments(allocator, &argv, &owned_args, vanilla.value.array, "1.20.1-forge-47.4.10", ".minecraft/instances/test", "Steve", "offline-uuid", "classpath", metadata.value);
    try appendLaunchArguments(allocator, &argv, &owned_args, forge.value.array, "1.20.1-forge-47.4.10", ".minecraft/instances/test", "Steve", "offline-uuid", "classpath", metadata.value);

    try std.testing.expectEqualStrings("--accessToken", argv.items[0]);
    try std.testing.expectEqualStrings("0", argv.items[1]);
    try std.testing.expectEqualStrings("--version", argv.items[2]);
    try std.testing.expectEqualStrings("1.20.1-forge-47.4.10", argv.items[3]);
    try std.testing.expectEqualStrings("--gameDir", argv.items[4]);
    try std.testing.expectEqualStrings(".minecraft/instances/test", argv.items[5]);
    try std.testing.expectEqualStrings("--assetsDir", argv.items[6]);
    const expected_assets_root = try path.join(allocator, &.{ ".minecraft/instances/test", "assets" });
    defer allocator.free(expected_assets_root);
    try std.testing.expectEqualStrings(expected_assets_root, argv.items[7]);
    try std.testing.expectEqualStrings("--launchTarget", argv.items[8]);
    try std.testing.expectEqualStrings("forgeclient", argv.items[9]);
}

test "vanilla and Forge versions get separate instance IDs" {
    const vanilla = try makeInstanceId(std.testing.allocator, "1.20.1", null);
    defer std.testing.allocator.free(vanilla);
    const forge = try makeInstanceId(std.testing.allocator, "1.20.1", "47.4.10");
    defer std.testing.allocator.free(forge);

    try std.testing.expectEqualStrings("1.20.1", vanilla);
    try std.testing.expectEqualStrings("1.20.1-forge-47.4.10", forge);
    try std.testing.expect(!std.mem.eql(u8, vanilla, forge));
}

test "Forge, NeoForge, and Fabric get distinct loader instance IDs" {
    const forge = try makeLoaderInstanceId(std.testing.allocator, "1.20.1", .forge, "47.4.10");
    defer std.testing.allocator.free(forge);
    const neoforge = try makeLoaderInstanceId(std.testing.allocator, "1.21.1", .neoforge, "21.1.172");
    defer std.testing.allocator.free(neoforge);
    const fabric = try makeLoaderInstanceId(std.testing.allocator, "1.21.1", .fabric, "0.16.5");
    defer std.testing.allocator.free(fabric);

    try std.testing.expectEqualStrings("1.20.1-forge-47.4.10", forge);
    try std.testing.expectEqualStrings("1.21.1-neoforge-21.1.172", neoforge);
    try std.testing.expectEqualStrings("1.21.1-fabric-0.16.5", fabric);
    const mods_path = try instanceModsPath(std.testing.allocator, neoforge);
    defer std.testing.allocator.free(mods_path);
    const expected_path = try path.join(std.testing.allocator, &.{
        McDir,
        "instances",
        "1.21.1-neoforge-21.1.172",
        "mods",
    });
    defer std.testing.allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, mods_path);
    const fabric_mods_path = try instanceModsPath(std.testing.allocator, fabric);
    defer std.testing.allocator.free(fabric_mods_path);
    const expected_fabric_mods_path = try path.join(std.testing.allocator, &.{
        McDir,
        "instances",
        "1.21.1-fabric-0.16.5",
        "mods",
    });
    defer std.testing.allocator.free(expected_fabric_mods_path);
    try std.testing.expectEqualStrings(expected_fabric_mods_path, fabric_mods_path);
    try std.testing.expectError(
        error.LoaderVersionRequired,
        makeLoaderInstanceId(std.testing.allocator, "1.21.1", .neoforge, null),
    );
}

test "pack metadata detects Minecraft and Forge versions from CurseForge manifests" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"minecraft\":{\"version\":\"1.20.1\",\"modLoaders\":[{\"id\":\"forge-47.4.10\",\"primary\":true}]},\"files\":[{\"projectID\":1,\"fileID\":2}]}",
        .{},
    );
    defer parsed.deinit();

    var metadata = try parseCurseForgeMetadata(std.testing.allocator, parsed.value);
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1.20.1", metadata.minecraft_version.?);
    try std.testing.expectEqual(ModLoader.forge, metadata.loader.?);
    try std.testing.expectEqualStrings("47.4.10", metadata.loader_version.?);
    try std.testing.expect(metadata.has_external_files);
}

test "pack metadata detects NeoForge from CurseForge manifests" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"minecraft\":{\"version\":\"1.21.1\",\"modLoaders\":[{\"id\":\"neoforge-21.1.172\",\"primary\":true}]}}",
        .{},
    );
    defer parsed.deinit();

    var metadata = try parseCurseForgeMetadata(std.testing.allocator, parsed.value);
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1.21.1", metadata.minecraft_version.?);
    try std.testing.expectEqual(ModLoader.neoforge, metadata.loader.?);
    try std.testing.expectEqualStrings("21.1.172", metadata.loader_version.?);
}

test "pack metadata detects MultiMC versions and flags unsupported loaders" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"components\":[{\"uid\":\"net.minecraft\",\"version\":\"1.19.2\"},{\"uid\":\"org.quiltmc.quilt-loader\",\"version\":\"0.27.1\"}]}",
        .{},
    );
    defer parsed.deinit();

    var metadata = try parseMmcPackMetadata(std.testing.allocator, parsed.value);
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1.19.2", metadata.minecraft_version.?);
    try std.testing.expectEqualStrings("org.quiltmc.quilt-loader", metadata.unsupported_loader.?);
}

test "Fabric Loader versions select the latest stable release" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "[{\"loader\":{\"version\":\"0.20.1\",\"stable\":false}},{\"loader\":{\"version\":\"0.16.5\",\"stable\":true}},{\"loader\":{\"version\":\"0.15.11\",\"stable\":true}}]",
        .{},
    );
    defer parsed.deinit();
    const version = try selectFabricLoaderVersion(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("0.16.5", version);

    const no_stable = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "[{\"loader\":{\"version\":\"0.20.1\",\"stable\":false}},{\"loader\":{\"version\":\"0.19.0\",\"stable\":false}}]",
        .{},
    );
    defer no_stable.deinit();
    const latest = try selectFabricLoaderVersion(std.testing.allocator, no_stable.value);
    defer std.testing.allocator.free(latest);
    try std.testing.expectEqualStrings("0.20.1", latest);
}

test "Fabric launcher profiles require matching Minecraft and loader versions" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"id\":\"fabric-loader-0.16.5-1.21.1\",\"inheritsFrom\":\"1.21.1\",\"mainClass\":\"net.fabricmc.loader.impl.launch.knot.KnotClient\",\"libraries\":[{\"name\":\"net.fabricmc:fabric-loader:0.16.5\",\"url\":\"https://maven.fabricmc.net/\"}],\"arguments\":{\"game\":[],\"jvm\":[\"-DFabricMcEmu= net.minecraft.client.main.Main \"]}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(isUsableFabricProfile(parsed.value, "1.21.1", "0.16.5"));
    try std.testing.expect(!isUsableFabricProfile(parsed.value, "1.20.1", "0.16.5"));
    try std.testing.expect(!isUsableFabricProfile(parsed.value, "1.21.1", "0.16.6"));
}

test "Modrinth and CurseForge metadata detect Fabric Loader" {
    const modrinth = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"dependencies\":{\"minecraft\":\"1.21.1\",\"fabric\":\"0.16.5\"}}",
        .{},
    );
    defer modrinth.deinit();
    var modrinth_metadata = try parseModrinthMetadata(std.testing.allocator, modrinth.value);
    defer modrinth_metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModLoader.fabric, modrinth_metadata.loader.?);
    try std.testing.expectEqualStrings("0.16.5", modrinth_metadata.loader_version.?);

    const curseforge = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"minecraft\":{\"version\":\"1.21.1\",\"modLoaders\":[{\"id\":\"fabric-0.16.5\",\"primary\":true}]}}",
        .{},
    );
    defer curseforge.deinit();
    var curseforge_metadata = try parseCurseForgeMetadata(std.testing.allocator, curseforge.value);
    defer curseforge_metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModLoader.fabric, curseforge_metadata.loader.?);
    try std.testing.expectEqualStrings("0.16.5", curseforge_metadata.loader_version.?);

    const multimc = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"components\":[{\"uid\":\"net.minecraft\",\"version\":\"1.21.1\"},{\"uid\":\"net.fabricmc.fabric-loader\",\"version\":\"0.16.5\"}]}",
        .{},
    );
    defer multimc.deinit();
    var multimc_metadata = try parseMmcPackMetadata(std.testing.allocator, multimc.value);
    defer multimc_metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModLoader.fabric, multimc_metadata.loader.?);
    try std.testing.expectEqualStrings("0.16.5", multimc_metadata.loader_version.?);
}

test "pack metadata detects Minecraft and Forge versions from Modrinth indexes" {
    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"dependencies\":{\"minecraft\":\"1.20.1\",\"forge\":\"47.4.10\"},\"files\":[{\"path\":\"mods/example.jar\"}]}",
        .{},
    );
    defer parsed.deinit();

    var metadata = try parseModrinthMetadata(std.testing.allocator, parsed.value);
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1.20.1", metadata.minecraft_version.?);
    try std.testing.expectEqual(ModLoader.forge, metadata.loader.?);
    try std.testing.expectEqualStrings("47.4.10", metadata.loader_version.?);
    try std.testing.expect(metadata.has_external_files);
}

test "pack metadata detects NeoForge from MultiMC and Modrinth manifests" {
    const mmc = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"components\":[{\"uid\":\"net.minecraft\",\"version\":\"1.21.1\"},{\"uid\":\"net.neoforged\",\"version\":\"21.1.172\"}]}",
        .{},
    );
    defer mmc.deinit();

    var mmc_metadata = try parseMmcPackMetadata(std.testing.allocator, mmc.value);
    defer mmc_metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModLoader.neoforge, mmc_metadata.loader.?);
    try std.testing.expectEqualStrings("21.1.172", mmc_metadata.loader_version.?);

    const modrinth = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "{\"dependencies\":{\"minecraft\":\"1.21.1\",\"neoforge\":\"21.1.172\"}}",
        .{},
    );
    defer modrinth.deinit();

    var modrinth_metadata = try parseModrinthMetadata(std.testing.allocator, modrinth.value);
    defer modrinth_metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModLoader.neoforge, modrinth_metadata.loader.?);
    try std.testing.expectEqualStrings("21.1.172", modrinth_metadata.loader_version.?);
}

test "Modrinth indexed paths reject absolute and parent traversal paths" {
    try std.testing.expect(isSafeModrinthPackPath("mods/example.jar"));
    try std.testing.expect(isSafeModrinthPackPath("config/example.json"));
    try std.testing.expect(!isSafeModrinthPackPath("../outside.jar"));
    try std.testing.expect(!isSafeModrinthPackPath("mods/../../outside.jar"));
    try std.testing.expect(!isSafeModrinthPackPath("/absolute.jar"));
    try std.testing.expect(!isSafeModrinthPackPath("C:/outside.jar"));
    try std.testing.expect(!isSafeModrinthPackPath("mods\\outside.jar"));
    try std.testing.expect(!isSafeModrinthPackPath("mods//outside.jar"));
}

test "Modrinth file URLs require HTTPS and prefer the Modrinth CDN mirror" {
    try std.testing.expect(isValidModrinthDownloadUrl("https://cdn.modrinth.com/data/example.jar"));
    try std.testing.expect(!isValidModrinthDownloadUrl("http://cdn.modrinth.com/data/example.jar"));
    try std.testing.expect(!isValidModrinthDownloadUrl("https://user@cdn.modrinth.com/data/example.jar"));
    try std.testing.expect(!isValidModrinthDownloadUrl("https:///data/example.jar"));

    const parsed = try json.parseFromSlice(
        json.Value,
        std.testing.allocator,
        "[\"https://edge.forgecdn.net/files/example.jar\",\"https://cdn.modrinth.com/data/example.jar\"]",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "https://cdn.modrinth.com/data/example.jar",
        try chooseModrinthDownloadUrl(parsed.value),
    );
}

test "Modrinth client environment includes required and optional files only" {
    const required = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"env\":{\"client\":\"required\"}}", .{});
    defer required.deinit();
    const optional = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"env\":{\"client\":\"optional\"}}", .{});
    defer optional.deinit();
    const unsupported = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"env\":{\"client\":\"unsupported\"}}", .{});
    defer unsupported.deinit();
    const unspecified = try json.parseFromSlice(json.Value, std.testing.allocator, "{}", .{});
    defer unspecified.deinit();

    try std.testing.expect(try shouldDownloadModrinthClientFile(required.value));
    try std.testing.expect(try shouldDownloadModrinthClientFile(optional.value));
    try std.testing.expect(!try shouldDownloadModrinthClientFile(unsupported.value));
    try std.testing.expect(try shouldDownloadModrinthClientFile(unspecified.value));
}

test "Modrinth SHA-1 values must be 40 hexadecimal characters" {
    try std.testing.expect(isValidSha1Hex("3d1bc31982eff30195e3a58247774b5136459e8d"));
    try std.testing.expect(isValidSha1Hex("3D1BC31982EFF30195E3A58247774B5136459E8D"));
    try std.testing.expect(!isValidSha1Hex("not-a-hash"));
    try std.testing.expect(!isValidSha1Hex("3d1bc31982eff30195e3a58247774b5136459e8x"));
}
