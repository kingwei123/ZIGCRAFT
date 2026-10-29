# Zig 极简 Minecraft 启动器

`zig-mc` 是一个用 Zig 编写的命令行 Minecraft 启动器。它可以下载并启动原版 Minecraft，安装 Forge、NeoForge 或 Fabric，并导入常见格式的整合包。

## 功能

- 下载 Minecraft 版本文件、游戏资源和依赖库，然后启动游戏。
- 安装并启动 Forge、NeoForge 和 Fabric 实例。
- 导入 CurseForge、MultiMC 和 Modrinth 清单格式的 `.zip` 整合包。
- 列出、删除已安装的实例；在实例之间独立管理 mod。
- 并行下载游戏文件，并校验资源文件的 SHA-1。

加载器支持范围：

| 加载器 | 支持范围 |
| --- | --- |
| Forge | Minecraft 1.13 及以上，限 Forge 官方发布的版本 |
| NeoForge | Minecraft 1.20.1 及以上的正式版本；按官方 Maven 元数据匹配可用版本，包含 1.20.x、1.21.x 及后续版本号格式 |
| Fabric | Fabric Loader 官方元数据提供的 Minecraft 版本 |

## 环境要求

- **运行**：可用的 Java 运行时和 `curl`，两者都需要能从 `PATH` 找到。所需 Java 版本取决于 Minecraft 及加载器版本；`curl` 用于下载游戏文件和元数据。在 Debian 13 上可运行 `sudo apt install curl` 安装。
- **Java 选择**：可设置 `MC_JAVA_HOME` 指定启动 Minecraft 使用的 Java 安装目录；未设置时使用 `JAVA_HOME`，两者都未设置则使用 `PATH` 中的 `java`。Minecraft 1.20.1 的 Forge/NeoForge 建议使用 Java 17；启动器会拒绝 Java 17 以下或 Java 20 以上的运行时。例如：

```powershell
$env:MC_JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-17"
.\zig-out\bin\zig-mc.exe 1.20.1 Steve --neoforge
```
- **安装或导入游戏**：需要互联网连接。
- **从源码构建**：Zig 0.16.0。

## 构建

在项目根目录运行：

```powershell
zig build
```

可执行文件生成在 `zig-out\bin\zig-mc.exe`。使用 ReleaseFast 优化构建：

```powershell
zig build -Doptimize=ReleaseFast
```

运行单元测试：

```powershell
zig test src\main.zig
```

## 使用

从项目根目录运行程序，或将其所在目录加入 `PATH`。在现有 `.minecraft` 目录下运行时，程序会向上查找并使用该目录；实例文件保存在 `.minecraft/instances/<实例ID>` 中。

### 启动 Minecraft

```powershell
.\zig-out\bin\zig-mc.exe <版本号> [离线用户名] [--forge [版本] | --neoforge [版本] | --fabric [版本]]
```

示例：

```powershell
# 启动原版 1.20.1，默认离线用户名为 Steve
.\zig-out\bin\zig-mc.exe 1.20.1

# 使用离线用户名 Alex 启动 Fabric
.\zig-out\bin\zig-mc.exe 1.20.1 Alex --fabric

# 指定 NeoForge 版本
.\zig-out\bin\zig-mc.exe 1.20.1 Alex --neoforge 21.1.172
```

离线用户名只能包含英文字母、数字和下划线，长度为 3 到 16 个字符。本程序不提供 Microsoft 账户登录；离线身份不能用于需要正版账户验证的服务器。

### 导入整合包

```powershell
.\zig-out\bin\zig-mc.exe --import-pack <整合包.zip> [Minecraft版本] [--forge|--neoforge|--fabric <加载器版本>]
```

程序会尝试从整合包清单识别 Minecraft 和加载器版本。也可以显式指定版本及加载器：

```powershell
.\zig-out\bin\zig-mc.exe --import-pack .\pack.zip 1.20.1 --fabric 0.16.9
```

### 管理实例和 mod

```powershell
# 列出已安装实例
.\zig-out\bin\zig-mc.exe --list-versions

# 删除实例
.\zig-out\bin\zig-mc.exe --delete-version <实例ID>

# 列出指定加载器实例中的 mod
.\zig-out\bin\zig-mc.exe --list-mods <加载器实例ID>

# 安装 mod JAR
.\zig-out\bin\zig-mc.exe --install-mod <加载器实例ID> .\example-mod.jar

# 删除指定 mod JAR
.\zig-out\bin\zig-mc.exe --delete-mod <加载器实例ID> <mod文件名.jar>
```

不带参数运行程序可查看命令帮助。Forge 安装器从 Forge 官方 Maven 源下载。NeoForge 资源下载可通过 `NEOFORGED_MAVEN_URL` 配置 Maven 镜像地址。Windows 上若 curl 明确报告证书吊销服务器脱机，程序会使用 Schannel 的 `--ssl-no-revoke` 选项重试；此选项仅跳过吊销状态检查，不会关闭 TLS 证书验证。

旧版曾使用 `FORGE_MAVEN_URL` 配置 Forge 镜像；新版已不再读取此变量。如需删除当前 PowerShell 会话中的变量：

```powershell
Remove-Item Env:FORGE_MAVEN_URL -ErrorAction SilentlyContinue
```

如需永久删除当前用户的变量：

```powershell
[Environment]::SetEnvironmentVariable("FORGE_MAVEN_URL", $null, "User")
```

如果它是系统变量，请以管理员身份打开 PowerShell 并执行：

```powershell
[Environment]::SetEnvironmentVariable("FORGE_MAVEN_URL", $null, "Machine")
```

删除后重新打开终端和启动器，使更改生效。

## GitHub 工程

GitHub Actions 会在推送、Pull Request 和手动触发时，使用 Zig 0.16.0 在 Windows、Linux 和 macOS 上构建并运行单元测试。提交问题前，请先确认使用的 Zig 版本，并附上复现步骤和相关日志；请勿在 Issue 中提交账户凭据或其他敏感信息。

## 免责声明

本项目与 Mojang Studios 或 Microsoft 无关，也未获其认可。Minecraft 是其各自权利人的商标。
