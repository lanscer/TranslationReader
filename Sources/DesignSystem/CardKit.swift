import SwiftUI
import Contracts

// 翻译卡的可复用视觉件与纯逻辑（文档 §3.2 / §4.1 / §4.2）。
// DesignSystem 只依赖 Contracts：不含业务、不碰网络与朗读。

// MARK: - 纯逻辑（可单测，无 UI）

/// 卡片的内容模式：单词看词条，句子看译文（文档 §3.2 第 4 点）。
public enum CardContentMode: String, Hashable, Sendable {
    case word
    case sentence
}

/// 细节区分页（文档 §12 已拍板 3：「简明 + 例句」两 tab 起步，句子模式为「译文 / 用法」）。
public enum CardTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case concise = "简明"
    case examples = "例句"
    case usage = "用法"
    /// 「出处」放 notes / 出处说明；译文本身永远只在卡片正文出现一次，tab 里不再重复。
    case origin = "出处"

    public var id: String { rawValue }
    public var title: String { rawValue }
}

/// 一个义项（序号 + 释义 + 例句）。
public struct LemmaDefinition: Hashable, Sendable, Identifiable {
    public let number: Int
    public let def: String
    public let examples: [TranslationDetail.ExamplePair]

    public var id: Int { number }

    public init(number: Int, def: String, examples: [TranslationDetail.ExamplePair] = []) {
        self.number = number
        self.def = def
        self.examples = examples
    }
}

/// 词性分组（文档 §3.2「词性分组 + 义项序号悬挂缩进」）。
public struct LemmaSection: Hashable, Sendable, Identifiable {
    public let pos: String
    public let defs: [LemmaDefinition]

    public var id: String { pos }

    public init(pos: String, defs: [LemmaDefinition]) {
        self.pos = pos
        self.defs = defs
    }
}

/// 卡片内容的推导规则，集中在这里便于单元测试。
public enum CardDetailLogic {
    /// 单词模式判定：单个 token（无空白），且排除「无空格但明显是句子」的中文长串。
    public static func isWordLike(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let hasWhitespace = text.contains { $0.isWhitespace || $0.isNewline }
        guard !hasWhitespace else { return false }
        if Self.containsCJK(text) {
            // 中文没有词间空格，"你好世界"这种需要靠长度与标点区分。
            guard !text.contains(where: { "。！？；，、：".contains($0) }) else { return false }
            return text.count <= 4
        }
        return text.count <= 40
    }

    public static func mode(for sourceText: String, detail: TranslationDetail? = nil) -> CardContentMode {
        if let detail {
            if detail.mode == .word { return .word }
            if detail.mode == .sentence { return .sentence }
        }
        return isWordLike(sourceText) ? .word : .sentence
    }

    /// 单词模式固定「简明 / 例句」，句子模式固定「用法 / 出处」。
    /// 句子模式**不再**有「译文」tab：译文已经在卡片正文里出现过，不能出现两份一样的文本。
    public static func tabs(for mode: CardContentMode) -> [CardTab] {
        switch mode {
        case .word: return [.concise, .examples]
        case .sentence: return [.usage, .origin]
        }
    }

    /// 细节区是否值得展示：当前模式下一条有效信息都没有就整块隐藏（文档 §4.3「Stage2 失败只隐藏细节」）。
    /// - 单词模式：词性义项 / 近义 / 用法 / 出处，任一非空即可；
    /// - 句子模式：只看「用法 / 出处」——译文本身不算细节，否则会逼出空 tab 区。
    public static func hasDetail(_ detail: TranslationDetail?, mode: CardContentMode = .word) -> Bool {
        guard let detail else { return false }
        switch mode {
        case .word:
            return !detail.senses.isEmpty || !detail.synonyms.isEmpty || !detail.usage.isEmpty || !detail.notes.isEmpty
        case .sentence:
            return !detail.usage.isEmpty || !detail.notes.isEmpty
        }
    }

    /// 「出处」tab 的内容：notes 优先，其次是近义词的备注（都为空则 tab 隐藏，见 hasDetail）。
    public static func originLines(from detail: TranslationDetail?) -> [String] {
        guard let detail else { return [] }
        var lines = detail.notes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for synonym in detail.synonyms where !synonym.word.isEmpty {
            if let note = synonym.note, !note.isEmpty {
                lines.append("\(synonym.word)：\(note)")
            } else {
                lines.append(synonym.word)
            }
        }
        return lines
    }

