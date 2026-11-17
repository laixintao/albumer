import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().stroke(Color.paper.opacity(0.035), lineWidth: 1).frame(width: 260, height: 260)
                Circle().stroke(Color.paper.opacity(0.045), lineWidth: 1).frame(width: 210, height: 210)
                SleeveMark(size: 92)
            }
            Text("Albumer").font(.system(size: 34, weight: .regular)).tracking(-1.2).padding(.top, 4)
            HStack(spacing: 6) {
                Image(systemName: "headphones").font(.system(size: 10))
                Text("Spotify Premium").font(.system(size: 12))
            }.foregroundStyle(Color.quiet).padding(.top, 12)
            Button("连接 Spotify") { model.showSettings = true }
                .buttonStyle(QuietButtonStyle(prominent: true)).padding(.top, 34)
                .accessibilityIdentifier("connectSpotify")
            Button("预览界面") { Task { await model.enterDemo() } }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.quiet).padding(.top, 18)
                .accessibilityIdentifier("previewButton")
            Spacer()
            SpotifyAttribution().padding(.bottom, 24)
        }.frame(maxWidth: .infinity)
    }
}

struct SettingsPanel: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Spotify").font(.system(size: 23, weight: .medium)).tracking(-0.5)
                Spacer()
                GlyphButton(symbol: "xmark", label: "关闭设置", size: 30) { dismiss() }
            }.padding(.bottom, 28)
            if model.isConnected && !model.isDemo {
                HStack(spacing: 10) {
                    Circle().fill(Color(red: 0.55, green: 0.69, blue: 0.48)).frame(width: 6, height: 6)
                    Text("已连接").font(.system(size: 13))
                    Spacer()
                    Button("断开连接") { Task { await model.disconnect() } }.buttonStyle(QuietButtonStyle())
                }
                Divider().overlay(.white.opacity(0.04)).padding(.vertical, 24)
                Text("音频由 Spotify 播放。若希望专辑结束后停止，请在 Spotify 中关闭自动播放并清空已有队列。")
                    .font(.system(size: 12)).foregroundStyle(Color.quiet).lineSpacing(5)
            } else {
                Text("Client ID").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.paper.opacity(0.7))
                TextField("Spotify 应用的 Client ID", text: $model.clientID)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(13).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.07)))
                    .padding(.top, 8).disabled(model.isAuthorizing).accessibilityIdentifier("clientIDField")
                HStack {
                    Link("创建 Spotify 应用 ↗", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                        .font(.system(size: 12)).tint(Color.paper.opacity(0.7))
                    Spacer()
                    Text("无需 Client Secret").font(.system(size: 10)).foregroundStyle(Color.quiet)
                }.padding(.top, 12)
                Text("Redirect URI").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.paper.opacity(0.7)).padding(.top, 27)
                HStack {
                    Text(SpotifyOAuthConfiguration.redirectURI).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    GlyphButton(symbol: copied ? "checkmark" : "doc.on.doc", label: "复制回调地址", size: 26) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SpotifyOAuthConfiguration.redirectURI, forType: .string)
                        copied = true
                    }
                }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).padding(.top, 8)
                Text("创建应用时选择 Web API，填入上方回调地址。开发模式需要 Premium，最多 5 位用户；朋友需加入 Users Management 授权名单。")
                    .font(.system(size: 11)).foregroundStyle(Color.quiet).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                if let notice = model.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Color(red: 0.9, green: 0.66, blue: 0.5)).lineSpacing(3).padding(.top, 14)
                }
                HStack {
                    Spacer()
                    if model.isAuthorizing {
                        ProgressView().controlSize(.small)
                        Button("取消") { model.cancelAuthorization() }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button("连接 Spotify") { model.connect() }.buttonStyle(QuietButtonStyle(prominent: true))
                            .disabled(model.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.top, 26)
            }
            HStack {
                Text("Albumer 1.0").font(.system(size: 10)).foregroundStyle(Color.quiet)
                Spacer()
                SpotifyAttribution()
            }.padding(.top, 28)
        }
        .padding(30).frame(width: 480).background(Color.room).foregroundStyle(Color.paper).preferredColorScheme(.dark)
        .onChange(of: model.showSettings) { _, visible in if !visible { dismiss() } }
        .onDisappear { if model.isAuthorizing { model.cancelAuthorization() } }
    }
}

struct DevicesPanel: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("播放设备").font(.system(size: 15, weight: .medium))
                Spacer()
                GlyphButton(symbol: "arrow.clockwise", label: "刷新设备", size: 26) { Task { await model.refreshDevices() } }
            }
            if model.devices.isEmpty {
                Text("打开 Spotify 后，在此选择设备。").font(.system(size: 12)).foregroundStyle(Color.quiet)
            } else {
                ForEach(Array(model.devices.enumerated()), id: \.offset) { _, device in
                    Button { Task { await model.chooseDevice(device) } } label: {
                        HStack(spacing: 13) {
                            Image(systemName: device.symbol).font(.system(size: 19)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.system(size: 12))
                                if device.isRestricted { Text("设备不支持远程控制").font(.system(size: 10)).foregroundStyle(Color.quiet) }
                            }
                            Spacer()
                            if device.isActive { Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(Color.paper.opacity(0.7)) }
                        }.padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(device.isRestricted || device.id == nil || model.isBusy)
                        .accessibilityIdentifier("device-\(device.id ?? "unavailable")")
                }
            }
            Divider().overlay(.white.opacity(0.05))
            HStack {
                Button("打开 Spotify") { model.openSpotify() }.buttonStyle(QuietButtonStyle())
                Spacer()
                VolumeControl(model: model)
            }
        }.padding(24).frame(width: 320).foregroundStyle(Color.paper).background(Color.room).preferredColorScheme(.dark)
    }
}

