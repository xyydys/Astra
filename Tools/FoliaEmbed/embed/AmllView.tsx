// 仿 Apple Music 的歌词页：AMLL（Apple Music-like Lyrics，AGPL-3.0）的歌词播放器 + 封面流体背景。
// 歌词由 Folia 的解析器解析成 Line[]，这里转换成 AMLL 的 LyricLine（时间单位毫秒）。
import React, { useEffect, useMemo, useRef } from 'react';
import {
    BackgroundRender,
    LayoutAlignAnchor,
    LyricPlayer,
    MeshGradientRenderer,
    type LyricLine,
    type LyricLineMouseEvent,
} from '@applemusic-like-lyrics/core';
import '@applemusic-like-lyrics/core/style.css';
import type { Line, Word } from '../src/types';

/** 这些格式带逐字时间；普通 LRC 只有行时间，整行作为一个词交给 AMLL（它会按行级歌词显示） */
const WORD_LEVEL_FORMATS = new Set(['yrc', 'qrc', 'krc', 'enhanced-lrc', 'ttml']);

const ms = (seconds: number) => Math.max(0, Math.round(seconds * 1000));

const toWords = (words: Word[] | undefined, text: string, start: number, end: number, wordLevel: boolean) => {
    const timed = wordLevel ? (words ?? []).filter(word => word.text.length > 0) : [];
    if (timed.length === 0) return [{ word: text, startTime: start, endTime: end }];
    return timed.map(word => ({
        word: word.text,
        startTime: ms(word.startTime),
        endTime: Math.max(ms(word.startTime) + 1, ms(word.endTime)),
    }));
};

export const toAmllLines = (lines: Line[], format: string, showTranslation: boolean): LyricLine[] => {
    const wordLevel = WORD_LEVEL_FORMATS.has(format);
    const result: LyricLine[] = [];
    lines.forEach((line, index) => {
        const text = (line.fullText ?? '').trim();
        if (!text) return;
        const start = ms(line.startTime);
        const nextStart = lines[index + 1] ? ms(lines[index + 1].startTime) : start + 6000;
        const end = Math.max(start + 1, line.endTime > line.startTime ? ms(line.endTime) : nextStart);
        result.push({
            words: toWords(line.words, line.fullText, start, end, wordLevel),
            translatedLyric: showTranslation ? (line.translation ?? '') : '',
            romanLyric: '',
            startTime: start,
            endTime: end,
            isBG: false,
            isDuet: false,
        });
        const vocal = line.backgroundVocal ?? line.backgroundVocals?.[0];
        if (vocal && vocal.text.trim()) {
            const bgStart = ms(vocal.startTime);
            const bgEnd = Math.max(bgStart + 1, ms(vocal.endTime));
            result.push({
                words: toWords(vocal.words, vocal.text, bgStart, bgEnd, wordLevel),
                translatedLyric: showTranslation ? (vocal.translation ?? '') : '',
                romanLyric: '',
                startTime: bgStart,
                endTime: bgEnd,
                isBG: true,
                isDuet: false,
            });
        }
    });
    return result;
};

interface AmllViewProps {
    lines: Line[];
    format: string;
    cover?: string;
    /** 当前播放时间（秒），每帧读取 */
    getTime: () => number;
    playing: boolean;
    showTranslation: boolean;
    staticMode: boolean;
    onSeek: (seconds: number) => void;
}

