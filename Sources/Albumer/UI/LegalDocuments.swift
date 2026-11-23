import SwiftUI

enum LegalDocument: String, Identifiable {
    case privacy = "PRIVACY", terms = "TERMS", notices = "THIRD_PARTY_NOTICES"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .privacy: "隐私说明"
        case .terms: "使用条款"
        case .notices: "开源与素材声明"
        }
    }
}

struct LegalLinks: View {
    @State private var document: LegalDocument?

    var body: some View {
        HStack(spacing: 16) {
            ForEach([LegalDocument.privacy, .terms, .notices]) { item in
                Button(item.title) { document = item }.buttonStyle(.link)
            }
        }
        .font(.caption)
        .sheet(item: $document) { LegalDocumentView(document: $0) }
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: document.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "文档无法读取。请从完整源码构建，或重新获取包含隐私说明和使用条款的发行包。"
        }
        if document == .notices, let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
           let contents = try? String(contentsOf: license, encoding: .utf8) {
            return text + "\n\n" + contents
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(document.title).font(.title2.weight(.semibold))
            ScrollView {
                Text(text).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 620, height: 560)
    }
}
