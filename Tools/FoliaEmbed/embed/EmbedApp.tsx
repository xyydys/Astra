// Astra 内嵌的 Folia 歌词动画（AGPL-3.0）
// 派生自 folia-major 的 src/components/obs/ObsBrowserSourceApp.tsx：
// 原版通过 SSE 从 Folia 主窗口拿歌词和播放时钟，这里改成由宿主 App（Swift / WKWebView）调用 window.kazumi 推送。
import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useMotionValue } from 'framer-motion';
import VisualizerRenderer from '../src/components/visualizer/VisualizerRenderer';
import { NO_LYRIC_LINES } from '../src/utils/lyrics/noLyricLines';
import { parseLyricsByFormat } from '../src/utils/lyrics/parserCore';
import { findLatestActiveLineIndex } from '../src/utils/appPlaybackHelpers';
import { DEFAULT_THEME } from '../src/services/baseThemes';
import type { Line, Theme, VisualizerMode } from '../src/types';
import type { VisualizerBackgroundConfig } from '../src/components/visualizer/backgrounds/definition';

type LyricFormat = 'lrc' | 'yrc' | 'qrc' | 'krc' | 'enhanced-lrc' | 'ttml';

interface EmbedSong {
    id: string;
    title?: string;
    artist?: string;
    album?: string;
    cover?: string;
    lyric?: { format?: LyricFormat; content?: string; translation?: string } | null;
}

interface EmbedClock {
    time: number;
    duration: number;
    playing: boolean;
    rate?: number;
    sentAt?: number;
}

interface EmbedState {
    song: EmbedSong | null;
    lines: Line[];
    mode: VisualizerMode;
    background: VisualizerBackgroundConfig;
    theme: Theme;
    isDaylight: boolean;
    lyricsFontScale: number;
    staticMode: boolean;
    showTranslation: boolean;
}

declare global {
    interface Window {
        kazumi?: {
            setSong: (song: EmbedSong | null) => void;
            setClock: (clock: EmbedClock) => void;
            setMode: (mode: string) => void;
            setBackground: (mode: string) => void;
            setTheme: (theme: Partial<Theme>, isDaylight?: boolean) => void;
            setOptions: (options: { lyricsFontScale?: number; staticMode?: boolean; showTranslation?: boolean }) => void;
        };
        webkit?: { messageHandlers?: Record<string, { postMessage: (message: unknown) => void }> };
    }
}

const post = (message: Record<string, unknown>) => {
    try {
        window.webkit?.messageHandlers?.folia?.postMessage(message);
    } catch {
        // 不在 App 里（浏览器调试）时忽略
    }
};

const parseLines = (song: EmbedSong | null): Line[] => {
    const content = song?.lyric?.content?.trim();
    if (!content) return [];
    try {
        const data = parseLyricsByFormat(song?.lyric?.format ?? 'lrc', content, song?.lyric?.translation ?? '');
        return data.lines ?? [];
    } catch (error) {
        post({ type: 'log', message: `歌词解析失败：${String(error)}` });
        try {
            return parseLyricsByFormat('lrc', content, song?.lyric?.translation ?? '').lines ?? [];
        } catch {
            return [];
        }
    }
};

const clockTime = (clock: EmbedClock | null) => {
    if (!clock) return 0;
    if (!clock.playing) return clock.time;
    const elapsed = Math.max(0, (performance.now() - (clock.sentAt ?? performance.now())) / 1000);
    const next = clock.time + elapsed * (clock.rate || 1);
    return clock.duration > 0 ? Math.min(clock.duration, next) : next;
};

const EMPTY_SPECTRUM = new Uint8Array(0);

