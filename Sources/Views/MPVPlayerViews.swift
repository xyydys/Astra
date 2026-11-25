import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - 画面容器

/// mpv 的画面只有一个，在内嵌和全屏之间搬：claim 为 true 的容器持有它
struct MPVVideoHost: UIViewRepresentable {
    let surface: MPVSurfaceView
    let claim: Bool

    func makeUIView(context: Context) -> MPVContainerView {
        let container = MPVContainerView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        if claim { Self.attach(surface, to: container) }
        return container
    }

    func updateUIView(_ container: MPVContainerView, context: Context) {
        if claim, surface.superview !== container { Self.attach(surface, to: container) }
    }

    /// 画面尺寸不变，容器按自己的大小缩放、居中（见 MPVContainerView）
    private static func attach(_ surface: MPVSurfaceView, to container: MPVContainerView) {
        surface.removeFromSuperview()
        container.addSubview(surface)
        container.setNeedsLayout()
    }
}

// MARK: - 控制条与手势

struct MPVControls: View {
    @ObservedObject var mpv: MPVPlayback
    var title = ""
    let isFullscreen: Bool
    var onNextEpisode: (() -> Void)? = nil
    let toggleFullscreen: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.defaultPlaybackSpeedKey) private var defaultSpeed: Double = 1.0
    @AppStorage(AppAccent.key) private var accentHex = ""

    @State private var visible = true
    @State private var isLocked = false
    @State private var lockBadgeVisible = false
    @State private var scrub: Double?
    @State private var gestureSeekStart: Double = 0
    @State private var gestureSeekTarget: Double?
    @State private var meterHUD: MeterHUD?
    @State private var doubleTapPulse: DoubleTapPulse?
    @State private var hideTask: Task<Void, Never>?
    @State private var meterHideTask: Task<Void, Never>?
    @State private var lockHideTask: Task<Void, Never>?
    @State private var pulseHideTask: Task<Void, Never>?
    @State private var boostPulse = false

    private static let fullscreenEdgePadding: CGFloat = 14
    private static let fullscreenIconDiameter: CGFloat = 36
    private static let fullscreenIconHitSize: CGFloat = 44
    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3]
    private static let defaultSpeedOptions: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private struct MeterHUD: Equatable {
        enum Kind: Equatable { case brightness, volume }
        let kind: Kind
        let value: Double
    }

    private struct DoubleTapPulse: Equatable {
        let id = UUID()
        let paused: Bool
    }

    private var displayedPosition: Double {
        scrub ?? gestureSeekTarget ?? mpv.position
    }

    private var hasActiveCenterHUD: Bool {
        gestureSeekTarget != nil || scrub != nil || meterHUD != nil
    }

    var body: some View {
        ZStack {
            // 铺满整个屏幕（包含安全区）的渐隐遮罩：不会出现未铺满的矩形黑框
            scrim
                .ignoresSafeAreaIf(isFullscreen)
                .opacity(visible && !isLocked ? 1 : 0)
                .allowsHitTesting(false)

            // 手势层同样铺满全屏（边缘留出系统手势缓冲区）
            MPVGestureOverlay(
                isFullscreen: isFullscreen,
                isLocked: isLocked,
                canSeek: { mpv.duration > 0 },
                canBoost: { !mpv.isPaused },
                onSingleTap: handleSingleTap,
                onDoubleTap: handleDoubleTap,
                onBoostStart: handleBoostStart,
                onBoostEnd: handleBoostEnd,
                onSeekBegin: handleGestureSeekBegin,
                onSeekUpdate: handleGestureSeekUpdate,
                onSeekEnd: handleGestureSeekEnd,
                onBrightnessChanged: { showMeter(.brightness, value: $0, autoHide: false) },
                onBrightnessEnd: { scheduleMeterHide() },
                onVolumeChanged: { showMeter(.volume, value: $0, autoHide: false) },
                onVolumeEnd: { scheduleMeterHide() },
                onExternalVolumeChanged: { showMeter(.volume, value: $0, autoHide: true) }
            )
            .ignoresSafeAreaIf(isFullscreen)

            // 播放信息面板
            if mpv.showStats, let stats = mpv.stats {
                statsPanel(stats)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, isFullscreen ? 60 : 8)
                    .padding(.leading, isFullscreen ? 14 : 10)
                    .allowsHitTesting(false)
            }

            // 顶部和底部控件独立布局，不参与中央控件的定位。
            controlsChrome
                .foregroundStyle(.white)
                .opacity(visible && !isLocked ? 1 : 0)
                .allowsHitTesting(visible && !isLocked)
                .accessibilityHidden(!visible || isLocked)

            // 中央控件在画面中心独立布局。隐藏控制栏也用同一枚玻璃显示缓冲。
            centerControls
                .foregroundStyle(.white)
                .ignoresSafeAreaIf(isFullscreen)

            // 锁屏状态下只显示解锁胶囊
            if isFullscreen, isLocked, lockBadgeVisible {
                unlockOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            // 顶部：长按倍速提示
            if mpv.isSpeedBoosting {
                speedBoostHUD
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, isFullscreen ? 16 : 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }

            // 居中：拖拽快进 / 快退预览
            if let target = gestureSeekTarget ?? scrub, mpv.duration > 0 {
                seekPreviewHUD(target: target, delta: gestureSeekTarget.map { $0 - gestureSeekStart })
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }

            // 居中：亮度 / 音量调节指示器
            if let meter = meterHUD, gestureSeekTarget == nil, scrub == nil {
                meterOverlay(meter)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .allowsHitTesting(false)
            }

            // 双击播放 / 暂停反馈
            if let pulse = doubleTapPulse, !visible, !hasActiveCenterHUD {
                Image(systemName: pulse.paused ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .playerGlass(prominent: true, in: Circle())
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: visible)
        .animation(.easeOut(duration: 0.16), value: isLocked)
        .animation(.easeOut(duration: 0.16), value: lockBadgeVisible)
        .animation(.easeOut(duration: 0.16), value: mpv.isSpeedBoosting)
        .animation(.easeOut(duration: 0.14), value: meterHUD)
        .onAppear { scheduleHide() }
        .onDisappear {
            hideTask?.cancel()
            meterHideTask?.cancel()
            lockHideTask?.cancel()
            pulseHideTask?.cancel()
            mpv.endSpeedBoost()
            resetSeekPreview()
            isLocked = false
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase != .active {
                resetSeekPreview()
            } else if visible {
                scheduleHide()
            }
        }
        .onChangeCompat(of: mpv.duration > 0) { _, canSeek in
            if !canSeek { resetSeekPreview() }
        }
        .onChangeCompat(of: mpv.isPaused) { _, paused in
            if paused {
                hideTask?.cancel()
                if !isLocked {
                    withAnimation(.easeOut(duration: 0.2)) { visible = true }
                }
            } else {
                scheduleHide()
            }
        }
    }

    // MARK: 遮罩

    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.58), location: 0.0),
                .init(color: .black.opacity(0.14), location: 0.24),
                .init(color: .black.opacity(0.10), location: 0.50),
                .init(color: .black.opacity(0.18), location: 0.75),
                .init(color: .black.opacity(0.68), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: 顶栏（全屏）

    @ViewBuilder
    private var controlsChrome: some View {
        if isFullscreen {
            GeometryReader { proxy in
                // 横屏的刘海一侧安全区可能更大。两边以较大值为准，
                // 保留上下安全区，左右控件都不会贴到屏幕圆角或灵动岛里。
                let insets = proxy.safeAreaInsets
                let side = max(insets.leading, insets.trailing)
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
                .padding(.leading, side - insets.leading)
                .padding(.trailing, side - insets.trailing)
            }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            fullscreenCircleButton("chevron.backward", pointSize: 16, label: "退出全屏", action: exitFullscreen)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)

            Spacer(minLength: 8)

            fullscreenCircleButton("lock.open", pointSize: 15, label: "锁定屏幕", action: lockScreen)
        }
        .padding(.horizontal, Self.fullscreenEdgePadding)
        .padding(.top, 7)
    }

    private func fullscreenCircleButton(
        _ icon: String,
        pointSize: CGFloat,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: pointSize, weight: .semibold))
                .frame(width: Self.fullscreenIconDiameter, height: Self.fullscreenIconDiameter)
                .playerGlass(interactive: true, in: Circle())
                .frame(width: Self.fullscreenIconHitSize, height: Self.fullscreenIconHitSize)
                .contentShape(Rectangle())
        }
        .playerButtonStyle()
        .accessibilityLabel(label)
    }

    private func lockScreen() {
        Haptics.tap()
        hideTask?.cancel()
        resetSeekPreview()
        withAnimation(.easeOut(duration: 0.18)) {
            isLocked = true
            visible = false
            lockBadgeVisible = true
        }
        scheduleLockBadgeHide()
    }

    // MARK: 中央控制

    private var centerControls: some View {
        let shown = visible && !isLocked && !hasActiveCenterHUD
        let buffering = mpv.isBuffering && !hasActiveCenterHUD
        let diameter: CGFloat = isFullscreen ? 56 : 48
        let spacing: CGFloat = isFullscreen ? 54 : 30

        // 相同尺寸的三格，无论快进按钮或缓冲提示显隐，中间都不会偏移。
        return HStack(spacing: spacing) {
            centerCircleButton(
                "gobackward.10",
                iconSize: isFullscreen ? 22 : 18,
                diameter: diameter,
                label: "后退 10 秒"
            ) { mpv.seek(by: -10) }
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)

            ZStack {
                if buffering {
                    ProgressView()
                        .tint(.white)
                        .controlSize(isFullscreen ? .large : .regular)
                        .accessibilityLabel("加载中")
                } else {
                    Button {
                        Haptics.tap()
                        mpv.togglePause()
                        scheduleHide()
                    } label: {
                        centerCircleLabel(
                            mpv.isPaused ? "play.fill" : "pause.fill",
                            iconSize: isFullscreen ? 29 : 24,
                            diameter: diameter
                        )
                    }
                    .playerButtonStyle()
                    .accessibilityLabel(mpv.isPaused ? "播放" : "暂停")
                }
            }
            .frame(width: diameter, height: diameter)
            // 播放和缓冲只切换内层图标，外层玻璃不重建。
            .playerGlass(interactive: true, in: Circle())
            .opacity(shown || buffering ? 1 : 0)
            .allowsHitTesting(shown && !buffering)
            .accessibilityHidden(!shown && !buffering)

            centerCircleButton(
                "goforward.10",
                iconSize: isFullscreen ? 22 : 18,
                diameter: diameter,
                label: "前进 10 秒"
            ) { mpv.seek(by: 10) }
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        }
        .fixedSize()
    }

    private func centerCircleButton(
        _ icon: String,
        iconSize: CGFloat,
        diameter: CGFloat,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
            scheduleHide()
        } label: {
            centerCircleLabel(icon, iconSize: iconSize, diameter: diameter)
        }
        .playerButtonStyle()
        // 与缓冲状态共用 xyydy 对应的玻璃承载层，直接按最终尺寸绘制。
        .playerGlass(interactive: true, in: Circle())
        .accessibilityLabel(label)
    }

    private func centerCircleLabel(_ icon: String, iconSize: CGFloat, diameter: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: iconSize, weight: .semibold))
            .symbolReplaceTransition()
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: isFullscreen ? 8 : 4) {
            // 高系统保留 UIKit 原生液态玻璃滑块，低系统保留自定义缓冲进度条。
            HStack(spacing: 10) {
                Text(Self.time(displayedPosition))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .frame(minWidth: 42, alignment: .leading)

                if #available(iOS 26, *) {
                    MPVNativeProgressSlider(
                        position: displayedPosition,
                        duration: mpv.duration,
                        onScrubChanged: previewScrub,
                        onScrubFinished: finishScrub
                    )
                    .frame(height: 28)
                } else {
                    MPVProgressBar(
                        position: displayedPosition,
                        buffered: mpv.cachedUntil,
                        duration: mpv.duration,
                        isScrubbing: scrub != nil,
                        onScrubChanged: previewScrub,
                        onScrubFinished: finishScrub
                    )
                }

                Text(Self.time(mpv.duration))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(minWidth: 42, alignment: .trailing)
            }

            // 左右各是一组：只调整整行的边缘留白，不单独偏移工具按钮。
            GlassGroup(spacing: isFullscreen ? 10 : 8) {
                HStack(spacing: 0) {
                    if isFullscreen {
                        HStack(spacing: 10) {
                            if #available(iOS 26, *) {
                                BarGlassIconButton(
                                    systemImage: mpv.isPaused ? "play.fill" : "pause.fill",
                                    pointSize: 14,
                                    diameter: 36,
                                    tone: .dark,
                                    accessibilityLabel: mpv.isPaused ? "播放" : "暂停"
                                ) {
                                    Haptics.tap()
                                    mpv.togglePause()
                                    scheduleHide()
                                }
                            } else {
                                Button {
                                    Haptics.tap()
                                    mpv.togglePause()
                                    scheduleHide()
                                } label: {
                                    Image(systemName: mpv.isPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(width: 36, height: 36)
                                        .contentShape(Circle())
                                }
                                .playerButtonStyle()
                                .playerGlass(interactive: true, in: Circle())
                                .accessibilityLabel(mpv.isPaused ? "播放" : "暂停")
                            }

                            if let onNextEpisode {
                                if #available(iOS 26, *) {
                                    BarGlassPillButton(
                                        title: "下一集",
                                        systemImage: "forward.end.fill",
                                        fontSize: 12,
                                        iconSize: 12,
                                        height: 36,
                                        horizontalPadding: 13,
                                        tone: .dark,
                                        accessibilityLabel: "播放下一集"
                                    ) {
                                        Haptics.tap()
                                        onNextEpisode()
                                        scheduleHide()
                                    }
                                } else {
                                    Button {
                                        Haptics.tap()
                                        onNextEpisode()
                                        scheduleHide()
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "forward.end.fill")
                                                .font(.system(size: 12, weight: .semibold))
                                            Text("下一集")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .padding(.horizontal, 13)
                                        .frame(height: 36)
                                        .contentShape(Capsule())
                                    }
                                    .playerButtonStyle()
                                    .playerGlass(interactive: true, in: Capsule())
                                    .accessibilityLabel("播放下一集")
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: isFullscreen ? 10 : 8) {
                        speedMenu
                        optionsMenu

                        if #available(iOS 26, *) {
                            BarGlassIconButton(
                                systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                pointSize: isFullscreen ? 14 : 13,
                                diameter: isFullscreen ? 36 : 32,
                                tone: .dark,
                                accessibilityLabel: isFullscreen ? "退出全屏" : "全屏"
                            ) {
                                if isFullscreen {
                                    exitFullscreen()
                                } else {
                                    toggleFullscreen()
                                }
                            }
                        } else {
                            Button {
                                if isFullscreen {
                                    exitFullscreen()
                                } else {
                                    toggleFullscreen()
                                }
                            } label: {
                                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: isFullscreen ? 14 : 13, weight: .semibold))
                                    .frame(width: isFullscreen ? 36 : 32, height: isFullscreen ? 36 : 32)
                                    .contentShape(Circle())
                            }
                            .playerButtonStyle()
                            .playerGlass(interactive: true, in: Circle())
                            .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, isFullscreen ? Self.fullscreenEdgePadding : 12)
        .padding(.bottom, isFullscreen ? 8 : 6)
    }

    // MARK: 倍速与默认倍速菜单

    @ViewBuilder
    private var speedMenu: some View {
        let isCustomSpeed = abs(mpv.speed - 1.0) >= 0.01
        let chipText = isCustomSpeed ? Self.speedLabel(mpv.speed) : "倍速"

        if #available(iOS 26, *) {
            BarGlassPillMenuButton(
                title: chipText,
                systemImage: "speedometer",
                showsChevron: false,
                fontSize: 12,
                iconSize: isFullscreen ? 12 : 11,
                height: isFullscreen ? 36 : 32,
                horizontalPadding: isFullscreen ? 12 : 10,
                tint: isCustomSpeed ? AppAccent.uiColor(accentHex) : nil,
                tone: .dark,
                monospacedDigits: true,
                accessibilityLabel: "倍速与默认倍速，当前 \(Self.speedLabel(mpv.speed))"
            ) {
                buildSpeedMenuElements()
            }
        } else {
            Menu {
                Section("当前倍速") {
                    ForEach(Self.speeds, id: \.self) { rate in
                        Button {
                            mpv.setSpeed(rate)
                            scheduleHide()
                        } label: {
                            checkLabel(rate == 1 ? "正常（1x）" : Self.speedLabel(rate), abs(mpv.speed - rate) < 0.01)
                        }
                    }
                }

                Section {
                    Menu {
                        ForEach(Self.defaultSpeedOptions, id: \.self) { rate in
                            Button {
                                defaultSpeed = rate
                                mpv.setSpeed(rate)
                                scheduleHide()
                            } label: {
                                checkLabel(rate == 1 ? "正常（1x）" : Self.speedLabel(rate), abs(defaultSpeed - rate) < 0.01)
                            }
                        }
                    } label: {
                        Label("默认倍速 · \(Self.speedLabel(defaultSpeed))", systemImage: "speedometer")
                    }

                    if abs(mpv.speed - defaultSpeed) >= 0.01,
                       Self.defaultSpeedOptions.contains(where: { abs($0 - mpv.speed) < 0.01 }) {
                        Button {
                            defaultSpeed = mpv.speed
                            scheduleHide()
                        } label: {
                            Label("将 \(Self.speedLabel(mpv.speed)) 设为默认倍速", systemImage: "pin")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: isFullscreen ? 12 : 11, weight: .semibold))
                    Text(chipText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(isCustomSpeed ? Color.accentColor : Color.white)
                .padding(.horizontal, isFullscreen ? 12 : 10)
                .frame(height: isFullscreen ? 36 : 32)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .playerGlass(interactive: true, in: Capsule())
            .accessibilityLabel("倍速与默认倍速，当前 \(Self.speedLabel(mpv.speed))")
        }
    }

    private func buildSpeedMenuElements() -> [UIMenuElement] {
        let currentActions = Self.speeds.map { rate in
            UIAction(
                title: rate == 1 ? "正常（1x）" : Self.speedLabel(rate),
                state: abs(mpv.speed - rate) < 0.01 ? .on : .off
            ) { _ in
                mpv.setSpeed(rate)
                scheduleHide()
            }
        }
        let currentSection = UIMenu(title: "当前倍速", options: .displayInline, children: currentActions)

        let defaultSubActions = Self.defaultSpeedOptions.map { rate in
            UIAction(
                title: rate == 1 ? "正常（1x）" : Self.speedLabel(rate),
                state: abs(defaultSpeed - rate) < 0.01 ? .on : .off
            ) { _ in
                defaultSpeed = rate
                mpv.setSpeed(rate)
                scheduleHide()
            }
        }
        var footerItems: [UIMenuElement] = [
            UIMenu(
                title: "默认倍速 · \(Self.speedLabel(defaultSpeed))",
                image: UIImage(systemName: "speedometer"),
                children: defaultSubActions
            )
        ]
        if abs(mpv.speed - defaultSpeed) >= 0.01,
           Self.defaultSpeedOptions.contains(where: { abs($0 - mpv.speed) < 0.01 }) {
            let currentRate = mpv.speed
            footerItems.append(
                UIAction(
                    title: "将 \(Self.speedLabel(currentRate)) 设为默认倍速",
                    image: UIImage(systemName: "pin")
                ) { _ in
                    defaultSpeed = currentRate
                    scheduleHide()
                }
            )
        }
        let footerSection = UIMenu(options: .displayInline, children: footerItems)
        return [currentSection, footerSection]
    }

    // MARK: 音轨 / 字幕 / 信息菜单

    @ViewBuilder
    private var optionsMenu: some View {
        if #available(iOS 26, *) {
            BarGlassIconMenuButton(
                systemImage: "captions.bubble",
                pointSize: isFullscreen ? 14 : 13,
                diameter: isFullscreen ? 36 : 32,
                tone: .dark,
                accessibilityLabel: "音轨、字幕和播放信息"
            ) {
                buildOptionsMenuElements()
            }
        } else {
            Menu {
                if !mpv.audioTracks.isEmpty {
                    Section("音轨") {
                        ForEach(mpv.audioTracks) { track in
                            Button {
                                mpv.selectAudio(track.id)
                                scheduleHide()
                            } label: {
                                checkLabel(track.title, track.selected)
                            }
                        }
                    }
                }
                Section("字幕") {
                    Button {
                        mpv.selectSubtitle(nil)
                        scheduleHide()
                    } label: {
                        checkLabel("关闭字幕", mpv.subtitleOff)
                    }
                    ForEach(mpv.subtitleTracks) { track in
                        Button {
                            mpv.selectSubtitle(track.id)
                            scheduleHide()
                        } label: {
                            checkLabel(track.title, track.selected)
                        }
                    }
                }
                Section {
                    Button {
                        mpv.showStats.toggle()
                        scheduleHide()
                    } label: {
                        checkLabel("播放信息（网速、码率、解码）", mpv.showStats)
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: isFullscreen ? 14 : 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: isFullscreen ? 36 : 32, height: isFullscreen ? 36 : 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .playerGlass(interactive: true, in: Circle())
            .accessibilityLabel("音轨、字幕和播放信息")
        }
    }

    private func buildOptionsMenuElements() -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        if !mpv.audioTracks.isEmpty {
            let audioActions = mpv.audioTracks.map { track in
                UIAction(title: track.title, state: track.selected ? .on : .off) { _ in
                    mpv.selectAudio(track.id)
                    scheduleHide()
                }
            }
            sections.append(UIMenu(title: "音轨", options: .displayInline, children: audioActions))
        }

        var subtitleActions: [UIAction] = [
            UIAction(title: "关闭字幕", state: mpv.subtitleOff ? .on : .off) { _ in
                mpv.selectSubtitle(nil)
                scheduleHide()
            }
        ]
        subtitleActions.append(contentsOf: mpv.subtitleTracks.map { track in
            UIAction(title: track.title, state: track.selected ? .on : .off) { _ in
                mpv.selectSubtitle(track.id)
                scheduleHide()
            }
        })
        sections.append(UIMenu(title: "字幕", options: .displayInline, children: subtitleActions))

        let statsAction = UIAction(
            title: "播放信息（网速、码率、解码）",
            state: mpv.showStats ? .on : .off
        ) { _ in
            mpv.showStats.toggle()
            scheduleHide()
        }
        sections.append(UIMenu(options: .displayInline, children: [statsAction]))
        return sections
    }

    // MARK: 悬浮提示 HUD

    private var speedBoostHUD: some View {
        HStack(spacing: 7) {
            Image(systemName: "forward.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .opacity(boostPulse ? 1 : 0.45)
                .onAppear {
                    boostPulse = false
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                        boostPulse = true
                    }
                }
                .onDisappear { boostPulse = false }
            Text("\(Self.speedLabel(mpv.boostSpeed)) 倍速播放中")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .playerGlass(prominent: true, in: Capsule())
    }

    private func seekPreviewHUD(target: Double, delta: Double?) -> some View {
        let ratio = mpv.duration > 0 ? min(max(target / mpv.duration, 0), 1) : 0
        return VStack(spacing: 8) {
            if let delta {
                HStack(spacing: 6) {
                    Image(systemName: delta >= 0 ? "forward.fill" : "backward.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text(Self.signedDelta(delta))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            HStack(spacing: 4) {
                Text(Self.time(target))
                    .foregroundStyle(.white)
                Text("/")
                    .foregroundStyle(.white.opacity(0.45))
                Text(Self.time(mpv.duration))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .font(.title3.weight(.semibold).monospacedDigit())

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.24))
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .frame(width: 156, height: 3.5)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .playerGlass(prominent: true, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func meterOverlay(_ meter: MeterHUD) -> some View {
        let iconName: String
        switch meter.kind {
        case .brightness:
            iconName = meter.value < 0.33 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if meter.value <= 0.001 {
                iconName = "speaker.slash.fill"
            } else if meter.value < 0.33 {
                iconName = "speaker.wave.1.fill"
            } else if meter.value < 0.66 {
                iconName = "speaker.wave.2.fill"
            } else {
                iconName = "speaker.wave.3.fill"
            }
        }
        let clamped = min(max(meter.value, 0), 1)
        return HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .frame(width: 112, height: 5)

            Text("\(Int((clamped * 100).rounded()))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .playerGlass(prominent: true, in: Capsule())
    }

    private var unlockOverlay: some View {
        Group {
            if #available(iOS 26, *) {
                BarGlassPillButton(
                    title: "点按解锁",
                    systemImage: "lock.fill",
                    fontSize: 12,
                    iconSize: 13,
                    height: 38,
                    horizontalPadding: 14,
                    tone: .dark,
                    accessibilityLabel: "解除屏幕锁定"
                ) {
                    unlockScreen()
                }
            } else {
                Button(action: unlockScreen) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("点按解锁")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .contentShape(Capsule())
                }
                .playerButtonStyle()
                .playerGlass(interactive: true, prominent: true, in: Capsule())
                .accessibilityLabel("解除屏幕锁定")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 18)
    }

    private func unlockScreen() {
        Haptics.tap()
        lockHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            isLocked = false
            lockBadgeVisible = false
            visible = true
        }
        scheduleHide()
    }

    private func statsPanel(_ stats: MPVStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("网速 \(stats.speedText) · 需要 \(stats.neededText)")
            Text("缓冲 \(Int(stats.buffered)) 秒 · 码率 \(stats.bitrateText)")
            Text(stats.decoderText)
            if stats.width > 0 {
                Text("\(stats.codec.uppercased()) \(stats.width)×\(stats.height)\(stats.dropped > 0 ? " · 丢帧 \(stats.dropped)" : "")")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .playerGlass(prominent: true, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func checkLabel(_ title: String, _ selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: 手势回调

    private func exitFullscreen() {
        resetSeekPreview()
        isLocked = false
        mpv.endSpeedBoost()
        toggleFullscreen()
    }

    private func handleSingleTap() {
        if isLocked {
            withAnimation(.easeOut(duration: 0.16)) { lockBadgeVisible.toggle() }
            if lockBadgeVisible { scheduleLockBadgeHide() } else { lockHideTask?.cancel() }
            return
        }
        toggleVisible()
    }

    private func handleDoubleTap() {
        guard !isLocked else { return }
        Haptics.tap()
        let willPause = !mpv.isPaused
        mpv.togglePause()
        if !visible {
            pulseHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.14)) {
                doubleTapPulse = DoubleTapPulse(paused: willPause)
            }
            pulseHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { doubleTapPulse = nil }
            }
        } else {
            scheduleHide()
        }
    }

    private func handleBoostStart() {
        guard !isLocked, !mpv.isPaused else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        mpv.beginSpeedBoost()
    }

    private func handleBoostEnd() {
        mpv.endSpeedBoost()
    }

    private func previewScrub(_ target: Double) {
        guard visible, !isLocked else { return }
        hideTask?.cancel()
        scrub = target
    }

    private func finishScrub(_ target: Double?) {
        scrub = nil
        if let target, mpv.duration > 0, visible, !isLocked,
           abs(target - mpv.position) > 0.01 {
            mpv.seek(to: target)
        }
        if visible { scheduleHide() }
    }

    private func resetSeekPreview() {
        scrub = nil
        gestureSeekTarget = nil
    }

    private func handleGestureSeekBegin() {
        hideTask?.cancel()
        gestureSeekStart = mpv.position
        gestureSeekTarget = mpv.position
    }

    private func handleGestureSeekUpdate(_ fraction: Double) {
        guard gestureSeekTarget != nil, mpv.duration > 0 else { return }
        // 滑满屏幕宽度的跨度按片长自适应（60 秒 ~ 180 秒），兼顾短片与长电影的精度
        let span = min(max(mpv.duration * 0.2, 60), 180)
        let maxPos = max(mpv.duration - 1, 0)
        gestureSeekTarget = min(max(gestureSeekStart + fraction * span, 0), maxPos)
    }

    private func handleGestureSeekEnd(_ commit: Bool) {
        if commit, let target = gestureSeekTarget {
            mpv.seek(to: target)
        }
        gestureSeekTarget = nil
        if visible { scheduleHide() }
    }

    private func showMeter(_ kind: MeterHUD.Kind, value: Double, autoHide: Bool) {
        meterHideTask?.cancel()
        meterHUD = MeterHUD(kind: kind, value: min(max(value, 0), 1))
        if autoHide { scheduleMeterHide() }
    }

    private func scheduleMeterHide() {
        meterHideTask?.cancel()
        meterHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { meterHUD = nil }
        }
    }

    private func scheduleLockBadgeHide() {
        lockHideTask?.cancel()
        lockHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { lockBadgeVisible = false }
        }
    }

    private func toggleVisible() {
        withAnimation(.easeOut(duration: 0.2)) { visible.toggle() }
        if visible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !mpv.isPaused, scrub == nil, gestureSeekTarget == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { visible = false }
        }
    }

    // MARK: 格式化

    static func speedLabel(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.01 {
            return "\(Int(rate.rounded()))x"
        }
        return String(format: "%gx", rate)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private static func signedDelta(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : "-"
        return "\(sign)\(time(abs(delta)))"
    }
}

private struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.91 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func ignoresSafeAreaIf(_ condition: Bool) -> some View {
        if condition {
            ignoresSafeArea()
        } else {
            self
        }
    }

    /// 播放器悬浮控件玻璃材质：
    /// - iOS 26+ 用与底栏同源的实体液态玻璃（深色通透起点 + 独立暗色滚动边，跟随系统「透明 / 色调」设置）
    /// - iOS 15–18 用深色磨砂材质 + 细微高光描边
    @ViewBuilder
    func playerGlass<S: InsettableShape>(interactive: Bool = false, prominent: Bool = false, in shape: S) -> some View {
        if #available(iOS 26, *) {
            background {
                AstraBarMatchedGlassBackground(
                    interactive: interactive,
                    corner: Self.playerGlassCorner(for: shape),
                    tone: .dark
                )
            }
            .contentShape(shape)
        } else {
            background {
                shape
                    .fill(.black.opacity(prominent ? 0.64 : 0.34))
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(.white.opacity(prominent ? 0.14 : 0.18), lineWidth: 0.5))
                    .shadow(color: prominent ? .black.opacity(0.30) : .clear, radius: prominent ? 12 : 0, y: prominent ? 4 : 0)
            }
        }
    }

    private static func playerGlassCorner<S: Shape>(for shape: S) -> AstraGlassCorner {
        if let rounded = shape as? RoundedRectangle {
            return .roundedRect(rounded.cornerSize.width)
        }
        if shape is Circle {
            return .circle
        }
        return .capsule
    }

    /// iOS 26 液态玻璃自带交互缩放与光效；低系统补充轻按缩放反馈
    @ViewBuilder
    func playerButtonStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.plain)
        } else {
            buttonStyle(PlayerPressStyle())
        }
    }
}

