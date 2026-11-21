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

    @AppStorage(AppSettings.defaultPlaybackSpeedKey) private var defaultSpeed: Double = 1.0

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

            // 缓冲指示器
            if mpv.isBuffering, !hasActiveCenterHUD {
                ZStack {
                    if !visible || isLocked {
                        Circle()
                            .fill(.black.opacity(0.42))
                            .background(.ultraThinMaterial, in: Circle())
                            .frame(width: isFullscreen ? 64 : 52, height: isFullscreen ? 64 : 52)
                    }
                    ProgressView()
                        .tint(.white)
                        .controlSize(isFullscreen ? .large : .regular)
                }
                .allowsHitTesting(false)
            }

            // 播放信息面板
            if mpv.showStats, let stats = mpv.stats {
                statsPanel(stats)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, isFullscreen ? 58 : 8)
                    .padding(.leading, isFullscreen ? 14 : 10)
                    .allowsHitTesting(false)
            }

            // 主控制栏（保持在安全区内；隐藏时仅透明不移除，避免打开菜单时被收起）
            VStack(spacing: 0) {
                if isFullscreen { topBar }
                Spacer(minLength: 0)
                centerButtons
                    .opacity(hasActiveCenterHUD ? 0 : 1)
                Spacer(minLength: 0)
                bottomBar
            }
            .foregroundStyle(.white)
            .opacity(visible && !isLocked ? 1 : 0)
            .allowsHitTesting(visible && !isLocked)

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
                Circle()
                    .fill(.black.opacity(0.45))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: pulse.paused ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }
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
            isLocked = false
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
                .init(color: .black.opacity(0.64), location: 0.0),
                .init(color: .black.opacity(0.16), location: 0.24),
                .init(color: .black.opacity(0.14), location: 0.50),
                .init(color: .black.opacity(0.20), location: 0.75),
                .init(color: .black.opacity(0.76), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: 顶栏（全屏）

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: exitFullscreen) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(frostedCircle)
                    .contentShape(Circle())
            }
            .buttonStyle(PlayerPressStyle())
            .accessibilityLabel("退出全屏")

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)

            Spacer(minLength: 8)

            Button {
                Haptics.tap()
                hideTask?.cancel()
                withAnimation(.easeOut(duration: 0.18)) {
                    isLocked = true
                    visible = false
                    lockBadgeVisible = true
                }
                scheduleLockBadgeHide()
            } label: {
                Image(systemName: "lock.open")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(frostedCircle)
                    .contentShape(Circle())
            }
            .buttonStyle(PlayerPressStyle())
            .accessibilityLabel("锁定屏幕")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: 中央控制

    private var centerButtons: some View {
        HStack(spacing: isFullscreen ? 54 : 36) {
            centerCircleButton(
                "gobackward.10",
                iconSize: isFullscreen ? 22 : 18,
                diameter: isFullscreen ? 50 : 44,
                label: "后退 10 秒"
            ) {
                mpv.seek(by: -10)
            }

            if mpv.isBuffering, scrub == nil, gestureSeekTarget == nil {
                Color.clear.frame(width: isFullscreen ? 66 : 56, height: isFullscreen ? 66 : 56)
            } else {
                centerCircleButton(
                    mpv.isPaused ? "play.fill" : "pause.fill",
                    iconSize: isFullscreen ? 29 : 24,
                    diameter: isFullscreen ? 66 : 56,
                    label: mpv.isPaused ? "播放" : "暂停"
                ) {
                    mpv.togglePause()
                }
            }

            centerCircleButton(
                "goforward.10",
                iconSize: isFullscreen ? 22 : 18,
                diameter: isFullscreen ? 50 : 44,
                label: "前进 10 秒"
            ) {
                mpv.seek(by: 10)
            }
        }
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
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .symbolReplaceTransition()
                .frame(width: diameter, height: diameter)
                .background(frostedCircle)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(label)
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: isFullscreen ? 8 : 3) {
            // 进度条行
            HStack(spacing: 10) {
                Text(Self.time(displayedPosition))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .frame(minWidth: 42, alignment: .leading)

                MPVProgressBar(
                    position: displayedPosition,
                    buffered: mpv.cachedUntil,
                    duration: mpv.duration,
                    isScrubbing: scrub != nil,
                    onScrubChanged: { target in
                        hideTask?.cancel()
                        scrub = target
                    },
                    onScrubEnded: { target in
                        mpv.seek(to: target)
                        scrub = nil
                        scheduleHide()
                    }
                )

                Text(Self.time(mpv.duration))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(minWidth: 42, alignment: .trailing)
            }

            // 工具按钮行
            HStack(spacing: isFullscreen ? 10 : 8) {
                if isFullscreen {
                    Button {
                        Haptics.tap()
                        mpv.togglePause()
                        scheduleHide()
                    } label: {
                        Image(systemName: mpv.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(frostedCircle)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PlayerPressStyle())
                    .accessibilityLabel(mpv.isPaused ? "播放" : "暂停")

                    if let onNextEpisode {
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
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(frostedCapsule)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PlayerPressStyle())
                        .accessibilityLabel("播放下一集")
                    }
                }

                Spacer(minLength: 0)

                speedMenu
                optionsMenu

                Button {
                    if isFullscreen {
                        exitFullscreen()
                    } else {
                        toggleFullscreen()
                    }
                } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: isFullscreen ? 14 : 13, weight: .semibold))
                        .frame(width: isFullscreen ? 34 : 30, height: isFullscreen ? 34 : 30)
                        .background(frostedCircle)
                        .contentShape(Circle())
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
            }
        }
        .padding(.horizontal, isFullscreen ? 14 : 12)
        .padding(.bottom, isFullscreen ? 8 : 6)
    }

    // MARK: 倍速与默认倍速菜单

    private var speedMenu: some View {
        let isCustomSpeed = abs(mpv.speed - 1.0) >= 0.01
        let chipText = isCustomSpeed ? Self.speedLabel(mpv.speed) : "倍速"

        return Menu {
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
            .padding(.horizontal, isFullscreen ? 11 : 9)
            .frame(height: isFullscreen ? 34 : 30)
            .background(frostedCapsule)
            .contentShape(Capsule())
        }
        .accessibilityLabel("倍速与默认倍速，当前 \(Self.speedLabel(mpv.speed))")
    }

    // MARK: 音轨 / 字幕 / 信息菜单

    private var optionsMenu: some View {
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
                .frame(width: isFullscreen ? 34 : 30, height: isFullscreen ? 34 : 30)
                .background(frostedCircle)
                .contentShape(Circle())
        }
        .accessibilityLabel("音轨、字幕和播放信息")
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
        .background(hudPillBackground)
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.64))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
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
        .background(hudPillBackground)
    }

    private var unlockOverlay: some View {
        Button {
            Haptics.tap()
            lockHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.18)) {
                isLocked = false
                lockBadgeVisible = false
                visible = true
            }
            scheduleHide()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("点按解锁")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(hudPillBackground)
            .contentShape(Capsule())
        }
        .buttonStyle(PlayerPressStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 18)
        .accessibilityLabel("解除屏幕锁定")
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.60))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                )
        )
    }

    // MARK: 视觉样式

    private var frostedCircle: some View {
        Circle()
            .fill(.black.opacity(0.34))
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
    }

    private var frostedCapsule: some View {
        Capsule()
            .fill(.black.opacity(0.34))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
    }

    private var hudPillBackground: some View {
        Capsule()
            .fill(.black.opacity(0.64))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
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

    private func handleGestureSeekBegin() {
        hideTask?.cancel()
        gestureSeekStart = mpv.position
        gestureSeekTarget = mpv.position
    }

    private func handleGestureSeekUpdate(_ fraction: Double) {
        guard mpv.duration > 0 else { return }
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
}

// MARK: - 自定义进度条

/// 替代系统默认 Slider（iOS 26 上默认滑块很大且不显示缓冲进度）
private struct MPVProgressBar: View {
    let position: Double
    let buffered: Double
    let duration: Double
    let isScrubbing: Bool
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

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
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let ratio = min(max(value.location.x / width, 0), 1)
                        onScrubChanged(Double(ratio) * duration)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let ratio = min(max(value.location.x / width, 0), 1)
                        onScrubEnded(Double(ratio) * duration)
                    }
            )
            .animation(.easeOut(duration: 0.14), value: isScrubbing)
        }
        .frame(height: 28)
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
    var allowedOrientations: UIInterfaceOrientationMask = .landscape
    var onUnexpectedDismiss: (() -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? allowedOrientations : .all
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        if UIDevice.current.userInterfaceIdiom == .phone, allowedOrientations == .landscape {
            return UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
        }
        return super.preferredInterfaceOrientationForPresentation
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            onUnexpectedDismiss?()
        }
    }
}