    /// 词性分组 + 义项序号（序号在组内连续）。
    public static func lemmaSections(from detail: TranslationDetail?) -> [LemmaSection] {
        guard let detail else { return [] }
        return detail.senses.map { sense in
            let defs = sense.defs.enumerated().map { index, item in
                LemmaDefinition(number: index + 1, def: item.def, examples: item.examples)
            }
            return LemmaSection(pos: sense.pos.isEmpty ? "—" : sense.pos, defs: defs)
        }
    }

    /// 「例句」tab：摊平所有义项下的例句，保留所属词性做小标题。
    public static func allExamples(from detail: TranslationDetail?) -> [TranslationDetail.ExamplePair] {
        guard let detail else { return [] }
        return detail.senses.flatMap { $0.defs.flatMap(\.examples) }
    }

    public static func examplePairs(from detail: TranslationDetail?) -> [(pos: String, pair: TranslationDetail.ExamplePair)] {
        guard let detail else { return [] }
        var result: [(pos: String, pair: TranslationDetail.ExamplePair)] = []
        for sense in detail.senses {
            for def in sense.defs {
                for pair in def.examples {
                    result.append((sense.pos, pair))
                }
            }
        }
        return result
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

// MARK: - 深色卡片外观（千问式，文档 §4.1）

/// 卡片外壳：深色底 + 12pt 圆角 + 浮层阴影。内容由调用方提供。
public struct DarkCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(14)
            .frame(width: DSMetric.cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DSMetric.cardCorner, style: .continuous)
                    .fill(DSColor.cardSurface)
            )
            // 不要再加 stroke / shadow：SwiftUI 的阴影只能画在 hosting view 内部，
            // 会被窗口边界裁成一圈硬边灰框（就是用户看到的「底框」）；描边则是另一条可见边框。
            // 悬浮感交给 NSPanel 自己的窗口阴影（hasShadow），它不受内容视图裁剪。
            .clipShape(RoundedRectangle(cornerRadius: DSMetric.cardCorner, style: .continuous))
    }
}

// MARK: - 词条块（有道式，文档 §4.2）

/// 词条标题 + 喇叭（只对原文朗读，译文永不挂喇叭）。
public struct LemmaTitleRow: View {
    public let title: String
    public let isPlaying: Bool
    public let onSpeak: () -> Void

    public init(title: String, isPlaying: Bool, onSpeak: @escaping () -> Void) {
        self.title = title
        self.isPlaying = isPlaying
        self.onSpeak = onSpeak
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(DSFont.lemmaTitle)
                .foregroundStyle(DSColor.cardAccent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            SpeakButton(isPlaying: isPlaying, action: onSpeak)
                .scaleEffect(0.85)
            Spacer(minLength: 0)
        }
    }
}

/// 词性 + 义项（序号悬挂缩进 18pt）+ 例句原/译对照。
public struct LemmaSectionsView: View {
    public let sections: [LemmaSection]
    public let showsExamples: Bool