// MARK: - 原生液态玻璃进度条（iOS 26+）

@available(iOS 26, *)
private struct MPVNativeProgressSlider: UIViewRepresentable {
    let position: Double
    let duration: Double
    let onScrubChanged: (Double) -> Void
    let onScrubFinished: (Double?) -> Void

    func makeUIView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider(frame: .zero)
        slider.minimumTrackTintColor = .white
        slider.overrideUserInterfaceStyle = .dark
        slider.accessibilityLabel = "播放进度"
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.addTarget(slider, action: #selector(TrackingSlider.valueDidChange), for: .valueChanged)
        return slider
    }

    func updateUIView(_ slider: TrackingSlider, context: Context) {
        slider.onScrubChanged = onScrubChanged
        slider.onScrubFinished = onScrubFinished
        slider.apply(position: position, duration: duration)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TrackingSlider, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: 28)
    }

    final class TrackingSlider: UISlider {
        var onScrubChanged: ((Double) -> Void)?
        var onScrubFinished: ((Double?) -> Void)?
        private var reportsTouch = false
        private var duration: Double = 0

        func apply(position: Double, duration: Double) {
            self.duration = duration.isFinite ? max(duration, 0) : 0
            let enabled = self.duration > 0
            if isEnabled != enabled { isEnabled = enabled }
            guard !reportsTouch, !isTracking else { return }
            let ratio = self.duration > 0 && position.isFinite ? position / self.duration : 0
            let clamped = Float(min(max(ratio, 0), 1))
            if value != clamped { setValue(clamped, animated: false) }
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard duration > 0 else { return false }
            reportsTouch = true
            let tracking = super.beginTracking(touch, with: event)
            if tracking {
                onScrubChanged?(seconds)
            } else {
                reportsTouch = false
                onScrubFinished?(nil)
            }
            return tracking
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let tracking = super.continueTracking(touch, with: event)
            if !tracking, reportsTouch {
                reportsTouch = false
                onScrubFinished?(nil)
            }
            return tracking
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            let wasReporting = reportsTouch
            super.endTracking(touch, with: event)
            reportsTouch = false
            if wasReporting { onScrubFinished?(touch == nil ? nil : seconds) }
        }

        override func cancelTracking(with event: UIEvent?) {
            let wasReporting = reportsTouch
            super.cancelTracking(with: event)
            reportsTouch = false
            if wasReporting { onScrubFinished?(nil) }
        }

        @objc func valueDidChange() {
            guard duration > 0 else { return }
            if reportsTouch {
                onScrubChanged?(seconds)
            } else {
                // VoiceOver、键盘等不走触摸追踪。直接跳转，不开启预览浮层。
                onScrubFinished?(seconds)
            }
        }

        private var seconds: Double { Double(value) * duration }
    }
}