/// 桥接 PlayerModel.isMPVFullscreen 与 UIKit 全屏弹出 / 收起
struct MPVFullscreenPresenter: UIViewControllerRepresentable {
    @ObservedObject var model: PlayerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.wantPresented = model.isMPVFullscreen
        DispatchQueue.main.async {
            coordinator.sync(from: host)
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.forceDismiss()
    }

    @MainActor
    final class Coordinator {
        var model: PlayerModel
        var wantPresented = false
        private var presented: MPVFullscreenHostingController<MPVFullscreenPlayer>?

        init(model: PlayerModel) {
            self.model = model
        }

        func sync(from host: UIViewController) {
            if wantPresented {
                guard presented == nil else { return }
                guard let presenter = Self.topPresenter(from: host) else { return }
                if let existing = presenter.presentedViewController, existing.isBeingDismissed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak host] in
                        guard let self, let host, self.wantPresented else { return }
                        self.sync(from: host)
                    }
                    return
                }
                let wantsLandscape = UIDevice.current.userInterfaceIdiom == .phone && model.mpv.videoAspect >= 1
                let mode: ScreenOrientation.Mode = wantsLandscape ? .landscape : .portrait
                let controller = MPVFullscreenHostingController(rootView: MPVFullscreenPlayer(model: model))
                controller.allowedOrientations = wantsLandscape ? .landscape : .portrait
                controller.modalPresentationStyle = .fullScreen
                controller.modalPresentationCapturesStatusBarAppearance = true
                controller.overrideUserInterfaceStyle = .dark
                controller.view.backgroundColor = .black
                controller.onUnexpectedDismiss = { [weak self] in
                    guard let self else { return }
                    self.presented = nil
                    self.wantPresented = false
                    self.model.setMPVFullscreen(false)
                    ScreenOrientation.set(.portrait)
                }
                presented = controller
                ScreenOrientation.prepare(mode)
                presenter.present(controller, animated: false) {
                    ScreenOrientation.set(mode)
                }
            } else {
                dismissIfNeeded()
            }
        }

        func forceDismiss() {
            wantPresented = false
            dismissIfNeeded()
        }

        private func dismissIfNeeded() {
            guard let controller = presented else { return }
            presented = nil
            controller.onUnexpectedDismiss = nil
            controller.allowedOrientations = .portrait
            ScreenOrientation.prepare(.portrait)
            if let presenting = controller.presentingViewController {
                presenting.dismiss(animated: false) {
                    ScreenOrientation.set(.portrait)
                }
            } else {
                ScreenOrientation.set(.portrait)
            }
        }

        private static func topPresenter(from host: UIViewController) -> UIViewController? {
            guard var top = host.view.window?.rootViewController else { return nil }
            while let next = top.presentedViewController, !next.isBeingDismissed {
                top = next
            }
            return top
        }
    }
}

