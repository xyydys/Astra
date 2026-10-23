import AVFoundation
import MediaPlayer
import UIKit

/// 阅读时用音量键翻页：监听系统音量变化，按一下就翻一页，再把音量调回原来的值。
/// 窗口里放一个几乎透明的 MPVolumeView，系统就不会弹出音量提示。
/// 音量已经在最大 / 最小时按键不会产生变化，所以开始时把音量从两端稍微挪开一点。
@MainActor
final class VolumeKeyPager {
    /// true：音量加（上一页），false：音量减（下一页）
    var onPress: (Bool) -> Void = { _ in }

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var baseline: Float = 0.5
    private var changedCategory = false

    var isRunning: Bool { observation != nil }

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // 自己没在放音乐时，换成可以和其他 App 混音的模式再激活，不打断别的 App 的声音
        if !MusicPlayer.shared.isPlaying {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            changedCategory = true
        }
        try? session.setActive(true)

        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        keyWindow?.addSubview(view)
        volumeView = view

        baseline = session.outputVolume
        if baseline > 0.95 { baseline = 0.9 } else if baseline < 0.05 { baseline = 0.1 }
        if baseline != session.outputVolume { setVolume(baseline) }

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.volumeChanged(value) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        if changedCategory {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            changedCategory = false
        }
    }

    private func volumeChanged(_ value: Float) {
        // 调回原值时也会收到一次通知，忽略
        guard abs(value - baseline) > 0.001 else { return }
        onPress(value > baseline)
        setVolume(baseline)
    }

    private func setVolume(_ value: Float) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { slider.value = value }
    }

    private var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
