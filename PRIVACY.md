# Albumer 隐私说明

更新日期：2026-11-25

Albumer 是在你的 Mac 上运行的 Spotify 专辑管理客户端，由 Albumer contributors 维护。没有 Albumer 账号、开发者后台、广告、遥测或自动上传日志的功能。开发者不会通过应用收到你的音乐资料或凭据。预览模式使用随应用提供的虚构数据和几何图片。

## 处理的数据与用途

连接 Spotify 后，应用通过官方 API 读取账号标识、收藏专辑、专辑及艺人资料、当前歌曲、播放进度、可用设备和音量。这些数据用于展示收藏、按你的操作管理收藏和控制 Spotify Connect 播放。应用不索取 Spotify 密码或 Client Secret。

授权范围为 user-library-read、user-library-modify、user-read-playback-state、user-modify-playback-state。授权使用 PKCE；登录时临时在 127.0.0.1:8888 接收回调，结束后关闭监听。

访问令牌、刷新令牌、Client ID 和账号标识存于 macOS Keychain 的 app.albumer.spotify 项目；设置页的 Client ID 副本和界面偏好存于本机 UserDefaults。应用为每张唱片保存最新的续播位置，并在本机累计观察到的专辑和歌曲播放次数。这些数据用于继续播放和展示次数，不上传给开发者。

点击“复制推荐 Prompt”时，应用整理收藏中的艺人、专辑名、年份和推荐偏好，写入系统剪贴板；不包含账号标识、令牌或播放记录。Albumer 不会自动将这些内容发送给 AI。你可以自行粘贴到选择的服务，粘贴后的处理受该服务的隐私政策约束。

## 网络与第三方

API 请求直接发送到 api.spotify.com；登录和令牌请求发送到 accounts.spotify.com。封面及艺人图片按 Spotify API 返回的 HTTPS 地址下载，图片服务器会接收正常网络请求信息，例如 IP 地址。网络服务受 Spotify 自己的隐私政策约束：https://www.spotify.com/legal/privacy-policy/ 。

点击 Spotify 链接或登录会打开 Spotify 应用或默认浏览器。Albumer 接收本机 Spotify 的播放变化通知以刷新状态；不记录鼠标位置，也不使用辅助功能、麦克风、摄像头、通讯录或屏幕录制权限。复制回调地址只会写入系统剪贴板，不读取剪贴板。

## 本地缓存与删除

收藏、曲目和设备选择缓存按账号隔离，位于 ~/Library/Caches/app.albumer。磁盘图片缓存上限约 256 MB，内存图片缓存约 64 MB。磁盘缓存最长保留 7 天，读取和下次启动时清理过期项目；应用未运行时不会在后台自动删除文件。曲目通常每天刷新，收藏超过 60 秒会后台同步。

续播位置保存在 ~/Library/Application Support/Albumer/playback，按账号隔离，每张唱片仅保留最新的歌曲标识、碟号、曲序与毫秒进度。位置随播放同步更新，并在切换唱片和正常退出时保存，不受 7 天缓存期限影响，保留至断开连接或清除本地数据。预览模式不会写入这些文件。

累计播放次数保存在 ~/Library/Application Support/Albumer/history，按账号隔离，并保留当前收听状态以避免重启后重复计数。专辑在同一次收听中累计 30 秒记一次；歌曲累计 30 秒或达到一半时长（取较短者，至少 1 秒）记一次。暂停、拖动进度和长时间未同步不计入收听时间。这些数据不是 Spotify 全平台的历史播放总数，不包含逐次播放事件列表；启动时不会删除，旧格式文件可继续读取。

在设置中点击“断开连接”或“清除本地数据并断开连接”，会删除 Keychain 令牌、Client ID 副本、所有账号的本地内容缓存、图片缓存、续播位置和播放次数，并取消旧请求。若操作系统拒绝删除，会在设置中提示重试。一般界面偏好（例如排序）保留。

本地断开不会撤销 Spotify 服务器上的授权。你也可以在 https://www.spotify.com/account/apps/ 移除应用访问权限。单独删除 Albumer.app 不会自动删除 Keychain 或应用数据，请先断开连接；若只在 Spotify 网站撤销授权，也请在 Albumer 中清除本地数据。

## 联系与更新

隐私问题可通过你下载 Albumer 的源码仓库 issue 反馈；请勿公开令牌、账号标识、个人设备名或包含个人资料的日志。发行者修改应用行为时，应同步更新本说明。项目随源码、应用欢迎页和设置页提供此文档，连接前即可阅读。
