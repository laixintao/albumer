# Albumer

一个只选专辑的原生 macOS Spotify 播放器。Swift 6、SwiftUI、AppKit，macOS 15+。

![收藏封面墙](docs/screenshots/collection.png)

![播放舞台](docs/screenshots/stage.png)

## 运行

需要完整 Xcode；无需安装第三方依赖。

```sh
./scripts/build-app.sh
open build/Albumer.app
```

也可以用 Xcode 打开 `Albumer.xcodeproj`，选择 **Albumer → My Mac** 运行。构建脚本默认使用 `/Applications/Xcode.app`，可通过 `DEVELOPER_DIR` 指定其他安装位置；不会修改系统的 `xcode-select` 设置。脚本产物包含 arm64／x86_64，已在 Apple Silicon Mac 上验证，使用本地签名，尚未进行 Developer ID 公证。

首次打开可选择 **预览界面**。预览使用独立的固定数据，不连接账号、不发出播放命令，也不播放音频。命令行预览：

```sh
open build/Albumer.app --args --demo
```

## 连接 Spotify

1. 使用有 **Premium** 的账号登录 [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)，创建应用，选择 **Web API**。
2. 将 Redirect URI 设置为 **`http://127.0.0.1:8888/callback`**，点击 **Add** 后保存。请保留端口 `8888`，不要使用 `localhost`，不要添加末尾斜杠。Spotify 文档允许不带端口的回环地址，但当前 Dashboard 表单会拒绝它；Albumer 使用固定端口，使注册地址与授权请求完全一致。
3. 复制 **Client ID**，在 Albumer 设置中粘贴，点击 **连接 Spotify**，在浏览器中完成授权。**无需 Client Secret**。
4. 打开并登录 Spotify 桌面客户端，或让一个 Spotify Connect 设备上线。在 Albumer 的设备面板选择输出设备，然后播放专辑。

新应用的开发模式最多支持 5 位授权用户。朋友需要加入该应用的 **Users Management** 名单；应用所有者与播放用户需要满足 Spotify 的 Premium 要求。登录成功但 API 返回 403 时，检查授权名单、Premium 和设备限制。

如果 Dashboard 显示 “This redirect URI is not secure”，确认填写了上方包含 `:8888` 的完整地址。授权时 Albumer 会临时监听本机 `127.0.0.1:8888`，完成或取消后关闭；若提示端口被占用，请关闭其他 Albumer 实例或占用该端口的程序后重试。

声音始终由 Spotify 客户端／Connect 设备播放。退出 Albumer 不会停止 Spotify。新开始的专辑会关闭随机播放和循环，从第一首开始；暂停后继续播放不会重新开始。Spotify 的自动续播及现有队列没有完整的官方关闭／清空 API；希望播完专辑就停下时，请在 Spotify 里关闭自动播放并清空队列。

## 使用

- 收藏和搜索都只显示 `album`、`compilation`；`single` 会被过滤，包括 Spotify 归为该类型的 EP。
- 收藏对应 Spotify **Your Library → Albums**。密集封面墙默认只展示封面，按年份排序时才在左上角显示发行年份，悬停可看名称；滚动到底部继续加载，不需要翻页。返回时保留列表和滚动位置。
- 收藏页的艺人图标可切换按主要艺人分组，排序图标可选择收藏顺序、年份从新到旧或从旧到新；分组内遵循同一排序，选择会保存在本机。启用分组或年份排序时会补齐收藏数据，以保证全库排列一致。年份来自 Spotify 的该发行版本，缺失年份的专辑排在末尾。
- 启动先显示本地收藏缓存，超过 60 秒的列表会在后台同步；也可以点刷新图标或按 `⌘R` 立即同步。网络不可用时保留已有内容。
- 点击封面浏览专辑，点击播放才改变音乐。播放页展示整张专辑的曲目顺序、时长和当前曲目，列表不提供单曲点播。
- 播放页有流动环境光、轨道光环、专辑进度环和当前曲目动效。动效跟随播放状态；Connect 不提供音频采样，因此它不是频谱或节拍检测。
- Dock 图标跟随正在播放的专辑封面，暂停时保留，无播放内容时恢复默认图标。
- 播放次数是 **本机统计**：专辑每次收听会话累计 30 秒记一次；曲目听满 30 秒（短曲为时长的一半）记一次。暂停、跳转及没有观测到播放的时段不会累加。统计按账号存储，重启不会重复计算已经计数的播放；Spotify API 不提供账号历史播放次数。
- 播放／暂停、上一首、下一首、当前歌曲进度拖动；音量在扬声器按钮或设备面板中调整。
- `Space` 播放／暂停当前舞台上的专辑；`⌘←`、`⌘→` 跳曲；`⌘F` 搜索；`Esc` 返回；`⌘,` 设置。
- 图标提供悬停说明与无障碍标签；遵循 macOS 的“减少动态效果”设置。后台停止动画，并将播放状态轮询降到每 20 秒一次，以更新 Dock 和本机收听记录。