// MARK: - 自定义进度条（iOS 26 以下使用）

/// iOS 26 以下替代系统默认 Slider，支持显示缓冲进度与拖拽放大
private struct MPVProgressBar: View {
    let position: Double
    let buffered: Double
    let duration: Double
    let isScrubbing: Bool
    let onScrubChanged: (Double) -> Void
    let onScrubFinished: (Double?) -> Void
    @GestureState private var touchActive = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
            let buffer = duration > 0 ? min(max(buffered / duration, 0), 1) : 0
            let trackHeight: CGFloat = isScrubbing ? 6 : 3.5
            let thumbSize: CGFloat = isScrubbing ? 15 : 11
            let thumbX = width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.24))
                    .frame(height: trackHeight)

                if buffer > 0 {
                    Capsule()
                        .fill(.white.opacity(0.42))
                        .frame(width: width * buffer, height: trackHeight)
                }

                Capsule()
                    .fill(.white)
                    .frame(width: max(thumbX, 0), height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: min(max(thumbX - thumbSize / 2, 0), max(width - thumbSize, 0)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touchActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let ratio = min(max(value.location.x / width, 0), 1)
                        onScrubChanged(Double(ratio) * duration)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let ratio = min(max(value.location.x / width, 0), 1)
                        onScrubFinished(Double(ratio) * duration)
                    }
            )
            .animation(.easeOut(duration: 0.14), value: isScrubbing)
        }
        .frame(height: 28)
        .onChangeCompat(of: touchActive) { _, active in
            // SwiftUI 拖拽取消时不一定有 onEnded，但 GestureState 一定会复位。
            if !active { onScrubFinished(nil) }
        }
    }
}

