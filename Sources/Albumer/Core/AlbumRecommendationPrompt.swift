import Foundation

struct AlbumRecommendationPrompt: Sendable {
    let text: String
    let albumCount: Int
    let isComplete: Bool

    init?(albums: [Album], isComplete: Bool) {
        var ids = Set<String>()
        let favorites = albums.filter { $0.isAllowed && ids.insert($0.id).inserted }
        guard !favorites.isEmpty else { return nil }
        albumCount = favorites.count
        self.isComplete = isComplete
        let list = favorites.enumerated().map { index, album in
            let name = Self.singleLine(album.name)
            let artist = Self.singleLine(album.artist)
            let year = album.releaseYear.map { "（\($0)）" } ?? ""
            return "\(index + 1). \(artist.isEmpty ? "未知艺人" : artist) — \(name)\(year)"
        }.joined(separator: "\n")
        let scope = isComplete ? "当前收藏，共 \(albumCount) 张" : "当前已加载的部分收藏，共 \(albumCount) 张；这不是完整收藏清单"
        text = """
        下面是我现在喜欢听并收藏的专辑，请根据这些口味线索，为我推荐一张新的、我可能喜欢的完整专辑。

        我的推荐偏好：
        - 只推荐一张，不要给候选清单。这里的“新”指对我而言的新发现，不要求是新发行的专辑。
        - 不要推荐清单中已有的专辑，也不要用同一专辑的重制版、豪华版或其他版本充当新推荐。
        - 不要过度同质化：请提炼我可能喜欢的旋律、节奏、音色、氛围或创作特点，而不是只推荐相同艺人或相同流派。
        - 欢迎带我探索之前可能没有听过的风格、年代、地区或语言，但请说明它与我的现有口味有什么联系、为什么值得尝试。
        - 可以综合流行程度、乐评口碑和音乐史影响力，优先考虑值得完整聆听的经典专辑；不必只追热门，也不要为了冷门而冷门。
        - 这份收藏只是偏好线索，不代表我的全部收听历史；不要把推测出的喜好或未听过的风格说成确定事实。

        请用中文回答，保留艺人和专辑的原名，并包含：
        1. 专辑名、艺人、发行年份和主要风格。
        2. 为什么选它：结合清单中的具体专辑，说明它符合我口味的地方，以及能带来的新鲜感。
        3. 它为何值得听，有什么经典地位、口碑或流行影响；不确定的事实请说明，不要编造销量、评分或奖项。
        4. 两三首适合入门的曲目，以及聆听整张专辑时可以留意的特点。

        我喜欢的专辑（\(scope)）：
        \(list)
        """
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum RecommendationPromptError: LocalizedError {
    case emptyLibrary, collectionChanged

    var errorDescription: String? {
        switch self {
        case .emptyLibrary: "先收藏一些喜欢的专辑，再复制推荐 Prompt。"
        case .collectionChanged: "收藏已更新，请再点一次复制。"
        }
    }
}
