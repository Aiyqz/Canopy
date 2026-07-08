# 🌿 Canopy（灵动岛歌词 · 中文说明）

一个专注效率的 **macOS 灵动岛体验**：原生 SwiftUI 应用，把 Mac 的刘海/灵动岛包成一个媒体控制器，带时间同步歌词、Liquid Glass 锁屏小组件、文件拖放暂存区，以及系统通知镜像。

> 灵感来自 [getcanopy.pro](https://getcanopy.pro/)，使用 Swift 从零实现。
> 本仓库是 `6gx42o/Canopy` 的 fork（GitHub: `Aiyqz/Canopy`），在 upstream 基础上做了若干中文环境与体验相关的增强。

---

## 本 fork 相比上游的改动

这些改动是为「免费开源替代收费 Dynamic Lyrics + 中文环境」而做的：

1. **卡拉OK 逐字渐变高亮**
   - 当前歌词行按播放进度从左到右渐变填充：已唱部分纯白高亮，未唱部分暗灰（4% 软过渡带）。
   - 由 `NotchView.karaokeForeground(_:)` 与 `NowPlayingModel.currentLyricProgress` 实现。
   - 注：LRCLIB 只提供**行级**时间戳，所以这是「整行内的进度填充」，并非逐字精确。

2. **繁体 → 简体中文**
   - LRCLIB 的华语歌词多为繁体（孙燕姿 / 苏打绿等）。
   - macOS 26 的 `CFStringTransform` 在本机**完全失效**（所有 transform 均返回 false），因此改用内置的 `TraditionalSimplified.swift`（586 对繁→简映射表，零依赖、运行时可靠）。
   - `LyricsService` 在拉到歌词后会自动转换为简体。

3. **macOS 26 下播放信息兜底**
   - 私有 `MediaRemote` API 在 macOS 26 开发者预览下失效（取不到正在播放的信息）。
   - 改为用 **AppleScript 直接读取 Spotify / Music** 的当前播放作为兜底（`fetchNowPlayingViaScript`），每 3 秒轮询校正一次。

4. **性能调优（丝滑 + 低占用）**
   - 高帧率渐变只在**正在播放**时运行，暂停/空闲立即停表，消除空转烧 CPU。
   - 播放头用「死推算（dead-reckoning）」基于墙钟时间连续推算，避免 3 秒一次的硬重置跳变。
   - 帧率 30fps（歌词填充行很长，肉眼无差别，SwiftUI 重绘开销减半）。
   - 实测：播歌时 CPU ≈ 单核 7%（整芯片不到 1%），空闲 ≈ 0%。

5. **多音源歌词（国内平台兜底）**
   - LRCLIB 服务器在海外、直连常被墙；本 fork 在 LRCLIB 之外新增 **网易云音乐** 与 **QQ 音乐** 两个国内音源作为兜底，任一来源拉到歌词即可展示。
   - 来源回退链：`LRCLIB（走路由器代理）` → `网易云（直连）` → `QQ音乐（直连）`。
   - 网易云走 **eapi** 接口（AES-128-ECB 加密，无需 RSA）；QQ 音乐歌词为 base64 编码的 LRC。两者均返回标准 LRC，复用同一套 `parseLRC` 解析。
   - 统一带**指数退避重试**：遇到 HTTP 429（限流）或 5xx 会自动退避后重试，失败时切换到下一个来源。
   - 移植自开源歌词库 [WXRIW/Lyricify-Lyrics-Helper](https://github.com/WXRIW/Lyricify-Lyrics-Helper) 的多音源客户端（端点 / 解析 / 限流）。
   - 待办：酷狗音乐（其开源客户端未提供歌词下载端点，暂缓，见文末 TODO）。

---

## 功能特性

- **灵动岛媒体播放器** —— 贴合刘海的黑色面板，悬停展开为完整播放器：封面、标题/艺人、动态音律条、可拖动进度条、播放/上一首/下一首。通过私有 `MediaRemote` 框架读取并控制系统级正在播放。
- **时间同步歌词** —— 多音源获取：优先 [LRCLIB](https://lrclib.net)（免费、无需 API key），并用 **网易云音乐 / QQ 音乐** 国内平台直连兜底；解析 LRC 后按播放进度跟踪。在灵动岛与小组件中展示，并带**从专辑封面提取的类 Apple Music 渐变色**。
- **Liquid Glass 锁屏小组件** —— 磨砂玻璃桌面小组件（窗口背后模糊 + 专辑封面渐变），含 **4 种预设**：锁屏（iOS 风格时钟 + 正在播放卡片）、正在播放、歌词（滚动同步）、极简时钟。
- **灵动岛横幅** —— 切歌与**系统通知镜像**从刘海滑下。镜像读取通知中心数据库（需要「完全磁盘访问」权限，缺失时优雅降级）。
- **文件拖放暂存区** —— 把文件拖到灵动岛暂存，之后可拖出、在 Finder 中显示或清空。
- **菜单栏应用** —— 无 Dock 图标。通过叶片菜单切换小组件、切换预设、设置登录启动、授予权限。

---

## 环境要求

- macOS 14+（开发环境为 macOS 26 / Apple Silicon）
- Swift 6.2 / Xcode 26（或仅命令行工具亦可编译）

---

## 构建与运行

```sh
./build.sh release      # 编译并组装一个 ad-hoc 签名的 Canopy.app（含图标）
open Canopy.app
```

开发期间也可：

```sh
swift build
swift run Canopy
```

> 拉取 LRCLIB 歌词需要联网；LRCLIB 服务器在海外，若直连经常超时，可在 `LyricsService.swift` 中配置代理（本 fork 已写死路由器代理 `192.168.10.1:20171` / SOCKS5 `:20170`）。国内音源（网易云 / QQ音乐）**直连即可，无需代理**。

### 离屏验证渲染模式

应用可把自身界面离屏渲染成 PNG（无需屏幕录制权限）：

```sh
swift run Canopy --snapshot /tmp     # 写出灵动岛 + 小组件预设的 PNG
swift run Canopy --icon /tmp/icon.png
```

---

## 权限

- **媒体控制 / 正在播放** —— 通过 `MediaRemote` 默认可用。
- **通知镜像** —— 需要**完全磁盘访问**（系统设置 → 隐私与安全性 → 完全磁盘访问 → 加入 Canopy）。叶片菜单会显示实时状态并快捷跳转设置页。切歌横幅无需该权限。

---

## 项目结构

| 路径 | 作用 |
|------|------|
| `Sources/Canopy/main.swift` | 入口 + `--snapshot` / `--icon` 模式 |
| `MediaRemote.swift` | 私有 MediaRemote.framework 桥接 |
| `NowPlayingModel.swift` | 可观察状态：播放、歌词、色板、暂存区、横幅（含死推算/帧定时器） |
| `LyricsService.swift` | 多音源歌词（LRCLIB / 网易云 / QQ音乐）拉取 + LRC 解析（含繁→简转换、代理、eapi 加密、限流重试） |
| `TraditionalSimplified.swift` | 繁→简映射表（本 fork 新增，绕开失效的 CFStringTransform） |
| `ColorExtractor.swift` | 专辑封面 → 渐变色板 |
| `NotchController.swift` / `Views/NotchView.swift` | 灵动岛窗口 + 收起/横幅/展开界面（含卡拉OK渐变） |
| `WidgetController.swift` / `Views/WidgetView.swift` / `Views/WidgetContent.swift` | Liquid Glass 桌面小组件 + 预设 |
| `NotificationMirror.swift` | 通知中心数据库读取 |
| `SettingsStore.swift` | 持久化设置 + 登录启动 |
| `AppIcon.swift` | 程序化生成应用图标 |

---

## 待办 / TODO

- [x] **多音源歌词（国产平台兜底）**：原只依赖海外 LRCLIB（常因被墙而拉不到歌词）。已移植网易云、QQ音乐作为直连兜底，回退链 `LRCLIB → 网易云 → QQ音乐`，带限流重试。
- [ ] **酷狗音乐**：Lyricify 开源客户端中酷狗仅提供搜索端点、未提供歌词下载端点，暂未纳入；后续可从 `lyrics.kugou.com/download` 自行实现（base64 + gzip）。
- [ ] **翻译歌词联动**：网易云 `tlyric` / QQ `trans` 已是现成的译文 LRC，可在灵动岛加一层「译」展示（目前只渲染主歌词）。
- [ ] **逐字歌词**：网易云 `yrc`、QQ `qrc`（DES 加密）为逐字格式，可进一步做真正的逐字卡拉OK（目前是整行进度填充）。

---

## 说明

这是一个独立、用于学习目的的重新实现，与 Canopy 官方无隶属关系。它使用了 Apple 的私有 `MediaRemote` 框架（与同类灵动岛应用相同的做法），因此仅限**个人使用**，不会上架 Mac App Store。

🤖 使用 [Claude Code](https://claude.com/claude-code) 构建
