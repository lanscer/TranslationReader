import SwiftUI
import DesignSystem

/// 文档 §3.1：浮条 = [logo] [文A 翻译] [···]，右侧 ··· 展开二级菜单。
/// 浮条窗口不能成为 key window，所以全部按钮用 .buttonStyle(.plain) 自绘点击。
public struct SelectionBarView: View {
    @ObservedObject private var model: SelectionBarModel

    public init(model: SelectionBarModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DSColor.textSecondary)
                .padding(.horizontal, 6)
                .help("划词翻译")

            Rectangle()
                .fill(DSColor.divider)
                .frame(width: 1, height: 16)

            Button {
                model.onTranslate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "character")
                        .font(.system(size: 12, weight: .medium))
                    Text("翻译")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DSColor.accent)

            Button {
                model.onSpeak()
            } label: {
                Image(systemName: model.isSpeaking ? "waveform" : "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isSpeaking ? DSColor.accent : DSColor.textPrimary)
            .help(model.isSpeaking ? "停止朗读" : "朗读原文")

            Menu {
                Button("复制原文", action: model.onCopy)
                Button(model.isSpeaking ? "停止朗读" : "朗读原文", action: model.onSpeak)
                Button(model.isFavorited ? "取消收藏" : "收藏", action: model.onFavorite)
                Divider()
                Button("用高级模型重译", action: model.onAdvancedRetranslate)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .foregroundStyle(DSColor.textSecondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: DSMetric.barCorner, style: .continuous)
                .fill(DSColor.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSMetric.barCorner, style: .continuous)
                .stroke(DSColor.divider, lineWidth: 0.5)
        )
        .fixedSize()
    }
}
