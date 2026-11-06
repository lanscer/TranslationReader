import SwiftUI
import Contracts
import DesignSystem

/// 文档 §3.2：顶栏（语言方向 + 模型档位 + 关闭）、原文区（喇叭 + 可选中原文）、译文区。
/// 细节区与底部输入条属于 M2，本卡先留出结构位置。
public struct TranslationCardView: View {
    @ObservedObject private var model: TranslationCardModel

    public init(model: TranslationCardModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Rectangle().fill(DSColor.divider).frame(height: 1)
            sourceSection
            Rectangle().fill(DSColor.divider).frame(height: 1)
            translationSection
        }
        .padding(14)
        .frame(width: DSMetric.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSMetric.cardCorner, style: .continuous)
                .fill(DSColor.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSMetric.cardCorner, style: .continuous)
                .stroke(DSColor.divider, lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.languagePairTitle)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { model.tier },
                set: { model.onTierChange($0) }
            )) {
                Text("标准").tag(AiTier.standard)
                Text("高级").tag(AiTier.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)

            Button {
                model.onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DSColor.textSecondary)
            .help("关闭（Esc / ⌘W）")
        }
    }

    private var sourceSection: some View {
        HStack(alignment: .top, spacing: 8) {
            SpeakButton(isPlaying: model.isSpeaking, action: model.onSpeak)
            Text(model.sourceText)
                .font(DSFont.sourceText)
                .foregroundStyle(DSColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(DSColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.translationText.isEmpty ? (model.isStreaming ? "翻译中…" : "—") : model.translationText)
                    .font(DSFont.translation)
                    .foregroundStyle(DSColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("复制", action: model.onCopyTranslation)
                Button("重新生成", action: model.onRegenerate)
                Spacer(minLength: 0)
                if model.isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(DSColor.textSecondary)
        }
    }
}
