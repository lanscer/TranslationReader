import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Contracts
import DesignSystem
import Store

@MainActor
final class HistoryListModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published var favoritesOnly: Bool = false
    @Published var statusMessage: String?

    private unowned let env: AppEnvironment
    private let pageSize = 500

    init(env: AppEnvironment) {
        self.env = env
        refresh()
    }

    func refresh() {
        let all = env.recentEntries(limit: pageSize)
        favoriteIDs = env.favoriteIDs()
        entries = favoritesOnly ? all.filter { favoriteIDs.contains($0.id) } : all
        statusMessage = "共 \(entries.count) 条" + (favoritesOnly ? "（仅收藏）" : "")
    }

    func toggleFavorite(_ id: String) {
        env.toggleFavorite(id)
        refresh()
    }

    func speak(_ entry: HistoryEntry) {
        env.speech.speak(entry.sourceText, lang: LanguageHint.bcp47(entry.sourceText))
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        env.toast.show("已复制")
    }

    func retranslate(_ entry: HistoryEntry) {
        env.card.present(text: entry.sourceText, kind: entry.sourceKind, anchor: CGRect(origin: NSEvent.mouseLocation, size: .zero))
    }
}

/// 历史窗口（文档 §3.6 / §9 M4）：时间 / 原文 / 译文 / 来源，可重新朗读与复制，支持收藏过滤与导出。
@MainActor
final class HistoryWindowController: NSWindowController {
    private let env: AppEnvironment
    private let listModel: HistoryListModel

    init(env: AppEnvironment) {
        self.env = env
        self.listModel = HistoryListModel(env: env)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "历史"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: HistoryListView(model: listModel, controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        listModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func export() {
        let entries = env.recentEntries(limit: 20000)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "translation-history.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryExport.write(entries, to: url)
            env.toast.show("已导出 \(entries.count) 条到 " + url.lastPathComponent)
        } catch {
            env.toast.show("导出失败：\(error.localizedDescription)", isError: true)
        }
    }

    func clearAll() {
        guard let history = env.history else { return }
        do {
            try history.deleteAll()
            listModel.refresh()
            env.toast.show("历史已清空")
        } catch {
            env.toast.show("清空失败：\(error.localizedDescription)", isError: true)
        }
    }
}

struct HistoryListView: View {
    @ObservedObject var model: HistoryListModel
    let controller: HistoryWindowController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("仅收藏", isOn: Binding(get: { model.favoritesOnly }, set: { model.favoritesOnly = $0; model.refresh() }))
                Button("刷新") { model.refresh() }
                Button("导出 JSON…") { controller.export() }
                Button("清空") { controller.clearAll() }
                Spacer(minLength: 0)
                Text(model.statusMessage ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
            }
            .padding(10)
            Divider()
            if model.entries.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有历史记录").font(.system(size: 13))
                    Text("用 ⌥Space 翻译剪贴板，或菜单「手动输入…」跑一条。")
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(time(entry.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(DSColor.textSecondary)
                Text(entry.sourceKind.rawValue)
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(DSColor.surfaceSunken))
                    .foregroundStyle(DSColor.textSecondary)
                if model.favoriteIDs.contains(entry.id) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                }
                if let error = entry.error {
                    Text(error).font(.system(size: 9)).foregroundStyle(DSColor.danger).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(model.favoriteIDs.contains(entry.id) ? "取消收藏" : "收藏") { model.toggleFavorite(entry.id) }
                    .font(.system(size: 10))
                Button("朗读") { model.speak(entry) }
                    .font(.system(size: 10))
                Button("复制原文") { model.copy(entry.sourceText) }
                    .font(.system(size: 10))
                Button("重译") { model.retranslate(entry) }
                    .font(.system(size: 10))
            }
            Text(entry.sourceText)
                .font(.system(size: 12))
                .lineLimit(2)
            Text(entry.translation ?? "（无译文）")
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func time(_ epoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
