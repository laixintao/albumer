import SwiftUI
import AppKit

struct RecommendationPromptButton: View {
    let model: AppModel
    @State private var task: Task<Void, Never>?
    @State private var preparing = false
    @State private var copied = false
    @State private var feedback: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: copyPrompt) {
                if preparing {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Label("复制推荐 Prompt", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                        .labelStyle(.iconOnly)
                }
            }
            .albumButtonStyle()
            .controlSize(.regular)
            .help(model.albums.isEmpty ? "先收藏喜欢的专辑" : "复制收藏与推荐偏好，粘贴给 AI 推荐一张新专辑")
            .accessibilityLabel(preparing ? "正在整理收藏" : "复制推荐 Prompt")
            .accessibilityIdentifier("copyRecommendationPrompt")
            .disabled(preparing || model.isLoading || model.albums.isEmpty)
            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recommendationPromptFeedback")
            }
        }
        .onDisappear {
            task?.cancel(); task = nil; preparing = false; copied = false; feedback = nil
        }
    }

    private func copyPrompt() {
        guard !preparing else { return }
        task?.cancel()
        preparing = true; copied = false; feedback = nil
        task = Task { @MainActor in
            do {
                let prompt = try await model.makeRecommendationPrompt()
                try Task.checkCancellation()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.setString(prompt.text, forType: .string) {
                    copied = true
                    feedback = prompt.isComplete ? "已复制 · \(prompt.albumCount) 张专辑" : "已复制部分收藏 · \(prompt.albumCount) 张"
                } else { feedback = "复制未完成，请重试" }
            } catch is CancellationError {
                preparing = false
                return
            } catch {
                feedback = NetworkRetry.message(for: error)
            }
            preparing = false
            do { try await Task.sleep(for: .seconds(copied ? 3 : 5)) } catch { return }
            copied = false; feedback = nil
        }
    }
}
