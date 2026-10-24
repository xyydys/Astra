import SwiftUI
import UIKit

/// 底栏图标：首页按模式各用一个图标，收藏 / 历史 / 我的也能换，全部是 SF Symbols 的名字。
/// 系统没有列出全部符号的接口，所以不内置符号库：输入名字（可以在「SF Symbols」App 里查）
/// 即时预览、检查这个系统版本有没有，另外给一组常用的建议。搜索按钮由系统固定，不能换。
enum TabIconSlot: Hashable, Identifiable {
    case home(ContentMode)
    case favorites
    case history
    case settings

    static var all: [TabIconSlot] {
        ContentMode.allCases.map { .home($0) } + [.favorites, .history, .settings]
    }

    var id: String { key }

    var key: String {
        switch self {
        case .home(let mode): return "home." + mode.rawValue
        case .favorites: return "favorites"
        case .history: return "history"
        case .settings: return "settings"
        }
    }

    var title: String {
        switch self {
        case .home(let mode): return "首页 · \(mode.title)"
        case .favorites: return "收藏"
        case .history: return "历史"
        case .settings: return "我的"
        }
    }

    var defaultIcon: String {
        switch self {
        case .home(.anime): return "play.tv"
        case .home(.video): return "film"
        case .home(.comic): return "book"
        case .home(.novel): return "text.book.closed"
        case .home(.music): return "music.note"
        case .favorites: return "heart"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "person.crop.circle"
        }
    }
}

enum TabIcons {
    /// 自定义的图标，存成「位置=符号名」的 JSON
    static let storageKey = "tabIcons"
    static let recentsKey = "tabIconRecents"

