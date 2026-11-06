import AppKit
import SwiftUI
import Contracts
import DesignSystem

/// 翻译卡（千问式深色可拖动 + 有道式词条排版）。
/// 结构：顶栏（语言方向 / 档位 / 关闭）→ 原文区（左侧喇叭，只在原文区）→ 译文区（流式 + 图标条）→ 细节 tab。
struct TranslationCardBody: View {
    @ObservedObject var session: TranslationSession
    @ObservedObject var speech: SpeechCoordinator

    private var sourcePlaying: Bool {
        speech.isSpeaking && speech.speakingText == session.sourceText
    }

    var body: some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                divider
                if session.showsEditor {
                    // OCR 编辑态：识别结果 + 翻译结果同屏，不再出引擎/档位选项。
                    editorSection
                } else {
                    sourceSection
                    if showsTranslationBlock {
                        divider
                        translationSection
                    }
                    if showsDetailBlock {
                        divider
                        detailSection
                    }
                    divider
                    iconBar
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(DSColor.cardDivider).frame(height: 1)
    }

    /// 正文里的译文块：句子模式必出；单词模式只在「拿不到词条细节」时兜底显示，
    /// 避免与「简明」tab 的义项文本重复。
    private var showsTranslationBlock: Bool {
        if session.errorText != nil { return true }
        if session.phase == .streaming && session.translationText.isEmpty && session.detail == nil { return true }
        switch session.mode {
        case .sentence: return true
        case .word: return !CardDetailLogic.hasDetail(session.detail, mode: .word)
        }
    }

