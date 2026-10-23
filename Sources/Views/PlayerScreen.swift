import SwiftUI

struct PlayerScreen: View {
    let request: PlayRequest

    @EnvironmentObject private var ruleStore: RuleStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: PlayerModel?

    var body: some View {
        Group {
            if let model {
                PlayerContent(model: model)
            } else {
                Color.black
            }
        }
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        .tabBarHiddenCompat()
        .task {
            if model == nil {
                let created = PlayerModel(request: request, rule: request.isCMS ? nil : ruleStore.rule(named: request.ruleName))
                model = created
                created.start()
            }
        }
        .onDisappear {
            // 全屏和画中画也会触发 onDisappear，这两种情况继续播放
            guard let model, !model.isFullscreen, !model.isPictureInPicture else { return }
            model.teardown()
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase != .active { model?.saveProgress() }
        }
    }
}

private struct PlayerContent: View {
    @ObservedObject var model: PlayerModel
    @State private var copiedLog = false
    /// 选集列表倒序（记住上次的选择）
    @AppStorage("episodeListReversed") private var episodesReversed = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    info
                    if model.roads.count > 1 { roadPicker }
                    episodes
                }
                .padding()
            }
        }
        .background(alignment: .topLeading) {
            HiddenWebViewHost(webView: model.sniffer.webView)
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: 视频区域

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoPlayerView(
                player: model.player,
                onFullscreenChange: { model.isFullscreen = $0 },
                onPictureInPictureChange: { model.isPictureInPicture = $0 }
            )
            .opacity(model.phase == .ready ? 1 : 0)

            switch model.phase {
            case .loadingChapters:
                status(text: "正在获取剧集列表…")
            case .resolving:
                status(text: "正在解析视频地址…")
            case .ready:
                EmptyView()
            case .failed(let message):
                failure(message)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func status(text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button("重试", icon: "arrow.clockwise") { model.retry() }
                        .glassProminentButtonStyle()
                    Button(copiedLog ? "已复制" : "复制日志", icon: "doc.on.doc") {
                        UIPasteboard.general.string = model.debugLog
                        copiedLog = true
                    }
                    .glassButtonStyle()
                }
            }
        }
    }

    // MARK: 信息

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.currentEpisode.map { "\(model.request.title) · \($0.name)" } ?? model.request.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(model.rule?.name ?? model.request.ruleName) · \(model.request.sourceTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.adSegmentsRemoved > 0 {
                Label("已跳过 \(model.adSegmentsRemoved) 个广告片段", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.hasNextEpisode, model.phase == .ready {
                Button("下一集", icon: "forward.end.fill") { model.playNext() }
                    .glassButtonStyle()
                    .controlSize(.small)
                    .padding(.top, 6)
            }
        }
    }

    private var roadPicker: some View {
        Picker("线路", selection: $model.selectedRoad) {
            ForEach(model.roads.indices, id: \.self) { index in
                Text(model.roads[index].name).tag(index)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: 选集

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.roads.indices.contains(model.selectedRoad) {
                let road = model.roads[model.selectedRoad]
                HStack {
                    Text("选集 · 共 \(road.episodes.count) 集")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.snappyCompat) { episodesReversed.toggle() }
                    } label: {
                        Label(episodesReversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                            .font(.subheadline)
                    }
                    .glassButtonStyle()
                    .controlSize(.small)
                    .accessibilityHint("切换选集列表的排列顺序")
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(episodesReversed ? Array(road.episodes.indices.reversed()) : Array(road.episodes.indices), id: \.self) { index in
                        let isCurrent = model.playingRoad == model.selectedRoad && model.playingEpisode == index
                        Button {
                            model.play(road: model.selectedRoad, episode: index)
                        } label: {
                            Text(road.episodes[index].name)
                                .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                                .background(
                                    isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.14)),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
