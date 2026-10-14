import SwiftUI
import BitClipboardCore
import ServiceManagement

private let accent = Color.primary
private let imageCornerRadius: CGFloat = 8

private enum HistoryFilter: String, CaseIterable {
    case all = "全部", text = "文字", image = "图片", link = "链接", pinned = "收藏"
    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return item.isPinned
        case .text: return item.kind == .text
        case .image: return item.kind == .image
        case .link: return item.kind == .link
        }
    }
}

struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var searchModel: SemanticSearchController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var filterSelection
    @State private var filter: HistoryFilter = .all
    @State private var preview: ClipboardItem?
    @State private var hoveredItem = HoveredHistoryItem()
    @State private var showSettings = false
    @State private var confirmClear = false
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    init(store: ClipboardStore) {
        self.store = store
        _searchModel = ObservedObject(wrappedValue: store.semanticSearch)
    }

    private var query: String { searchModel.query }

    private var results: [ClipboardItem] {
        SearchRanking.results(items: store.items.filter { filter.matches($0) }, query: query, semanticScores: searchModel.scores)
    }

    private var contentAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }

    var body: some View {
        let visibleItems = results
        return VStack(spacing: 0) {
            toolbar
            if !query.isEmpty {
                HStack(spacing: 6) {
                    if searchModel.isSearching { ProgressView().controlSize(.mini) }
                    Text(searchModel.status).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("清除") { searchModel.query = "" }.buttonStyle(.plain).font(.system(size: 10))
                }.padding(.horizontal, 14).padding(.vertical, 6)
            }
            if let error = store.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.secondary)
                    Text(error).font(.system(size: 11))
                    Spacer(minLength: 0)
                    Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(Color.primary.opacity(0.05))
            }
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            HistoryRow(item: item, store: store, preview: { preview = item }, hoverChanged: { hovering in
                                if hovering { hoveredItem.id = item.id }
                                else if hoveredItem.id == item.id { hoveredItem.id = nil }
                            })
                                .transition(rowTransition)
                                .background {
                                    if index < 9 {
                                        Button("") { store.copy(item) }
                                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                                            .hidden().accessibilityHidden(true)
                                    }
                                }
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
                .opacity(visibleItems.isEmpty ? 0 : 1)
                .allowsHitTesting(!visibleItems.isEmpty)
                .accessibilityHidden(visibleItems.isEmpty)

                if visibleItems.isEmpty {
                    emptyState.transition(reduceMotion ? .identity : .opacity)
                }
            }
            .animation(contentAnimation, value: visibleItems.map(\.id))
        }
        .frame(width: 420, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .background {
            HoverPreviewKeyHandler(
                hoveredItem: hoveredItem,
                isEnabled: preview == nil && !showSearch && !showSettings && !confirmClear
            ) { id in
                if let item = visibleItems.first(where: { $0.id == id }) { preview = item }
            }.frame(width: 0, height: 0)
        }
        .onChange(of: filter) { _ in hoveredItem.id = nil }
        .onChange(of: query) { _ in hoveredItem.id = nil }
        .onDisappear { hoveredItem.id = nil }
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(item: $preview) { item in PreviewView(item: item, store: store) }
        .alert("清空历史记录？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.clear() }
        } message: { Text("删除未收藏的记录和本地图片，已收藏的内容会保留。此操作无法撤销。") }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            filters
            Button { showSearch.toggle() } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(query.isEmpty ? Color.secondary : accent)
                    .frame(width: 26, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help(query.isEmpty ? "搜索（⌘F）" : "搜索：\(query)")
            .accessibilityLabel("搜索")
            .popover(isPresented: $showSearch, arrowEdge: .top) {
                search.padding(14).frame(width: 290)
                    .onAppear { searchFocused = true }
            }
            Menu {
                Button(store.isPaused ? "继续记录" : "暂停记录") { store.isPaused.toggle() }
                Button("设置…") { showSettings = true }
                Divider()
                Button("清空未收藏记录…", role: .destructive) { confirmClear = true }
                Divider()
                Button("退出 BitClipboard") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 24, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作")
        }.padding(.horizontal, 14).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("描述想找的内容或输入关键词", text: $searchModel.query).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                    .onSubmit { showSearch = false }
                if !query.isEmpty {
                    Button { searchModel.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                } else {
                    Text("⌘ F").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.padding(.horizontal, 12).frame(height: 37)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.035)))
            Text(searchModel.status).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(HistoryFilter.allCases, id: \.self) { value in
                Button { filter = value } label: {
                    HStack(spacing: 4) {
                        Text(value.rawValue).font(.system(size: 11, weight: filter == value ? .semibold : .medium))
                    }.frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(filter == value ? (colorScheme == .dark ? Color.black : Color.white) : .secondary)
                        .background {
                            if filter == value {
                                RoundedRectangle(cornerRadius: 7).fill(accent)
                                    .matchedGeometryEffect(id: "selected-filter", in: filterSelection)
                            }
                        }
                }.buttonStyle(.plain)
            }
        }.animation(contentAnimation, value: filter)
    }

    private var emptyState: some View {
        Text(!query.isEmpty ? (searchModel.isSearching ? "正在查找相关内容…" : "没有找到相关内容") :
                store.items.isEmpty ? "你还没有复制任何内容" :
                filter == .pinned ? "还没有收藏任何内容" : "这个分类还没有内容")
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                EmptyHistoryAnimation()
                    .frame(width: 180, height: 180)
                    .foregroundStyle(accent).opacity(0.14)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }

}