// MARK: - 手势层（单击 / 双击 / 长按倍速 / 水平快进退 / 左亮度右音量）

private struct MPVGestureOverlay: UIViewRepresentable {
    let isFullscreen: Bool
    let isLocked: Bool
    let canSeek: () -> Bool
    let canBoost: () -> Bool
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onBoostStart: () -> Void
    let onBoostEnd: () -> Void
    let onSeekBegin: () -> Void
    let onSeekUpdate: (Double) -> Void
    let onSeekEnd: (Bool) -> Void
    let onBrightnessChanged: (Double) -> Void
    let onBrightnessEnd: () -> Void
    let onVolumeChanged: (Double) -> Void
    let onVolumeEnd: () -> Void
    let onExternalVolumeChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncVolumeBinding(on: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private enum PanMode { case undecided, seek, brightness, volume }

        var parent: MPVGestureOverlay
        private weak var hostView: UIView?
        private var singleTap: UITapGestureRecognizer?
        private var doubleTap: UITapGestureRecognizer?
        private var longPress: UILongPressGestureRecognizer?
        private var pan: UIPanGestureRecognizer?

        private var panMode: PanMode = .undecided
        private var panStartPoint: CGPoint = .zero
        private var startBrightness: CGFloat = 0.5
        private var startVolume: Float = 0.5
        private var lastProgrammaticVolumeAt = Date.distantPast
        private var volumeObservation: NSKeyValueObservation?
        private var volumeDetachTask: Task<Void, Never>?

        private lazy var volumeView: MPVolumeView = {
            let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 40, height: 40))
            view.alpha = 0.01
            view.isUserInteractionEnabled = false
            return view
        }()

        private var volumeSlider: UISlider? {
            volumeView.subviews.compactMap { $0 as? UISlider }.first
        }

        init(parent: MPVGestureOverlay) {
            self.parent = parent
        }

        func install(on view: UIView) {
            hostView = view

            let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
            single.numberOfTapsRequired = 1
            single.delegate = self

            let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            double.numberOfTapsRequired = 2
            double.delegate = self
            single.require(toFail: double)

            let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            press.minimumPressDuration = 0.35
            press.allowableMovement = 14
            press.delegate = self

            let drag = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            drag.maximumNumberOfTouches = 1
            drag.delegate = self

            view.addGestureRecognizer(single)
            view.addGestureRecognizer(double)
            view.addGestureRecognizer(press)
            view.addGestureRecognizer(drag)

            singleTap = single
            doubleTap = double
            longPress = press
            pan = drag

            syncVolumeBinding(on: view)
        }

        func syncVolumeBinding(on view: UIView) {
            if parent.isFullscreen {
                volumeDetachTask?.cancel()
                if volumeView.superview !== view {
                    view.addSubview(volumeView)
                }
                if volumeObservation == nil {
                    let session = AVAudioSession.sharedInstance()
                    volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                        guard let value = change.newValue else { return }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard self.panMode != .volume,
                                  Date().timeIntervalSince(self.lastProgrammaticVolumeAt) > 0.35 else { return }
                            self.parent.onExternalVolumeChanged(Double(value))
                        }
                    }
                }
            } else {
                volumeObservation?.invalidate()
                volumeObservation = nil
                if panMode != .volume, volumeDetachTask == nil {
                    volumeView.removeFromSuperview()
                }
            }
        }

        func teardown() {
            volumeDetachTask?.cancel()
            volumeDetachTask = nil
            volumeObservation?.invalidate()
            volumeObservation = nil
            volumeView.removeFromSuperview()
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === singleTap { return true }
            if parent.isLocked { return false }
            if gestureRecognizer === doubleTap { return true }
            guard let view = gestureRecognizer.view else { return false }
            let location = gestureRecognizer.location(in: view)
            guard isInsideSafeArea(location, in: view.bounds) else { return false }
            if gestureRecognizer === longPress { return parent.canBoost() }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        private func isInsideSafeArea(_ point: CGPoint, in bounds: CGRect) -> Bool {
            let verticalMargin: CGFloat = parent.isFullscreen ? 36 : 10
            let horizontalMargin: CGFloat = parent.isFullscreen ? 24 : 14
            return point.y >= verticalMargin
                && point.y <= bounds.height - verticalMargin
                && point.x >= horizontalMargin
                && point.x <= bounds.width - horizontalMargin
        }

        // MARK: 手势动作

        @objc private func handleSingleTap() {
            parent.onSingleTap()
        }

        @objc private func handleDoubleTap() {
            parent.onDoubleTap()
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                parent.onBoostStart()
            case .ended, .cancelled, .failed:
                parent.onBoostEnd()
            default:
                break
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                panStartPoint = recognizer.location(in: view)
                panMode = .undecided

            case .changed:
                let translation = recognizer.translation(in: view)
                if panMode == .undecided {
                    guard abs(translation.x) > 10 || abs(translation.y) > 10 else { return }
                    if abs(translation.x) >= abs(translation.y) {
                        guard parent.canSeek() else {
                            recognizer.isEnabled = false
                            recognizer.isEnabled = true
                            return
                        }
                        panMode = .seek
                        parent.onSeekBegin()
                    } else if panStartPoint.x < view.bounds.width * 0.5 {
                        panMode = .brightness
                        startBrightness = view.window?.windowScene?.screen.brightness ?? 0.5
                        parent.onBrightnessChanged(Double(startBrightness))
                    } else {
                        panMode = .volume
                        volumeDetachTask?.cancel()
                        if volumeView.superview !== view {
                            view.addSubview(volumeView)
                            volumeView.layoutIfNeeded()
                        }
                        startVolume = AVAudioSession.sharedInstance().outputVolume
                        parent.onVolumeChanged(Double(startVolume))
                    }
                }

                switch panMode {
                case .undecided:
                    break
                case .seek:
                    let width = max(view.bounds.width, 200)
                    parent.onSeekUpdate(Double(translation.x / width))
                case .brightness:
                    let span = max(view.bounds.height * 0.65, 160)
                    let next = min(max(startBrightness - translation.y / span, 0), 1)
                    view.window?.windowScene?.screen.brightness = next
                    parent.onBrightnessChanged(Double(next))
                case .volume:
                    let span = max(view.bounds.height * 0.65, 160)
                    let next = Float(min(max(CGFloat(startVolume) - translation.y / span, 0), 1))
                    setSystemVolume(next)
                    parent.onVolumeChanged(Double(next))
                }

            case .ended:
                finishPan(commitSeek: true)

            case .cancelled, .failed:
                finishPan(commitSeek: false)

            default:
                break
            }
        }

        private func finishPan(commitSeek: Bool) {
            let mode = panMode
            panMode = .undecided
            switch mode {
            case .undecided:
                break
            case .seek:
                parent.onSeekEnd(commitSeek)
            case .brightness:
                parent.onBrightnessEnd()
            case .volume:
                parent.onVolumeEnd()
                if !parent.isFullscreen {
                    volumeDetachTask?.cancel()
                    volumeDetachTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        guard let self, !Task.isCancelled, !self.parent.isFullscreen, self.panMode != .volume else { return }
                        self.volumeView.removeFromSuperview()
                        self.volumeDetachTask = nil
                    }
                }
            }
        }

        private func setSystemVolume(_ value: Float) {
            lastProgrammaticVolumeAt = Date()
            volumeSlider?.setValue(value, animated: false)
        }
    }
}