const AmllView: React.FC<AmllViewProps> = ({ lines, format, cover, getTime, playing, showTranslation, staticMode, onSeek }) => {
    const lyricHostRef = useRef<HTMLDivElement>(null);
    const backgroundHostRef = useRef<HTMLDivElement>(null);
    const playerRef = useRef<LyricPlayer | null>(null);
    const backgroundRef = useRef<BackgroundRender<MeshGradientRenderer> | null>(null);
    const getTimeRef = useRef(getTime);
    const onSeekRef = useRef(onSeek);
    getTimeRef.current = getTime;
    onSeekRef.current = onSeek;

    const amllLines = useMemo(() => toAmllLines(lines, format, showTranslation), [lines, format, showTranslation]);

    useEffect(() => {
        const lyricHost = lyricHostRef.current;
        const backgroundHost = backgroundHostRef.current;
        if (!lyricHost || !backgroundHost) return;

        const player = new LyricPlayer();
        const lyricElement = player.getElement();
        lyricElement.style.width = '100%';
        lyricElement.style.height = '100%';
        lyricHost.appendChild(lyricElement);
        player.setAlignAnchor(LayoutAlignAnchor.Center);
        player.setAlignPosition(0.36);
        player.setEnableSpring(true);
        player.setEnableScale(true);
        player.setEnableBlur(true);
        player.setWordFadeWidth(0.5);
        const onLineClick = (event: Event) => {
            const line = player.getLyricLines()[(event as LyricLineMouseEvent).lineIndex];
            if (line) onSeekRef.current(line.startTime / 1000);
        };
        player.addEventListener('line-click', onLineClick);
        playerRef.current = player;

        const background = BackgroundRender.new(MeshGradientRenderer);
        const canvas = background.getElement();
        canvas.style.width = '100%';
        canvas.style.height = '100%';
        backgroundHost.appendChild(canvas);
        background.setRenderScale(0.5);
        background.setFPS(30);
        background.setFlowSpeed(2);
        backgroundRef.current = background;

        let frame = 0;
        let lastFrame = -1;
        let lastTime = -1;
        const tick = (now: number) => {
            const delta = lastFrame < 0 ? 0 : now - lastFrame;
            lastFrame = now;
            const time = Math.round(getTimeRef.current() * 1000);
            if (time !== lastTime) {
                // 正常播放一帧只走十几毫秒，跳了一秒多说明是拖动了进度
                player.setCurrentTime(time, lastTime >= 0 && Math.abs(time - lastTime) > 1200);
                lastTime = time;
            }
            player.update(delta);
            frame = requestAnimationFrame(tick);
        };
        frame = requestAnimationFrame(tick);

        return () => {
            cancelAnimationFrame(frame);
            player.removeEventListener('line-click', onLineClick);
            player.dispose();
            background.dispose();
            lyricElement.remove();
            canvas.remove();
            playerRef.current = null;
            backgroundRef.current = null;
        };
    }, []);

    useEffect(() => {
        const player = playerRef.current;
        if (!player) return;
        player.setLyricLines(amllLines, Math.round(getTimeRef.current() * 1000));
        player.update();
        backgroundRef.current?.setHasLyric(amllLines.length > 0);
    }, [amllLines]);

    useEffect(() => {
        if (cover) void backgroundRef.current?.setAlbum(cover);
    }, [cover]);

    useEffect(() => {
        const player = playerRef.current;
        const background = backgroundRef.current;
        if (playing) {
            player?.resume();
            background?.resume();
        } else {
            player?.pause();
            background?.pause();
        }
    }, [playing]);

    useEffect(() => {
        backgroundRef.current?.setStaticMode(staticMode);
    }, [staticMode]);

    return (
        <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', background: '#111' }}>
            <div ref={backgroundHostRef} style={{ position: 'absolute', inset: 0 }} />
            <div
                ref={lyricHostRef}
                style={{
                    position: 'absolute',
                    inset: 0,
                    padding: 'calc(env(safe-area-inset-top, 0px) + 24px) 26px 0',
                    boxSizing: 'border-box',
                    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", sans-serif',
                    fontWeight: 700,
                    // 和 Apple Music 一样：字号跟屏幕宽度走，竖屏上大约一行七八个汉字
                    ['--amll-lp-font-size' as string]: 'clamp(26px, 8.4vw, 46px)',
                    ['--amll-lp-color' as string]: 'rgba(255, 255, 255, 0.96)',
                    maskImage: 'linear-gradient(to bottom, transparent 0, #000 12%, #000 80%, transparent 96%)',
                    WebkitMaskImage: 'linear-gradient(to bottom, transparent 0, #000 12%, #000 80%, transparent 96%)',
                }}
            />
        </div>
    );
};

export default AmllView;