const EmbedApp: React.FC = () => {
    const [state, setState] = useState<EmbedState>({
        song: null,
        lines: [],
        mode: 'classic',
        background: { mode: 'latent' },
        theme: DEFAULT_THEME,
        isDaylight: false,
        lyricsFontScale: 1,
        staticMode: false,
        showTranslation: true,
    });
    const [playing, setPlaying] = useState(false);
    const [duration, setDuration] = useState(0);
    const [currentLineIndex, setCurrentLineIndex] = useState(-1);
    const clockRef = useRef<EmbedClock | null>(null);
    const linesRef = useRef<Line[]>([]);
    const lineIndexRef = useRef(-1);
    const currentTime = useMotionValue(0);
    const audioPower = useMotionValue(0);
    const bass = useMotionValue(0);
    const lowMid = useMotionValue(0);
    const mid = useMotionValue(0);
    const vocal = useMotionValue(0);
    const treble = useMotionValue(0);
    const spectrum = useMotionValue(EMPTY_SPECTRUM);
    const audioBands = useMemo(() => ({ bass, lowMid, mid, vocal, treble, spectrum }), [bass, lowMid, mid, vocal, treble, spectrum]);

    useEffect(() => {
        linesRef.current = state.lines;
    }, [state.lines]);

    useEffect(() => {
        window.kazumi = {
            setSong: song => {
                const lines = parseLines(song);
                linesRef.current = lines;
                lineIndexRef.current = -1;
                setCurrentLineIndex(-1);
                setState(prev => ({ ...prev, song, lines }));
                post({ type: 'lyrics', count: lines.length });
            },
            setClock: clock => {
                clockRef.current = { ...clock, sentAt: performance.now() };
                setPlaying(prev => (prev === clock.playing ? prev : clock.playing));
                setDuration(prev => (prev === clock.duration ? prev : (Number.isFinite(clock.duration) ? clock.duration : 0)));
            },
            setMode: mode => setState(prev => ({ ...prev, mode: mode as VisualizerMode })),
            setBackground: mode => setState(prev => ({ ...prev, background: { ...prev.background, mode: mode as VisualizerBackgroundConfig['mode'] } })),
            setTheme: (theme, isDaylight) => setState(prev => ({
                ...prev,
                theme: { ...DEFAULT_THEME, ...theme },
                isDaylight: isDaylight ?? prev.isDaylight,
            })),
            setOptions: options => setState(prev => ({
                ...prev,
                lyricsFontScale: options.lyricsFontScale ?? prev.lyricsFontScale,
                staticMode: options.staticMode ?? prev.staticMode,
                showTranslation: options.showTranslation ?? prev.showTranslation,
            })),
        };
        post({ type: 'ready' });
        return () => {
            delete window.kazumi;
        };
    }, []);

    // 和 OBS 渲染器一样，按时钟插值推进歌词时间
    useEffect(() => {
        let frameId = 0;
        const tick = () => {
            const time = clockTime(clockRef.current);
            currentTime.set(time);
            // 没有音频分析：用很轻的呼吸感代替，让依赖音量的效果不至于完全静止
            const clock = clockRef.current;
            audioPower.set(clock?.playing ? 0.35 + 0.15 * Math.sin(time * 2.1) : 0);
            const lines = linesRef.current;
            const next = lines.length > 0 ? findLatestActiveLineIndex(lines, time) : -1;
            if (next !== lineIndexRef.current) {
                lineIndexRef.current = next;
                setCurrentLineIndex(next);
            }
            frameId = window.requestAnimationFrame(tick);
        };
        frameId = window.requestAnimationFrame(tick);
        return () => window.cancelAnimationFrame(frameId);
    }, [audioPower, currentTime]);

    const { song, theme } = state;

    return (
        <div
            className="overflow-hidden"
            style={{ width: '100vw', height: '100vh', backgroundColor: theme.backgroundColor, color: theme.primaryColor }}
        >
            <VisualizerRenderer
                mode={state.mode}
                currentTime={currentTime}
                duration={duration}
                currentLineIndex={currentLineIndex}
                lines={state.lines.length > 0 ? state.lines : NO_LYRIC_LINES}
                theme={theme}
                isDaylight={state.isDaylight}
                audioPower={audioPower}
                audioBands={audioBands}
                songTitle={song?.title}
                songArtist={song?.artist}
                songAlbum={song?.album}
                coverUrl={song?.cover}
                showText={true}
                seed={song?.id ?? 'kazumi'}
                staticMode={state.staticMode}
                paused={!playing}
                visualizerOpacity={1}
                background={state.background}
                lyricsFontScale={state.lyricsFontScale}
                subtitleFontScale={1}
                subtitleOverlayOpacity={1}
                subtitleOverlayBackground={false}
                subtitleUpcomingLyricsBlur={true}
                showHarmonySubtitle={true}
                harmonySubtitleBackground={false}
                isPlayerChromeHidden={true}
                hideTranslationSubtitle={!state.showTranslation}
                showSubtitleTranslation={state.showTranslation}
                onLyricLineSeek={time => post({ type: 'seek', time })}
            />
        </div>
    );
};

export default EmbedApp;