// MARK: - 全屏容器与屏幕方向

struct MPVFullscreenPlayer: View {
    @ObservedObject var model: PlayerModel
    @AppStorage(AppAccent.key) private var accentHex = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoHost(surface: model.mpv.surface, claim: model.isMPVFullscreen)
                .ignoresSafeArea()
            MPVControls(
                mpv: model.mpv,
                title: model.currentEpisode.map { "\(model.request.title) · \($0.name)" } ?? model.request.title,
                isFullscreen: true,
                onNextEpisode: model.hasNextEpisode ? { model.playNext() } : nil
            ) {
                model.setMPVFullscreen(false)
            }
        }
        .tint(AppAccent.color(accentHex))
        .accentColor(AppAccent.color(accentHex))
        .statusBarHidden()
        .homeIndicatorHiddenCompat()
        .preferredColorScheme(.dark)
    }
}

/// 独立的 UIKit 全屏承载控制器：明确声明支持的方向、状态栏和底部指示条隐藏，
/// 避免 SwiftUI fullScreenCover 与 requestGeometryUpdate 并发转场导致方向错位
private final class MPVFullscreenHostingController<Content: View>: UIHostingController<Content> {
    var allowedOrientations: UIInterfaceOrientationMask = .portrait
    var onUnexpectedDismiss: (() -> Void)?
    private var sizeTransition: Int?
    private var transitionGeneration = 0