    static func decode(_ raw: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    static func encode(_ map: [String: String]) -> String {
        (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// 某个位置当前用的图标：自定义的名字在这个系统版本不存在时退回默认
    static func icon(for slot: TabIconSlot, in raw: String) -> String {
        if let custom = decode(raw)[slot.key], isValid(custom) { return custom }
        return slot.defaultIcon
    }

    static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && UIImage(systemName: trimmed) != nil
    }

    /// 常用建议（运行时过滤掉这个系统版本没有的）
    static let suggestions: [String] = [
        "house", "house.fill", "play.house", "play.house.fill", "play.tv", "play.tv.fill", "tv", "sparkles.tv",
        "film", "film.stack", "popcorn", "movieclapper", "play.rectangle", "play.circle", "sparkles", "star",
        "book", "book.fill", "books.vertical", "book.closed", "text.book.closed", "book.pages", "magazine",
        "newspaper", "character.book.closed", "music.note", "music.note.list", "music.quarternote.3", "headphones",
        "music.mic", "waveform", "opticaldisc", "hifispeaker", "heart", "heart.fill", "heart.circle", "star.fill",
        "bookmark", "bookmark.fill", "tray.full", "archivebox", "clock", "clock.arrow.circlepath", "calendar",
        "hourglass", "person", "person.crop.circle", "person.circle", "gearshape", "gearshape.fill", "slider.horizontal.3",
        "pawprint", "pawprint.fill", "camera.macro", "tornado", "leaf", "flame", "moon.stars", "sun.max", "cloud",
        "bolt", "gamecontroller", "puzzlepiece", "crown", "gift", "cat", "dog", "fish", "bird", "hare", "tortoise",
        "face.smiling", "theatermasks", "paintpalette", "wand.and.stars", "globe.asia.australia",
    ]
}

// MARK: - 设置页

/// 设置 → 外观 → 底栏图标
struct TabIconSettingsView: View {
    @AppStorage(TabIcons.storageKey) private var raw = ""

    var body: some View {
        List {
            Section {
                ForEach(ContentMode.allCases) { mode in
                    row(.home(mode))
                }
            } header: {
                Text("首页（跟着模式换）")
            } footer: {
                Text("切换番剧、影视、漫画、小说、音乐时，首页按钮换成对应的图标。")
            }

            Section {
                row(.favorites)
                row(.history)
                row(.settings)
            } header: {
                Text("其他按钮")
            } footer: {
                Text("搜索按钮由系统固定，不能更换。")
            }

            if !TabIcons.decode(raw).isEmpty {
                Section {
                    Button("全部恢复默认", role: .destructive) {
                        raw = ""
                        Haptics.success()
                    }
                }
            }
        }
        .navigationTitle("底栏图标")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ slot: TabIconSlot) -> some View {
        let icon = TabIcons.icon(for: slot, in: raw)
        return NavigationLink(destination: TabIconPicker(slot: slot)) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.title)
                    Text(icon)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// 给一个位置选图标：输入名字即时预览，或者点建议
struct TabIconPicker: View {
    let slot: TabIconSlot
    @AppStorage(TabIcons.storageKey) private var raw = ""
    @AppStorage(TabIcons.recentsKey) private var recentsRaw = ""
    @State private var input = ""

    private let grid = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    private var current: String { TabIcons.icon(for: slot, in: raw) }
    private var typed: String { input.trimmingCharacters(in: .whitespaces).lowercased() }
    private var typedValid: Bool { TabIcons.isValid(typed) }
    private var recents: [String] { recentsRaw.split(separator: "\n").map(String.init).filter(TabIcons.isValid) }

    /// 建议：输入了内容时按名字筛选
    private var suggestions: [String] {
        let all = TabIcons.suggestions.filter(TabIcons.isValid)
        guard !typed.isEmpty else { return all }
        return all.filter { $0.contains(typed) }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: typedValid ? typed : current)
                        .font(.system(size: 54))
                        .foregroundStyle(.tint)
                        .frame(height: 70)
                        .symbolReplaceTransition()
                    Text(typedValid ? typed : current)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                TextField("输入 SF Symbols 名称，如 pawprint.fill", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .submitLabel(.done)
                    .onSubmit { if typedValid { choose(typed) } }
                if !typed.isEmpty {
                    if typedValid {
                        Button("使用「\(typed)」", icon: "checkmark.circle") { choose(typed) }
                    } else {
                        Label("没有这个图标，或者这个系统版本还不支持", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("名字可以在 Apple 的「SF Symbols」App 或图标查询 App 里查到，复制过来粘贴即可。底栏会自动显示实心样式。")
            }

            if !recents.isEmpty, typed.isEmpty {
                Section("最近用过") {
                    iconGrid(recents)
                }
            }

            Section(typed.isEmpty ? "常用" : "匹配的建议") {
                if suggestions.isEmpty {
                    Text("没有匹配的建议，直接输入完整名字也可以")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    iconGrid(suggestions)
                }
            }

            if current != slot.defaultIcon {
                Section {
                    Button("恢复默认（\(slot.defaultIcon)）", role: .destructive) { choose(nil) }
                }
            }
        }
        .navigationTitle(slot.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iconGrid(_ names: [String]) -> some View {
        LazyVGrid(columns: grid, spacing: 12) {
            ForEach(names, id: \.self) { name in
                Button {
                    choose(name)
                } label: {
                    Image(systemName: name)
                        .font(.title2)
                        .frame(width: 56, height: 48)
                        .foregroundStyle(name == current ? Color.white : Color.primary)
                        .background(
                            name == current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
        .padding(.vertical, 6)
    }

    /// 选定一个图标；nil 表示恢复默认
    private func choose(_ name: String?) {
        var map = TabIcons.decode(raw)
        if let name, name != slot.defaultIcon {
            map[slot.key] = name
            if !TabIcons.suggestions.contains(name) {
                let list = [name] + recents.filter { $0 != name }
                recentsRaw = list.prefix(12).joined(separator: "\n")
            }
        } else {
            map[slot.key] = nil
        }
        raw = TabIcons.encode(map)
        input = ""
        Haptics.success()
    }
}