/// 屏幕方向管理（配合 AppDelegate.supportedInterfaceOrientationsFor）：
/// 正常页面在 iPhone 上锁竖屏，mpv 横屏全屏锁横屏，系统播放器全屏放开横竖屏，退出全屏后确保完整切回竖屏
@MainActor
enum ScreenOrientation {
    enum Mode: Equatable {
        case portrait
        case landscape
        case flexible
    }

    private(set) static var mode: Mode = .portrait
    private static var verifyTask: Task<Void, Never>?

    static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        switch mode {
        case .portrait:
            if hasSystemPlayerFullscreen(in: window) { return .allButUpsideDown }
            return .portrait
        case .landscape:
            return .landscape
        case .flexible:
            return .allButUpsideDown
        }
    }

    /// 仅更新允许的方向掩码（在 present / dismiss 前调用，避免与转场冲突）
    static func prepare(_ newMode: Mode) {
        mode = newMode
        verifyTask?.cancel()
        verifyTask = nil
    }

    /// 更新允许的方向并通知系统旋转到位
    static func set(_ newMode: Mode) {
        mode = newMode
        verifyTask?.cancel()
        verifyTask = nil
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard let scene = activeScene else { return }

        notifyAllViewControllers(in: scene)

        switch newMode {
        case .flexible:
            // 系统播放器自己管旋转，这里只放开方向掩码，不主动抢几何更新
            return
        case .landscape:
            applyGeometry(in: scene, mask: preferredLandscapeMask())
        case .portrait:
            applyGeometry(in: scene, mask: .portrait)
            refreshSystemBars(in: scene)
            schedulePortraitVerification()
        }
    }

    private static func preferredLandscapeMask() -> UIInterfaceOrientationMask {
        UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func hasSystemPlayerFullscreen(in window: UIWindow?) -> Bool {
        var current = window?.rootViewController
        while let presented = current?.presentedViewController {
            let name = String(describing: type(of: presented))
            if name.contains("AVFullScreen") || name.contains("AVPlayerViewController") {
                return true
            }
            current = presented
        }
        return false
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
    private static func schedulePortraitVerification() {
        verifyTask = Task { @MainActor in
            for delay in [150_000_000 as UInt64, 420_000_000 as UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, mode == .portrait, let scene = activeScene else { return }
                let windowLandscape = scene.windows.contains { $0.bounds.width > $0.bounds.height }
                if scene.interfaceOrientation.isLandscape || windowLandscape {
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