    var isChangingSize: Bool { sizeTransition != nil }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? allowedOrientations : .all
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        if UIDevice.current.userInterfaceIdiom == .phone {
            if allowedOrientations == .portrait { return .portrait }
            if allowedOrientations == .landscape {
                let current = presentingViewController?.viewIfLoaded?.window?.windowScene?.interfaceOrientation
                if let current, current.isLandscape { return current }
                return ScreenOrientation.preferredLandscapeOrientation
            }
        }
        return super.preferredInterfaceOrientationForPresentation
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        transitionGeneration += 1
        let generation = transitionGeneration
        sizeTransition = generation
        if !coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
            guard let self, self.sizeTransition == generation else { return }
            self.sizeTransition = nil
        }) {
            sizeTransition = nil
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            onUnexpectedDismiss?()
        }
    }
}

/// 先让全屏接住同一个视频画面，再由 UIKit 旋转当前可见的控制器。
/// 退出时全屏继续遮住底下的导航栏，直到场景和视频布局均已回到竖屏。
@MainActor
final class MPVFullscreenManager {
    static let shared = MPVFullscreenManager()

    private weak var presented: MPVFullscreenHostingController<MPVFullscreenPlayer>?
    private weak var ownerModel: PlayerModel?
    private var isTransitioning = false
    private var dismissAfterPresentation = false
    private var portraitExitTask: Task<Void, Never>?

