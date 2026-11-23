# Albumer

原生 macOS Spotify 专辑管理客户端。Swift 6、SwiftUI、AppKit，macOS 15+；使用系统字体、SF Symbols 和语义颜色，macOS 26+ 的控件使用 Liquid Glass。

## 本地开发

需要完整 Xcode，无第三方包依赖。

```sh
make run       # 构建最新 Debug 版本，再打开该开发应用
make build     # 只构建，不启动应用
make release   # 构建并检查 Release，输出 build/Albumer.app
make test      # 无界面的核心测试
```

`make run` 只重启同一路径下的开发实例。脚本默认使用 `/Applications/Xcode.app`，可通过 `DEVELOPER_DIR` 指定其他安装位置，不修改系统的 `xcode-select` 设置。

发布脚本映射源码路径、使用全新应用目录、检查凭据模式及本机路径，并验证本地签名。Release 包含 arm64 和 x86_64；目前在 Apple Silicon 上验证。产物是 ad hoc 本地签名，未做 Developer ID 签名或公证，不能视为面向普通用户的正式安装包。

首次启动可选择“预览界面”，也可手动执行：

```sh
open build/Albumer.app --args --demo
```

预览使用原创几何图片与虚构专辑、艺人、曲目，不连接账号，不播放音频。图片与元数据可用 `python3 scripts/generate-preview-fixtures.py` 离线重新生成。

## 连接 Spotify

连接前请阅读 [隐私说明](PRIVACY.md) 和 [使用条款](TERMS.md)，应用欢迎页和设置页也提供离线版本。

1. 在 [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) 创建应用，选择 Web API。
2. 注册回调地址 **`http://127.0.0.1:8888/callback`**，保留端口和路径，不要使用 `localhost` 或添加末尾斜杠。
3. 在 Albumer 设置中填入自己的 **Client ID**，点击“连接 Spotify”，在浏览器中授权。无需 Client Secret。
4. 打开 Spotify 桌面客户端或让一个 Spotify Connect 设备上线。应用自动选择可控设备，也可在页面上切换。

Spotify 账号、应用所有者的 Premium 条件、开发模式用户白名单和配额以 [Spotify 官方规则](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) 为准。开发模式应用通常最多支持 5 位授权用户。API 返回 403 时请检查账号资格、授权名单和设备限制；开源代码不自动获得面向公众的 Spotify API 权限。

授权只在本机 `127.0.0.1:8888` 临时监听，完成或取消后关闭。声音始终由 Spotify 客户端／Connect 设备播放，退出 Albumer 不会停止 Spotify。新开始专辑时关闭随机播放和循环，从第一首开始；暂停后继续不会重新开始。Spotify 的自动续播和既有队列需在 Spotify 内管理。

## 使用

- 收藏和搜索聚焦专辑及合辑；Spotify 分类为 `single` 的发行版本（包括部分 EP）不进入专辑收藏网格，但其真实播放状态仍可显示。
- 专辑可按主要艺人分组，按收藏顺序或年份排序；排列切换和返回详情保留浏览位置。封面保持原图，年份及播放标志位于封面外，悬停稍作停留可查看艺人、年份、曲目数和时长。
- 点击封面浏览详情，点击播放才开始音乐。左栏提供播放控制、进度和专辑资料，右侧展示曲目；多碟发行按 Spotify 的 disc_number 分区，不推断实体黑胶 A/B 面。
- 点击艺人进入主页，分别展示已收藏和未收藏的专辑；收藏变更立即更新对应分区。
- 收藏页显示当前播放专辑，详情页标记当前曲目。Spotify 将专辑内歌曲映射到单曲版时，结合播放上下文、曲目 ID、linked_from 及唯一元数据匹配判断所属专辑，避免误用单曲封面或把第 5 首认成第 1 首。未确定的序号显示“—”，不猜测；播放列表中的真实单曲仍按单曲显示。
- Dock 使用当前专辑封面。右键菜单展示歌曲、艺人、专辑、年份和设备，并提供上一首、播放／暂停、下一首。没有 Dock 悬停或鼠标位置跟踪功能。
- 确认新歌开始后 1 秒，在右下角显示原始封面、歌曲名和专辑内序号，停留 5 秒。点击可打开对应专辑，不改变播放。提示使用系统材质和语义文字色，不把模糊封面作为背景。
- 临时断线、超时和服务端故障自动退避重试；限流遵守 Retry-After。对跳曲、整张专辑开始等可能重复执行的命令不盲目重发。后台临时错误不反复弹窗，最终失败可重试。
- ×／`⌘W` 只关主窗口，继续同步播放；点击 Dock 恢复。`⌘Q` 退出。设置从应用菜单或 `⌘,` 打开。
- `Space` 播放／暂停当前专辑，`⌘←`／`⌘→` 跳曲，`⌘F` 搜索，`⌘1` 返回收藏，`Esc` 返回。