    public init(sections: [LemmaSection], showsExamples: Bool = true) {
        self.sections = sections
        self.showsExamples = showsExamples
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.pos)
                        .font(DSFont.posTag)
                        .foregroundStyle(DSColor.cardTextSecondary)
                    ForEach(section.defs) { def in
                        SenseRow(index: def.number, text: def.def)
                        if showsExamples {
                            ForEach(Array(def.examples.enumerated()), id: \.offset) { _, pair in
                                ExampleRowView(pair: pair)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 例句：原文（次要色）+ 译文（主色），左侧 18pt 悬挂对齐义项文本。
public struct ExampleRowView: View {
    public let pair: TranslationDetail.ExamplePair

    public init(pair: TranslationDetail.ExamplePair) {
        self.pair = pair
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pair.src)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.cardTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(pair.tgt)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.cardTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 18)
    }
}

// MARK: - 底部图标条（千问式）

public struct CardIcon: Hashable, Sendable, Identifiable {
    public let symbol: String
    public let help: String
    public let identifier: String

    public var id: String { identifier }

    public init(symbol: String, help: String, identifier: String) {
        self.symbol = symbol
        self.help = help
        self.identifier = identifier
    }
}

/// 底部图标条：复制 / 赞 / 踩 / 分享 / 重新生成 / 更多。
public struct CardIconBar: View {
    public let icons: [CardIcon]
    public let onTap: (CardIcon) -> Void

    public init(icons: [CardIcon] = CardIcon.defaults, onTap: @escaping (CardIcon) -> Void) {
        self.icons = icons
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 14) {
            ForEach(icons) { icon in
                Button {
                    onTap(icon)
                } label: {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(DSColor.cardTextSecondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(icon.help)
            }
            Spacer(minLength: 0)
        }
    }
}

public extension CardIcon {
    static let copy = CardIcon(symbol: "doc.on.doc", help: "复制译文", identifier: "copy")
    static let up = CardIcon(symbol: "hand.thumbsup", help: "译文有帮助", identifier: "up")
    static let down = CardIcon(symbol: "hand.thumbsdown", help: "译文有问题", identifier: "down")
    static let share = CardIcon(symbol: "square.and.arrow.up", help: "分享", identifier: "share")
    static let regenerate = CardIcon(symbol: "arrow.clockwise", help: "重新生成", identifier: "regenerate")
    static let more = CardIcon(symbol: "ellipsis", help: "更多", identifier: "more")

    static let defaults: [CardIcon] = [.copy, .up, .down, .share, .regenerate, .more]
}

// MARK: - 加载骨架（文档 §4.3）

/// 译文占位：三条呼吸灰条。用 ProgressView 的既有动画，避免引入 SwiftUI 宏。
public struct TranslationSkeleton: View {
    public let lines: Int

    public init(lines: Int = 3) {
        self.lines = lines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<lines, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DSColor.cardDivider.opacity(0.55))
                    .frame(width: index == lines - 1 ? 160 : nil, height: 11)
                    .opacity(index == lines - 1 ? 0.7 : 1)
            }
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 权限与错误件

/// 权限自检的一行：名称 + 状态 + 深链按钮（文档 §7）。
public struct PermissionStatusRow: View {
    public let kind: PermissionKind
    public let granted: Bool
    /// 直接向系统发起授权（AXIsProcessTrustedWithOptions / CGRequestScreenCaptureAccess）。
    public let onRequestAuthorization: (() -> Void)?
    public let onOpenSettings: () -> Void

    public init(
        kind: PermissionKind,
        granted: Bool,
        onRequestAuthorization: (() -> Void)? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.kind = kind
        self.granted = granted
        self.onRequestAuthorization = onRequestAuthorization
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : DSColor.danger)
            Text(kind.displayName)
                .font(.system(size: 12, weight: .medium))
            Text(granted ? "已授权" : "未授权")
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
            Spacer(minLength: 8)
            if let onRequestAuthorization {
                Button("向系统请求授权") { onRequestAuthorization() }
                    .font(.system(size: 11))
            }
            Button("打开系统设置") { onOpenSettings() }
                .font(.system(size: 11))
        }
    }
}

/// 未授权引导卡（文档 §4.3「未授权」分支）。
public struct PermissionGuideCard: View {
    public let onOpenAccessibility: () -> Void
    public let onOpenScreenRecording: () -> Void

    public init(onOpenAccessibility: @escaping () -> Void, onOpenScreenRecording: @escaping () -> Void) {
        self.onOpenAccessibility = onOpenAccessibility
        self.onOpenScreenRecording = onOpenScreenRecording
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还差一步授权", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
            Text("划词需要「辅助功能」，截图需要「屏幕录制」。授权后回到本 App 即生效，无需重启。")
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("授权辅助功能", action: onOpenAccessibility)
                Button("授权屏幕录制", action: onOpenScreenRecording)
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DSMetric.buttonCorner, style: .continuous)
                .fill(DSColor.surfaceSunken)
        )
    }
}

/// 顶部 toast（引擎回落、复制成功、导出完成等）。
public struct ToastBanner: View {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? DSColor.danger : Color.green)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DSColor.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DSColor.divider, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