    private init() {}

    func present(model: PlayerModel) {
        if presented != nil, ownerModel === model { return }
        if presented != nil { dismissImmediate() }
        guard let presenter = Self.topPresenter() else {
            Diag.log("全屏", "找不到可弹出的顶层控制器")
            model.finishMPVFullscreenExit()
            return
        }
        if let existing = presenter.presentedViewController, existing.isBeingDismissed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak model] in
                guard let self, let model, model.isMPVFullscreen else { return }
                self.present(model: model)
            }
            return
        }

        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let wantsLandscape = isPhone && model.mpv.videoAspect >= 1
        let mode: ScreenOrientation.Mode = wantsLandscape ? .landscape : .portrait
        let initialScene = presenter.viewIfLoaded?.window?.windowScene
        let startsLandscape = initialScene?.interfaceOrientation.isLandscape == true
        let initialMode: ScreenOrientation.Mode = isPhone && startsLandscape ? .landscape : .portrait
        let rotatesAfterPresentation = isPhone && startsLandscape != wantsLandscape
        let controller = MPVFullscreenHostingController(rootView: MPVFullscreenPlayer(model: model))
        controller.allowedOrientations = initialMode == .landscape ? .landscape : .portrait
        controller.modalPresentationStyle = .fullScreen
        controller.modalTransitionStyle = .crossDissolve
        controller.modalPresentationCapturesStatusBarAppearance = true
        controller.overrideUserInterfaceStyle = .dark
        controller.view.backgroundColor = .black
        controller.onUnexpectedDismiss = { [weak self, weak controller, weak model] in
            guard let self, let controller, self.presented === controller else { return }
            self.clearTransition()
            model?.finishMPVFullscreenExit()
            ScreenOrientation.set(.portrait)
        }

        presented = controller
        ownerModel = model
        isTransitioning = true
        ScreenOrientation.prepare(initialMode)
        presenter.present(controller, animated: !rotatesAfterPresentation) { [weak self, weak model] in
            guard let self, self.presented === controller else { return }
            guard controller.presentingViewController != nil else {
                self.clearTransition()
                model?.finishMPVFullscreenExit()
                ScreenOrientation.set(.portrait)
                return
            }
            // 避免屏幕旋转被合并进无动画的 present 事务。
            DispatchQueue.main.async { [weak self, weak controller, weak model] in
                guard let self, let controller, self.presented === controller else { return }
                self.isTransitioning = false
                if self.dismissAfterPresentation {
                    self.dismissAfterPresentation = false
                    if let model { self.dismiss(model: model) }
                    return
                }
                controller.allowedOrientations = wantsLandscape ? .landscape : .portrait
                ScreenOrientation.set(mode, in: controller.view.window?.windowScene)
            }
        }
    }

    func dismiss(model: PlayerModel) {
        guard ownerModel === model || ownerModel == nil else {
            model.finishMPVFullscreenExit()
            return
        }
        guard let controller = presented else {
            ownerModel = nil
            model.finishMPVFullscreenExit()
            ScreenOrientation.set(.portrait)
            return
        }
        if isTransitioning {
            if portraitExitTask == nil, !controller.isBeingDismissed {
                dismissAfterPresentation = true
            }
            return
        }

        isTransitioning = true
        let scene = controller.view.window?.windowScene
        let restoresPortrait = UIDevice.current.userInterfaceIdiom == .phone
            && (ScreenOrientation.mode == .landscape
                || controller.isChangingSize
                || (scene.map { !ScreenOrientation.isPortraitSettled(in: $0) } ?? false))
        controller.allowedOrientations = .portrait
        ScreenOrientation.set(.portrait, in: scene, verifyPortrait: false, forcePortraitGeometry: restoresPortrait)

        guard restoresPortrait, let scene else {
            finishDismiss(controller, model: model, animated: true)
            return
        }

        portraitExitTask = Task { @MainActor [weak self, weak controller, weak model] in
            // 不能用写入方向掩码的时刻当作动画完成。等待 UIKit 转场结束，
            // 再确认连续两帧是竖屏；系统拒绝旋转时仍允许有界退出。
            var settledFrames = 0
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled, let self, let controller,
                      self.presented === controller else { return }
                let bounds = controller.view.bounds
                if !controller.isChangingSize, ScreenOrientation.isPortraitSettled(in: scene),
                   bounds.height >= bounds.width, !bounds.isEmpty {
                    settledFrames += 1
                    if settledFrames >= 2 { break }
                } else {
                    settledFrames = 0
                }
            }
            guard !Task.isCancelled, let self, let controller,
                  self.presented === controller else { return }
            if settledFrames < 2 {
                Diag.log("屏幕方向", "等待全屏竖屏布局超时，退出后复查")
            }
            self.finishDismiss(controller, model: model, animated: settledFrames < 2)
        }
    }

    private func finishDismiss(
        _ controller: MPVFullscreenHostingController<MPVFullscreenPlayer>,
        model: PlayerModel?,
        animated: Bool
    ) {
        controller.onUnexpectedDismiss = nil
        let scene = controller.view.window?.windowScene
        let finish: () -> Void = { [weak self, weak model] in
            guard let self, self.presented === controller else { return }
            self.clearTransition()
            model?.finishMPVFullscreenExit()
            ScreenOrientation.set(.portrait, in: scene)
        }
        if let presenting = controller.presentingViewController {
            presenting.dismiss(animated: animated, completion: finish)
        } else {
            finish()
        }
    }

    private func clearTransition() {
        portraitExitTask?.cancel()
        portraitExitTask = nil
        presented = nil
        ownerModel = nil
        isTransitioning = false
        dismissAfterPresentation = false
    }

    private func dismissImmediate() {
        guard let controller = presented else { return }
        let previous = ownerModel
        let scene = controller.view.window?.windowScene
        clearTransition()
        controller.onUnexpectedDismiss = nil
        controller.allowedOrientations = .portrait
        ScreenOrientation.prepare(.portrait)
        controller.presentingViewController?.dismiss(animated: false)
        previous?.finishMPVFullscreenExit()
        ScreenOrientation.set(.portrait, in: scene)
    }

    private static func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}

