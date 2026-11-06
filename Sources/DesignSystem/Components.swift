import SwiftUI
import Contracts

/// 原文区喇叭按钮（文档 §3.3：只读原文，译文区不出现喇叭）。
public struct SpeakButton: View {
    public let isPlaying: Bool
    public let action: () -> Void

    public init(isPlaying: Bool, action: @escaping () -> Void) {
        self.isPlaying = isPlaying
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "waveform" : "speaker.wave.2")
                .font(DSFont.speakButton)
                .foregroundStyle(isPlaying ? DSColor.accent : DSColor.textPrimary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "停止朗读" : "朗读原文")
    }
}

/// 词条义项行：悬挂缩进 18pt + 序号（文档 §4.2）。
public struct SenseRow: View {
    public let index: Int
    public let text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(index).")
                .font(DSFont.senseIndex)
                .foregroundStyle(DSColor.textSecondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DSColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 18)
        .padding(.trailing, 0)
    }
}

/// 细节区分页条（简明 / 例句），未选中用 surfaceSunken（文档 §4.1）。
public struct SectionTabBar: View {
    public let titles: [String]
    @Binding public var selection: Int

    public init(titles: [String], selection: Binding<Int>) {
        self.titles = titles
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { offset, title in
                Button {
                    selection = offset
                } label: {
                    Text(title)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: DSMetric.buttonCorner)
                                .fill(offset == selection ? DSColor.surfaceElevated : DSColor.surfaceSunken)
                        )
                        .foregroundStyle(offset == selection ? DSColor.accent : DSColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 卡片容器：圆角 12pt + 主题底色（文档 §4.2）。
public struct CardContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: DSMetric.cardCorner)
                    .fill(DSColor.surface)
            )
    }
}