## 数据与隐私

没有遥测、开发者服务器或自动 AI 上传。令牌在 macOS Keychain 中，Client ID 的设置副本在本机偏好设置中。收藏、曲目、设备选择和图片缓存位于 `~/Library/Caches/app.albumer`，缓存最多保留 7 天，读取或下次启动时清理过期文件。图片内存预算约 64 MB、磁盘预算约 256 MB。

断开连接会删除本地令牌、Client ID、所有账号缓存、图片缓存和旧版收听记录，拒绝旧请求重新写入缓存。旧版 `~/Library/Application Support/Albumer/history` 也在下次非预览启动时迁移删除。可从设置重试清理；若要撤销 Spotify 服务端授权，还需到 [Spotify 账号应用页面](https://www.spotify.com/account/apps/) 移除访问权限。

本版本移除了将 Spotify 收藏导出给 AI 的推荐 Prompt、本机播放次数统计、封面翻转和模糊封面背景。调整依据是 Spotify 对 AI 内容输入、派生收听指标及封面呈现的限制；保留专辑浏览和播放功能。详见 [Spotify Developer Policy](https://developer.spotify.com/policy)、[Developer Terms](https://developer.spotify.com/terms) 和 [Design Guidelines](https://developer.spotify.com/documentation/design)。这些改动不构成 Spotify 审核或发行批准。

## 开源发布准备

原创代码、应用图标、虚构演示数据及几何素材采用 [MIT License](LICENSE)。Spotify 标识和运行时内容不在 MIT 授权范围内，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。

```sh
make audit     # 扫描当前源码，报告位置，不输出疑似凭据值
make public    # 生成可审阅的公开仓库、源码 zip 和 Git bundle；不会发布
```

输出位于 `build/public/Albumer-*/`：

- `Albumer/`：独立 Git 仓库，保留 HEAD 的完整提交祖先及原作者姓名、邮箱、时间、提交信息。
- 历史中的旧预览目录、下载脚本和截图被剔除；最后追加当前工作区的发布快照，包含原创替代素材。提交 ID 会变化，映射见 `history-map.json`。
- `Albumer-source.zip`：当前源码快照；`Albumer-public.bundle`：含清理后历史的 Git 离线包。

原仓库和原提交不被改写。公开时使用生成的副本；直接推送原仓库仍会公开旧历史素材。脚本不复制原仓库配置、远程地址、reflog 或被剔除的对象；公开副本仍按作者选择保留姓名和邮箱。不会自动推送、上传或创建远程仓库。

凭据扫描是模式检查，不能证明绝无遗漏，也不授予任何第三方权利。公开源码前应审阅最终副本；发布应用还需确认 Spotify 的接入条件、品牌使用规则，并按需要完成 Developer ID 签名和公证。

## 开发与验证

```sh
./scripts/test.sh        # 核心测试，无 Spotify 账号、无桌面操作
./scripts/test.sh --ui   # 原生 XCUITest，会启动并操作应用；需显式选择
```

核心测试覆盖 OAuth/PKCE、令牌刷新、重试、收藏、设备、播放同步、单曲发行与专辑上下文识别、通知生命周期、账号缓存删除和延迟写入拦截。UI 测试使用虚构预览数据，不能替代真实 Spotify 联调。

工程分为 Core（数据、OAuth、存储与 API）、AppModel（界面和播放协调）及 UI。新增或删除 Swift 文件后运行 `python3 scripts/generate-project.py` 更新已提交的 Xcode 工程；应用图标由 `scripts/make-icon.swift` 生成。