/// 屏幕方向管理（配合 AppDelegate.supportedInterfaceOrientationsFor）：
/// 正常页面在 iPhone 上锁竖屏，mpv 横屏全屏锁横屏，退出全屏后切回竖屏
@MainActor
enum ScreenOrientation {
    enum Mode: Equatable {
        case portrait
        case landscape
    }

    private(set) static var mode: Mode = .portrait
    private static var verifyTask: Task<Void, Never>?

    static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        switch mode {
        case .portrait:
            return .portrait
        case .landscape:
            return .landscape
        }
    }

    /// 仅更新允许的方向掩码（在 present / dismiss 前调用，避免与转场冲突）
    static func prepare(_ newMode: Mode) {
        mode = newMode
        verifyTask?.cancel()
        verifyTask = nil
    }

    /// 更新允许的方向并通知系统旋转到位
    static func set(
        _ newMode: Mode,
        in scene: UIWindowScene? = nil,
        verifyPortrait: Bool = true,
        forcePortraitGeometry: Bool = false
    ) {
        prepare(newMode)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard let scene = scene ?? activeScene else { return }

        notifyAllViewControllers(in: scene)

        switch newMode {
        case .landscape:
            if !scene.interfaceOrientation.isLandscape {
                let mask: UIInterfaceOrientationMask = preferredLandscapeOrientation == .landscapeLeft
                    ? .landscapeLeft : .landscapeRight
                applyGeometry(in: scene, mask: mask)
            }
        case .portrait:
            if forcePortraitGeometry || !isPortraitSettled(in: scene) {
                applyGeometry(in: scene, mask: .portrait)
                if verifyPortrait { schedulePortraitVerification(in: scene) }
            }
            refreshSystemBars(in: scene)
        }
    }

    static var preferredLandscapeOrientation: UIInterfaceOrientation {
        UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
    }

    static func isPortraitSettled(in scene: UIWindowScene) -> Bool {
        guard !scene.interfaceOrientation.isLandscape else { return false }
        guard let window = scene.windows.first(where: \.isKeyWindow)
            ?? scene.windows.first(where: { $0.rootViewController != nil }) else {
            return scene.interfaceOrientation.isPortrait
        }
        return !window.bounds.isEmpty && window.bounds.height >= window.bounds.width
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func notifyAllViewControllers(in scene: UIWindowScene) {
        guard #available(iOS 16, *) else { return }
        for window in scene.windows {
            notifyTree(window.rootViewController)
        }
    }

    @available(iOS 16, *)
    private static func notifyTree(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in controller.children {
            notifyTree(child)
        }
        if let presented = controller.presentedViewController {
            notifyTree(presented)
        }
    }

    private static func refreshSystemBars(in scene: UIWindowScene) {
        for window in scene.windows {
            window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            window.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    private static func applyGeometry(in scene: UIWindowScene, mask: UIInterfaceOrientationMask) {
        if #available(iOS 16, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                Diag.log("屏幕方向", "切换方向失败（\(mask.rawValue)）：\(error.localizedDescription)")
            }
        } else {
            let orientation: UIInterfaceOrientation
            if mask == .landscapeLeft {
                orientation = .landscapeLeft
            } else if mask == .landscapeRight || mask == .landscape {
                orientation = .landscapeRight
            } else {
                orientation = .portrait
            }
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    /// 退出全屏后复查窗口尺寸与场景方向，避免转场尚未落地导致 UI 停在横屏
    private static func schedulePortraitVerification(in scene: UIWindowScene) {
        verifyTask = Task { @MainActor [weak scene] in
            for delay in [150_000_000 as UInt64, 420_000_000 as UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, mode == .portrait, let scene else { return }
                if !isPortraitSettled(in: scene) {
                    Diag.log("屏幕方向", "退出全屏后窗口仍为横屏，再次请求切回竖屏")
                    notifyAllViewControllers(in: scene)
                    applyGeometry(in: scene, mask: .portrait)
                    refreshSystemBars(in: scene)
                    for window in scene.windows {
                        window.rootViewController?.view.setNeedsLayout()
                    }
                } else {
                    return
                }
            }
        }
    }
}