    private var showsDetailBlock: Bool {
        !session.tabs.isEmpty && CardDetailLogic.hasDetail(session.detail, mode: session.mode)
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 8) {
            Text(session.pairTitle)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.cardTextSecondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if !session.showsEditor {
                Picker("", selection: Binding(
                    get: { session.engine },
                    set: { session.switchEngine($0) }
                )) {
                    Text("机器").tag(TranslationEngineKind.machine)
                    Text("AI").tag(TranslationEngineKind.ai)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 92)
                .help("机器翻译：免密钥、开箱即用，只有译文；AI 翻译：需端点与 Key，另有词条 / 例句 / 用法")
            }

            if !session.showsEditor && session.engine == .ai {
                Picker("", selection: Binding(
                    get: { session.tier },
                    set: { session.switchTier($0) }
                )) {
                    Text("标准").tag(AiTier.standard)
                    Text("高级").tag(AiTier.advanced)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 104)
                .help("标准 / 高级 = 两个模型名，切换即重新翻译")
            }

            Button {
                session.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DSColor.cardTextSecondary)
            .help("关闭（Esc / ⌘W）")
        }
    }

    // MARK: 原文（唯一允许出现喇叭的地方）

    private var sourceSection: some View {
        HStack(alignment: .top, spacing: 8) {
            SpeakButton(isPlaying: sourcePlaying) { session.speakOriginal() }
                .help(sourcePlaying ? "停止朗读" : "朗读原文")

            if session.mode == .word {
                Text(session.sourceText)
                    .font(DSFont.lemmaTitle)
                    .foregroundStyle(DSColor.cardAccent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(session.sourceText)
                    .font(DSFont.sourceText)
                    .foregroundStyle(DSColor.cardTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                session.copySource()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.cardTextSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制原文")
        }
    }

    // MARK: OCR 编辑态（识别结果 + 翻译结果）

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("识别结果（可直接修改错字）")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.cardTextSecondary)
                Spacer(minLength: 0)
                SpeakButton(isPlaying: sourcePlaying) { session.speakOriginal() }
                    .help(sourcePlaying ? "停止朗读" : "朗读识别到的原文")
            }

            TextEditor(text: $session.editableText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: DSMetric.buttonCorner, style: .continuous)
                        .fill(DSColor.cardSurfaceElevated)
                )
                .frame(minHeight: 54, maxHeight: 108)

            divider

            HStack(spacing: 8) {
                Text("翻译结果")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.cardTextSecondary)
                Spacer(minLength: 0)
                if session.canCopyTranslation {
                    Button {
                        session.copyTranslation()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(DSColor.cardTextSecondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("复制译文")
                }
            }

            translationSection

            HStack(spacing: 10) {
                Button("取消") { session.cancelConfirm() }
                Button("翻译并朗读") { session.confirmOCR() }
                    .keyboardShortcut(.return, modifiers: [])
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
        }
    }

    // MARK: 译文

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorText = session.errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(DSColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = session.errorHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.cardTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button("重试") { session.retry() }
                    if session.missingAPIKey {
                        Button("去配置模型") { session.openSettings() }
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
            } else if session.translationText.isEmpty && session.phase == .streaming {
                TranslationSkeleton()
            } else {
                Text(session.translationText.isEmpty ? "—" : session.translationText)
                    .font(DSFont.translation)
                    .foregroundStyle(DSColor.cardTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 默认隐藏：只有「设置 → 通用 → 显示性能指标」或 TRANSLATIONREADER_DEBUG_TIMING=1 才出现。
            if DebugFlags.showTiming,
               let ms = session.firstTokenMs,
               session.phase == .streaming || session.phase == .done {
                Text("首 token \(ms)ms" + (session.totalMs.map { " · 完成 \($0)ms" } ?? ""))
                    .font(.system(size: 10))
                    .foregroundStyle(DSColor.cardTextSecondary.opacity(0.8))
            }
        }
    }

    // MARK: 细节 tab

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTabBar(
                titles: session.tabs.map(\.title),
                selection: Binding(get: { session.selectedTab }, set: { session.selectTab($0) })
            )
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        let detail = session.detail
        let tab = session.tabs.indices.contains(session.selectedTab) ? session.tabs[session.selectedTab] : nil
        switch tab {
        case .concise:
            LemmaSectionsView(sections: CardDetailLogic.lemmaSections(from: detail), showsExamples: true)
        case .examples:
            examplesView(detail)
        case .usage:
            usageView(detail)
        case .origin:
            originView(detail)
        case .none:
            EmptyView()
        }
    }

    private func examplesView(_ detail: TranslationDetail?) -> some View {
        let pairs = CardDetailLogic.examplePairs(from: detail)
        return VStack(alignment: .leading, spacing: 6) {
            if pairs.isEmpty {
                Text("暂无例句")
                    .font(.system(size: 12))
                    .foregroundStyle(DSColor.cardTextSecondary)
            } else {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.pos)
                            .font(DSFont.posTag)
                            .foregroundStyle(DSColor.cardTextSecondary)
                        ExampleRowView(pair: item.pair)
                    }
                }
            }
        }
    }

    private func usageView(_ detail: TranslationDetail?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notes = detail?.usage, !notes.isEmpty {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DSColor.cardTextPrimary)
                        Text(note.body)
                            .font(.system(size: 12))
                            .foregroundStyle(DSColor.cardTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if detail?.usage.isEmpty ?? true {
                Text("暂无用法信息")
                    .font(.system(size: 12))
                    .foregroundStyle(DSColor.cardTextSecondary)
            }
        }
    }

    /// 「出处」tab：notes + 近义备注，与「用法」分开，避免同一段文本在两个 tab 里各出现一次。
    private func originView(_ detail: TranslationDetail?) -> some View {
        let lines = CardDetailLogic.originLines(from: detail)
        return VStack(alignment: .leading, spacing: 6) {
            if lines.isEmpty {
                Text("暂无出处信息")
                    .font(.system(size: 12))
                    .foregroundStyle(DSColor.cardTextSecondary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(DSColor.cardTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 图标条

    private var iconBar: some View {
        CardIconBar { icon in
            switch icon.identifier {
            case "copy": session.copyTranslation()
            case "regenerate": session.retry()
            case "more": session.toggleFavorite()
            case "share": session.copySource()
            case "up", "down": session.toggleFavorite()
            default: break
            }
        }
    }
}