private struct HoverPreviewKeyHandler: View {
    @ObservedObject var hoveredItem: HoveredHistoryItem
    let isEnabled: Bool
    let preview: (UUID) -> Void

    var body: some View {
        SpaceKeyHandler(isEnabled: isEnabled && hoveredItem.id != nil) {
            if let id = hoveredItem.id { preview(id) }
        }
    }
}

/// Native adaptation of SVG Spinners' MIT-licensed pulse-rings-3 icon.
/// Original asset and license are bundled under Resources/ThirdParty.
private struct EmptyHistoryAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                Circle().stroke(lineWidth: 8)
                    .padding(4)
                    .scaleEffect(reduceMotion ? 0.5 + Double(index) * 0.16 : expanded ? 1 : 0)
                    .opacity(reduceMotion ? 0.4 : expanded ? 0 : 1)
                    .animation(reduceMotion ? nil :
                        .timingCurve(0.52, 0.6, 0.25, 0.99, duration: 1.2)
                            .repeatForever(autoreverses: false).delay(Double(index) * 0.4),
                        value: expanded)
            }
        }
        .onAppear { expanded = true }
        .onDisappear { expanded = false }
    }
}

private struct HistoryRow: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipboardStore
    let preview: () -> Void
    let hoverChanged: (Bool) -> Void
    @State private var hovered = false
    @StateObject private var content: HistoryRowContent
    private let maximumImageHeight: CGFloat = 160

    init(item: ClipboardItem, store: ClipboardStore, preview: @escaping () -> Void, hoverChanged: @escaping (Bool) -> Void) {
        self.item = item
        self.store = store
        self.preview = preview
        self.hoverChanged = hoverChanged
        _content = StateObject(wrappedValue: HistoryRowContent(item: item))
    }

    var body: some View {
        let tokens = content.tokens
        return VStack(alignment: .leading, spacing: 0) {
            Button { store.copy(item) } label: {
                Group {
                    if item.kind == .image && (content.image != nil || content.imageLoading) {
                        FittedImageLayout(imageSize: content.image?.size ?? content.imageSize, maximumHeight: maximumImageHeight) {
                            Group {
                                if let image = content.image {
                                    Image(nsImage: image).resizable().interpolation(.medium)
                                } else {
                                    Rectangle().fill(Color.primary.opacity(0.035))
                                }
                            }
                                .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))
                                .accessibilityLabel("图片预览，点击复制")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(item.kind == .image ? "图片不可用" : content.summary)
                            .font(.system(size: 13)).lineSpacing(4).lineLimit(3)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    }
                }
                .padding(13).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击复制完整内容")

            if !tokens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(tokens) { token in
                            let copied = store.copiedTokenID == item.id.uuidString + ":" + token.id
                            Button { store.copy(token, from: item) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: copied ? "checkmark" : token.kind == .link ? "link" : "number")
                                    Text(token.value).lineLimit(1).truncationMode(.middle)
                                        .frame(maxWidth: 220)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(copied ? Color.primary : .secondary)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color.primary.opacity(copied ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(copied ? "已复制" : "复制\(token.kind == .link ? "链接" : "数字")：\(token.value)")
                            .accessibilityLabel("复制\(token.kind == .link ? "链接" : "数字") \(token.value)")
                        }
                    }
                }
                .frame(height: 28)
                .padding(.horizontal, 13).padding(.bottom, 13)
            }
        }
        .background(Color.primary.opacity(hovered ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if store.copiedID == item.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                    .padding(8).background(.regularMaterial, in: Circle()).padding(5)
                    .accessibilityLabel("已复制")
            }
        }
            .help("点击复制；悬停时按空格预览；右键查看更多操作")
            .onAppear { content.load(item: item, imageURL: store.previewImageURL(for: item)) }
            .onHover {
                hovered = $0
                hoverChanged($0)
            }
            .onDisappear {
                hoverChanged(false)
                if item.kind == .image { content.unloadImage() }
            }
            .contextMenu {
                Button("复制") { store.copy(item) }
                Button(item.isPinned ? "取消收藏" : "收藏") { store.pin(item) }
                Button("查看完整内容", action: preview)
                Divider()
                Button("删除", role: .destructive) { store.delete(item) }
            }
    }
}