令牌保存在 macOS Keychain，Client ID 保存在本机偏好设置。收藏和曲目缓存按账号隔离，封面采用 64 MB 内存缓存与约 256 MB 磁盘缓存，封面最长缓存 30 天；曲目缓存每天更新。缓存位于 `~/Library/Caches/app.albumer`，本机收听记录位于 `~/Library/Application Support/Albumer`。退出账号清理该账号的收藏与曲目缓存，保留本机收听记录；重新授权同一账号可继续累计。没有遥测或服务器。

## 开发与验证

```sh
./scripts/test.sh        # 核心测试，不需要 Spotify 账号
./scripts/test.sh --ui   # 再运行原生 XCUITest，需要图形桌面
```

核心测试覆盖 PKCE 的 RFC 向量、OAuth 回环回调、取消和 state 校验、单次并发刷新、退出时取消刷新、2026 年收藏接口、专辑过滤与分页、204 空状态、403／404／429、Retry-After、配额熔断、完整专辑播放请求及进度校准。

原生 UI 测试使用明确的 `--demo` 模式，验证封面墙、专辑播放控制、搜索、空状态、设置、设备、键盘操作、小窗口、缺失封面、长名称及减少动态效果。截图保存在测试结果 `.xcresult` 中。UI fixture 测试不等同于真实 Spotify 音频联调。

真实账号验收需要用户提供自己的 Client ID 并授权：验证音频输出、专辑顺序播放、暂停续播、跳曲／拖动、收藏同步、Connect 切换、重启后恢复登录，以及 Spotify 外部改播后的同步。当前仓库不包含账号凭据。

工程分为 `Core`（模型、OAuth、钥匙串、可注入 HTTP 层）、`AppModel`（界面与播放协调）及 `UI`。网络协议支持替换测试实现；新播放入口只接收 `AlbumID`，不会构造单曲 URI 队列。

新增 Swift 文件后可运行 `python3 scripts/generate-project.py` 更新已提交的 Xcode 工程。图标由 `scripts/make-icon.swift` 生成；预览素材可用 `scripts/fetch-preview-assets.py` 更新，正常构建不需要执行这两个脚本。

## Spotify 资料与素材

实现依据 [PKCE 授权](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)、[回调地址规则](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)、[2026 API 迁移说明](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide) 和 [配额规则](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)。收藏写入使用新版 `/me/library`，搜索每次最多 10 条，不依赖已移除的用户 `product` 等字段。

Spotify 标识来自其官方品牌素材包，预览封面及曲目显示元数据来自 Spotify 的公开 oEmbed／嵌入页面；版权属于各自权利人。素材仅用于标注来源的应用界面，不包含音频。实际连接账号后的内容通过官方 Web API 获取，封面按 [Spotify 展示规范](https://developer.spotify.com/documentation/design) 保持原样，环境光及动效独立绘制。
