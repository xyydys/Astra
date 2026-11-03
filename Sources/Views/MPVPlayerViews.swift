import SwiftUI
import UIKit

// MARK: - 画面容器

/// mpv 的画面只有一个，在内嵌和全屏之间搬：claim 为 true 的容器持有它
struct MPVVideoHost: UIViewRepresentable {
    let surface: MPVSurfaceView
    let claim: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        if claim { Self.attach(surface, to: container) }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if claim, surface.superview !== container { Self.attach(surface, to: container) }
    }

    private static func attach(_ surface: UIView, to container: UIView) {
        surface.removeFromSuperview()
        surface.frame = container.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(surface)
    }
}

// MARK: - 控制条

struct MPVControls: View {
    @ObservedObject var mpv: MPVPlayback
    var title = ""
    let isFullscreen: Bool
    let toggleFullscreen: () -> Void

    @State private var visible = true
    @State private var scrub: Double?
    @State private var hideTask: Task<Void, Never>?

    private static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleVisible() }

            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)

            if mpv.isBuffering, scrub == nil {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                    .allowsHitTesting(false)
            }

            // 隐藏时只是透明，不从界面上拿掉：菜单打开时控制条自动隐藏也不会把菜单关掉
            VStack(spacing: 0) {
                if isFullscreen { topBar }
                Spacer(minLength: 0)
                centerButtons
                Spacer(minLength: 0)
                bottomBar
            }
            .foregroundStyle(.white)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .onChangeCompat(of: mpv.isPaused) { _, paused in
            if paused {
                hideTask?.cancel()
                withAnimation(.easeOut(duration: 0.2)) { visible = true }
            } else {
                scheduleHide()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: toggleFullscreen) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("退出全屏")
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private var centerButtons: some View {
        HStack(spacing: isFullscreen ? 64 : 44) {
            controlButton("gobackward.10", size: 22, label: "后退 10 秒") { mpv.seek(by: -10) }
            if mpv.isBuffering, scrub == nil {
                // 缓冲时转圈的位置就是播放键的位置
                Color.clear.frame(width: 56, height: 56)
            } else {
                controlButton(mpv.isPaused ? "play.fill" : "pause.fill", size: 34, label: mpv.isPaused ? "播放" : "暂停") {
                    mpv.togglePause()
                }
            }
            controlButton("goforward.10", size: 22, label: "前进 10 秒") { mpv.seek(by: 10) }
        }
    }

    private var bottomBar: some View {
        let upper = max(mpv.duration, 1)
        return HStack(spacing: 10) {
            Text(Self.time(scrub ?? mpv.position))
            Slider(
                value: Binding(
                    get: { min(scrub ?? mpv.position, upper) },
                    set: { scrub = $0 }
                ),
                in: 0...upper,
                onEditingChanged: { editing in
                    if editing {
                        hideTask?.cancel()
                    } else if let target = scrub {
                        mpv.seek(to: target)
                        scrub = nil
                        scheduleHide()
                    }
                }
            )
            .tint(.white)
            .disabled(mpv.duration <= 0)
            Text(Self.time(mpv.duration))
            optionsMenu
            Button(action: toggleFullscreen) {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.bottom, isFullscreen ? 4 : 6)
    }

    private var optionsMenu: some View {
        Menu {
            if !mpv.audioTracks.isEmpty {
                Section("音轨") {
                    ForEach(mpv.audioTracks) { track in
                        Button { mpv.selectAudio(track.id) } label: { checkLabel(track.title, track.selected) }
                    }
                }
            }
            Section("字幕") {
                Button { mpv.selectSubtitle(nil) } label: { checkLabel("关闭字幕", mpv.subtitleOff) }
                ForEach(mpv.subtitleTracks) { track in
                    Button { mpv.selectSubtitle(track.id) } label: { checkLabel(track.title, track.selected) }
                }
            }
            Section("倍速") {
                ForEach(Self.speeds, id: \.self) { rate in
                    Button { mpv.setSpeed(rate) } label: {
                        checkLabel(rate == 1 ? "正常" : String(format: "%gx", rate), abs(mpv.speed - rate) < 0.01)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("音轨、字幕和倍速")
    }

    @ViewBuilder
    private func checkLabel(_ title: String, _ selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func controlButton(_ icon: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private func toggleVisible() {
        withAnimation(.easeOut(duration: 0.2)) { visible.toggle() }
        if visible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !mpv.isPaused, scrub == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { visible = false }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - 全屏

struct MPVFullscreenPlayer: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoHost(surface: model.mpv.surface, claim: model.isMPVFullscreen)
                .ignoresSafeArea()
            MPVControls(
                mpv: model.mpv,
                title: model.currentEpisode.map { "\(model.request.title) · \($0.name)" } ?? model.request.title,
                isFullscreen: true
            ) {
                model.setMPVFullscreen(false)
            }
        }
        .statusBarHidden()
        .homeIndicatorHiddenCompat()
        .preferredColorScheme(.dark)
    }
}

/// 全屏时转横屏、退出时转回竖屏（只在 iPhone 上）
@MainActor
enum ScreenOrientation {
    static func rotate(landscape: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        if #available(iOS 16, *) {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        } else {
            let orientation: UIInterfaceOrientation = landscape ? .landscapeRight : .portrait
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
