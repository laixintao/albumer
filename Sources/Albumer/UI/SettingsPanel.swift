import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "opticaldisc")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Albumer").font(.largeTitle.weight(.semibold))
                Text("从一张专辑开始听。").font(.body).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                Button("连接 Spotify") { model.showSettings = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("connectSpotify")
                Button("预览界面") { Task { await model.enterDemo() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("previewButton")
            }
            Text("需要 Spotify Premium").font(.caption).foregroundStyle(.secondary)
            LegalLinks()
            Spacer()
            SpotifyAttribution().padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsPanel: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private var connected: Bool { model.isConnected && !model.isDemo }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Spotify").font(.title2.weight(.semibold))
                Spacer()
            }.padding(20)
            Form {
                if connected {
                    Section {
                        LabeledContent("账号状态") {
                            Label("已连接", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        Button("断开连接", role: .destructive) { Task { await model.disconnect() } }
                    } footer: {
                        Text("音频由 Spotify 播放。若希望专辑结束后停止，请在 Spotify 中关闭自动播放并清空已有队列。")
                    }
                } else {
                    Section {
                        TextField("Client ID", text: $model.clientID, prompt: Text("Spotify 应用的 Client ID"))
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isAuthorizing)
                            .accessibilityIdentifier("clientIDField")
                        LabeledContent("Redirect URI") {
                            HStack(spacing: 8) {
                                Text(SpotifyOAuthConfiguration.redirectURI)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                GlyphButton(symbol: copied ? "checkmark" : "doc.on.doc", label: "复制回调地址", size: 24) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(SpotifyOAuthConfiguration.redirectURI, forType: .string)
                                    copied = true
                                }
                            }
                        }
                        Link(destination: URL(string: "https://developer.spotify.com/dashboard")!) {
                            Label("创建 Spotify 应用", systemImage: "arrow.up.right.square")
                        }
                    } header: {
                        Text("连接账号")
                    } footer: {
                        Text("创建应用时选择 Web API，并填写上方回调地址。连接只需 Client ID，无需 Client Secret。开发模式最多支持 5 位用户，其他用户需加入 Spotify 应用的授权名单。")
                    }
                }
                if let notice = model.notice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    LegalLinks()
                    if !connected {
                        Button("清除本地数据并断开连接", role: .destructive) {
                            Task { await model.disconnect() }
                        }
                    }
                } footer: {
                    Text(connected ? "断开连接会删除本地令牌、Client ID 和所有内容缓存。" : "点击连接即表示你已阅读隐私说明并同意使用条款。")
                }
            }
            .disabled(model.isDisconnecting)
            .formStyle(.grouped)
            .scrollIndicators(.never)
            .frame(height: connected ? 320 : 430)
            Divider()
            HStack(spacing: 12) {
                SpotifyAttribution()
                Spacer()
                if model.isAuthorizing {
                    ProgressView().controlSize(.small)
                    Button("取消授权") { model.cancelAuthorization() }
                } else if !connected {
                    Button("连接 Spotify") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDisconnecting || model.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("关闭设置")
                    .accessibilityLabel("关闭设置")
            }.padding(20)
        }
        .frame(width: 540)
        .onChange(of: model.showSettings) { _, visible in if !visible { dismiss() } }
        .onDisappear { if model.isAuthorizing { model.cancelAuthorization() } }
    }
}

struct PlaybackDevicesView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.devices.isEmpty {
                if model.isRefreshingDevices {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在查找设备")
                } else {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
                        .help("未发现可用设备，打开 Spotify 后会自动选择")
                        .accessibilityLabel("未发现可用播放设备")
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    deviceButtons.fixedSize()
                    ScrollView(.horizontal) {
                        deviceButtons
                    }
                    .scrollIndicators(.never)
                    .frame(minWidth: 100, maxWidth: 360)
                    .frame(height: 28)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            GlyphButton(symbol: "arrow.clockwise", label: "刷新设备", size: 24) { Task { await model.refreshDevices() } }
                .disabled(model.isRefreshingDevices || model.isBusy)
                .accessibilityIdentifier("refreshDevices")
            Divider().frame(height: 20)
            Button { model.openSpotify() } label: {
                HStack(spacing: 6) {
                    SpotifyWordmark(width: 64)
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }.padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("通过 Spotify 播放 · 打开 Spotify")
            .accessibilityLabel("通过 Spotify 播放，打开 Spotify")
            .accessibilityIdentifier("openSpotify")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .controlGlass()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spotify 播放设备")
        .accessibilityIdentifier("playbackDevices")
    }

    private var deviceButtons: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.devices.enumerated()), id: \.offset) { _, device in
                let selected = device.id != nil && device.id == model.preferredDevice?.id
                Button { Task { await model.chooseDevice(device) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: device.symbol)
                        Text(device.name).lineLimit(1).frame(maxWidth: 150)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, 6).frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!device.isSelectable || model.isBusy)
                .help(device.isSelectable ? device.name : "设备不支持远程控制")
                .accessibilityLabel(device.name)
                .accessibilityValue(selected ? "已选中" : "未选中")
                .accessibilityIdentifier("device-\(device.id ?? "unavailable")")
            }
        }
    }
}