/// Measure from the original aspect ratio, so small images don't acquire empty space.
private struct FittedImageLayout: Layout {
    let imageSize: CGSize
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let availableWidth = max(0, proposal.width ?? imageSize.width)
        let scale = min(1, availableWidth / imageSize.width, maximumHeight / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

private struct PreviewView: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(item.kind.title, systemImage: item.kind.symbol).font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let url = store.previewImageURL(for: item), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))
                        .frame(maxWidth: .infinity)
                } else {
                    Text(item.kind == .image ? "图片不可用" : item.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(minHeight: 250, maxHeight: 370)
            HStack {
                Text(item.source).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(store.copiedID == item.id ? "已复制" : "复制内容") { store.copy(item) }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 380).tint(accent)
            .background {
                SpaceKeyHandler(isEnabled: true) { dismiss() }.frame(width: 0, height: 0)
            }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject private var searchModel: SemanticSearchController
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    init(store: ClipboardStore) {
        self.store = store
        _searchModel = ObservedObject(wrappedValue: store.semanticSearch)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("设置").font(.system(size: 20, weight: .bold))
                Spacer()
                Button("完成") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("自动记录剪贴板", isOn: Binding(get: { !store.isPaused }, set: { store.isPaused = !$0 }))
                    Toggle("登录时启动", isOn: $launchAtLogin).onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            store.error = "登录启动设置失败：\(error.localizedDescription)"
                        }
                    }
                    Picker("历史记录上限", selection: $store.historyLimit) {
                        Text("100 条").tag(100)
                        Text("200 条").tag(200)
                        Text("500 条").tag(500)
                        Text("1,000 条").tag(1000)
                    }
                    Divider()
                    modelSettings
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的内容，留在你的 Mac").font(.system(size: 12, weight: .semibold))
                        Text("历史记录保存在本机，不上传至云端。收藏不受数量限制。会忽略标记为敏感或临时的剪贴板内容；未标记的密码等文字仍可能被记录，可随时暂停。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        Text("唤起面板  ⌃⌥V    ·    快速复制  ⌘1–9").font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                    }
                    Text("BitClipboard 1.0.0").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 380, height: 560).tint(accent)
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
                Toggle("自然语言语义搜索", isOn: $searchModel.enabled)
                Text("Google EmbeddingGemma 2 · 本机运行\n支持文字和链接，例如“关于会议安排的内容”。首次安装需要联网下载模型，搜索时保持离线。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                if searchModel.isInstalling {
                    VStack(alignment: .leading, spacing: 6) {
                        let progress = searchModel.installationProgress
                        HStack {
                            Text(progress?.title ?? "准备安装环境").font(.system(size: 11))
                            Spacer()
                            if let fraction = progress?.fraction {
                                Text("\(Int(fraction * 100))%")
                                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            }
                        }
                        if let fraction = progress?.fraction {
                            ProgressView(value: fraction).progressViewStyle(.linear)
                        } else { ProgressView().controlSize(.small) }
                        Text(progress?.detail ?? "正在准备，请稍候…")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("关闭设置后会继续下载，重新打开可查看进度。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                } else if let error = searchModel.installationError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                } else {
                    Label(searchModel.ready ? "本地模型已就绪" : "本地模型尚未安装", systemImage: searchModel.ready ? "checkmark.circle" : "arrow.down.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Button(searchModel.isInstalling ? "正在安装…" : searchModel.installationError != nil ? "重试安装" : searchModel.ready ? "重新安装模型" : "下载并安装模型") { searchModel.install() }
                        .disabled(searchModel.isInstalling)
                    Button("安装日志") { searchModel.openInstallLog() }
                }
        }
    }
}
