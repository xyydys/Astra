// Mineradio（GPL-3.0）的封面粒子特效：three.js 粒子场景 + 居中发光的逐字歌词。
// 原版用音频分析驱动律动，App 里拿不到音频数据，这里改成跟着歌词的字和行打拍子。
import React, { useEffect, useRef } from 'react';
import * as THREE from 'three';
import type { Line } from '../src/types';
import {
    bloomFragmentShader,
    bloomVertexShader,
    particleFragmentShader,
    particleVertexShader,
    starRiverFragmentShader,
    starRiverVertexShader,
} from './mineradioShaders';

export const MINERADIO_PRESETS = {
    cover: 0,
    tunnel: 1,
    planet: 2,
    vinyl: 4,
    river: 5,
    eclipse: 9,
    drizzle: 10,
    flock: 11,
    bloom: 12,
} as const;

export type MineradioPreset = keyof typeof MINERADIO_PRESETS;

/** 各预设的取景：内容半径（自动按屏幕宽高算机位距离）、固定距离、俯仰角、背景星河亮度 */
const FRAMING: Record<MineradioPreset, { radius?: number; distance?: number; tilt: number; stars: number; grid: number }> = {
    cover: { radius: 2.5, tilt: -0.1, stars: 0.34, grid: 120 },
    tunnel: { distance: 9.6, tilt: 0, stars: 0.34, grid: 150 },
    planet: { radius: 3.1, tilt: 0.12, stars: 0.34, grid: 150 },
    vinyl: { radius: 2.65, tilt: 0.45, stars: 0.34, grid: 170 },
    river: { distance: 19, tilt: 0, stars: 0, grid: 180 },
    eclipse: { radius: 5.3, tilt: 0, stars: 0.12, grid: 150 },
    drizzle: { radius: 4.4, tilt: 0, stars: 0.18, grid: 150 },
    flock: { radius: 4.6, tilt: 0, stars: 0.1, grid: 150 },
    bloom: { radius: 4.3, tilt: 0, stars: 0.16, grid: 150 },
};

const WORD_LEVEL_FORMATS = new Set(['yrc', 'qrc', 'krc', 'enhanced-lrc', 'ttml']);
const FOV = 50;

interface MineradioViewProps {
    preset: MineradioPreset;
    lines: Line[];
    format: string;
    cover?: string;
    getTime: () => number;
    playing: boolean;
    staticMode: boolean;
    showTranslation: boolean;
    backgroundColor: string;
    accentColor: string;
    onSeek: (seconds: number) => void;
    onLog?: (message: string) => void;
}

const makeDotTexture = () => {
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 64;
    const context = canvas.getContext('2d')!;
    const gradient = context.createRadialGradient(32, 32, 0, 32, 32, 31);
    gradient.addColorStop(0, 'rgba(255,255,255,0.96)');
    gradient.addColorStop(0.42, 'rgba(255,255,255,0.78)');
    gradient.addColorStop(0.72, 'rgba(255,255,255,0.22)');
    gradient.addColorStop(1, 'rgba(255,255,255,0)');
    context.fillStyle = gradient;
    context.fillRect(0, 0, 64, 64);
    const texture = new THREE.CanvasTexture(canvas);
    texture.minFilter = THREE.LinearFilter;
    texture.magFilter = THREE.LinearFilter;
    return texture;
};

const makeSolidTexture = (color: string) => {
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 4;
    const context = canvas.getContext('2d')!;
    context.fillStyle = color;
    context.fillRect(0, 0, 4, 4);
    const texture = new THREE.CanvasTexture(canvas);
    texture.minFilter = THREE.LinearFilter;
    texture.magFilter = THREE.LinearFilter;
    return texture;
};

const buildGrid = (grid: number) => {
    const count = grid * grid;
    const geometry = new THREE.BufferGeometry();
    const positions = new Float32Array(count * 3);
    const uvs = new Float32Array(count * 2);
    const rands = new Float32Array(count);
    const size = 4.8;
    for (let i = 0; i < count; i += 1) {
        const gx = i % grid;
        const gy = Math.floor(i / grid);
        positions[i * 3] = (gx / (grid - 1) - 0.5) * size;
        positions[i * 3 + 1] = (gy / (grid - 1) - 0.5) * size;
        uvs[i * 2] = (gx + 0.5) / grid;
        uvs[i * 2 + 1] = (gy + 0.5) / grid;
        rands[i] = Math.random();
    }
    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geometry.setAttribute('aUv', new THREE.BufferAttribute(uvs, 2));
    geometry.setAttribute('aRand', new THREE.BufferAttribute(rands, 1));
    return geometry;
};

const buildStarRiver = (count: number) => {
    const geometry = new THREE.BufferGeometry();
    const seeds = new Float32Array(count);
    const lanes = new Float32Array(count);
    const depths = new Float32Array(count);
    for (let i = 0; i < count; i += 1) {
        seeds[i] = Math.random() * 1000 + i * 0.37;
        lanes[i] = Math.random();
        depths[i] = Math.random();
    }
    // three 需要 position 才知道点的数量
    geometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(count * 3), 3));
    geometry.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 1));
    geometry.setAttribute('aLane', new THREE.BufferAttribute(lanes, 1));
    geometry.setAttribute('aDepthSeed', new THREE.BufferAttribute(depths, 1));
    return geometry;
};

const LYRIC_STYLE = `
.mr-lyrics { position: absolute; left: 7%; right: 7%; top: 69%; height: 0; text-align: center;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", sans-serif; color: #fff; }
.mr-slot { position: absolute; left: 0; right: 0; top: 0; transform: translateY(-50%); }
.mr-block { will-change: opacity, transform, filter; }
.mr-block.mr-enter { animation: mr-in 0.7s cubic-bezier(0.2, 0.8, 0.2, 1) both; }
.mr-block.mr-leave { animation: mr-out 0.45s ease-in both; }
.mr-line { font-size: clamp(22px, 6.4vw, 38px); font-weight: 700; line-height: 1.28; letter-spacing: 0.02em;
  filter: drop-shadow(0 0 6px rgba(255,255,255,0.45)) drop-shadow(0 0 18px var(--mr-glow, rgba(160,200,255,0.55))); }
.mr-word { --p: 0; background-image: linear-gradient(90deg, #fff 0, #fff calc(var(--p) * (100% + 0.4em) - 0.4em), rgba(255,255,255,0.34) calc(var(--p) * (100% + 0.4em)));
  -webkit-background-clip: text; background-clip: text; color: transparent; -webkit-text-fill-color: transparent; white-space: pre-wrap; }
.mr-trans { margin-top: 0.55em; font-size: clamp(13px, 3.6vw, 19px); font-weight: 500; opacity: 0.72; letter-spacing: 0.04em;
  filter: drop-shadow(0 0 8px var(--mr-glow, rgba(160,200,255,0.45))); }
@keyframes mr-in { from { opacity: 0; transform: translateY(16px) scale(0.97); filter: blur(10px); } to { opacity: 1; transform: none; filter: blur(0); } }
@keyframes mr-out { from { opacity: 1; filter: blur(0); } to { opacity: 0; transform: translateY(-12px) scale(1.02); filter: blur(8px); } }
`;

interface ShownWord { el: HTMLSpanElement; start: number; end: number; progress: number }

const MineradioView: React.FC<MineradioViewProps> = props => {
    const hostRef = useRef<HTMLDivElement>(null);
    const lyricRef = useRef<HTMLDivElement>(null);
    const propsRef = useRef(props);
    propsRef.current = props;
    const sceneRef = useRef<{
        setCover: (url?: string) => void;
        setPreset: (preset: MineradioPreset) => void;
        setColors: (background: string, accent: string) => void;
    } | null>(null);

    useEffect(() => {
        const host = hostRef.current;
        const lyricHost = lyricRef.current;
        if (!host || !lyricHost) return;

        let renderer: THREE.WebGLRenderer;
        try {
            renderer = new THREE.WebGLRenderer({ antialias: false, alpha: false, powerPreference: 'high-performance' });
        } catch (error) {
            propsRef.current.onLog?.(`Mineradio 特效无法创建 WebGL：${String(error)}`);
            return;
        }
        const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
        renderer.setPixelRatio(pixelRatio);
        renderer.autoClear = false;
        renderer.domElement.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block';
        host.appendChild(renderer.domElement);

        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(FOV, 1, 0.1, 200);
        const starScene = new THREE.Scene();
        const starCamera = new THREE.PerspectiveCamera(FOV, 1, 0.1, 200);
        starCamera.position.set(0, 0, 7);

        const dotTexture = makeDotTexture();
        let coverTexture: THREE.Texture = makeSolidTexture('#1c1c28');
        let previousTexture: THREE.Texture = makeSolidTexture('#1c1c28');
        const uniforms = {
            uTime: { value: 0 },
            uBass: { value: 0 },
            uMid: { value: 0 },
            uTreble: { value: 0 },
            uBeat: { value: 0 },
            uEnergy: { value: 0 },
            uBurstAmt: { value: 0 },
            uVinylSpin: { value: 0 },
            uPreset: { value: 0 },
            uIntensity: { value: 0.85 },
            uSpeed: { value: 1 },
            uColorBoost: { value: 1.1 },
            uHasCover: { value: 0 },
            uPixel: { value: pixelRatio },
            uSizeScale: { value: 1 },
            uColorMixT: { value: 1 },
            uCoverTex: { value: coverTexture },
            uPrevCoverTex: { value: previousTexture },
            uDotTex: { value: dotTexture },
            uAlpha: { value: 0 },
            uBloomStrength: { value: 0.62 },
            uBloomSize: { value: 2.4 },
        };
        const material = new THREE.ShaderMaterial({
            uniforms,
            vertexShader: particleVertexShader,
            fragmentShader: particleFragmentShader,
            transparent: true,
            depthWrite: false,
            blending: THREE.NormalBlending,
        });
        const bloomMaterial = new THREE.ShaderMaterial({
            uniforms,
            vertexShader: bloomVertexShader,
            fragmentShader: bloomFragmentShader,
            transparent: true,
            depthWrite: false,
            depthTest: false,
            blending: THREE.AdditiveBlending,
        });
        let grid = FRAMING[propsRef.current.preset].grid;
        let geometry = buildGrid(grid);
        const group = new THREE.Group();
        const bloomPoints = new THREE.Points(geometry, bloomMaterial);
        const points = new THREE.Points(geometry, material);
        bloomPoints.frustumCulled = false;
        points.frustumCulled = false;
        bloomPoints.renderOrder = 0;
        points.renderOrder = 1;
        group.add(bloomPoints, points);
        scene.add(group);

        const starUniforms = {
            uDotTex: { value: dotTexture },
            uTime: uniforms.uTime,
            uBass: uniforms.uBass,
            uTreble: uniforms.uTreble,
            uBeat: uniforms.uBeat,
            uEnergy: uniforms.uEnergy,
            uPixel: uniforms.uPixel,
            uTintColor: { value: new THREE.Color(propsRef.current.accentColor) },
            uAlpha: { value: 0 },
        };
        const starGeometry = buildStarRiver(1400);
        const starMaterial = new THREE.ShaderMaterial({
            uniforms: starUniforms,
            vertexShader: starRiverVertexShader,
            fragmentShader: starRiverFragmentShader,
            transparent: true,
            depthWrite: false,
            depthTest: false,
            blending: THREE.AdditiveBlending,
        });
        const stars = new THREE.Points(starGeometry, starMaterial);
        stars.frustumCulled = false;
        starScene.add(stars);

        const clearColor = new THREE.Color(propsRef.current.backgroundColor);
        let preset: MineradioPreset = propsRef.current.preset;
        let width = 1;
        let height = 1;
        let distance = 8;
        let colorMixTarget = 1;

        const tanV = Math.tan(THREE.MathUtils.degToRad(FOV / 2));
        // 粒子主体放在画面上部（中心约在 36% 高度），下面留给歌词
        const fitDistance = () => {
            const framing = FRAMING[preset];
            if (framing.distance) return framing.distance;
            const tanH = tanV * (width / Math.max(1, height));
            const radius = framing.radius ?? 3;
            return Math.max(radius / (0.6 * tanV), radius / (0.9 * tanH));
        };

        const resize = () => {
            width = Math.max(1, host.clientWidth);
            height = Math.max(1, host.clientHeight);
            renderer.setSize(width, height, false);
            camera.aspect = width / height;
            camera.updateProjectionMatrix();
            starCamera.aspect = width / height;
            starCamera.updateProjectionMatrix();
            distance = fitDistance();
        };
        const observer = new ResizeObserver(resize);
        observer.observe(host);
        resize();

        const applyPreset = (next: MineradioPreset) => {
            preset = next;
            uniforms.uPreset.value = MINERADIO_PRESETS[next];
            uniforms.uBurstAmt.value = 1;
            uniforms.uAlpha.value = 0;
            const nextGrid = FRAMING[next].grid;
            if (nextGrid !== grid) {
                grid = nextGrid;
                const old = geometry;
                geometry = buildGrid(grid);
                points.geometry = geometry;
                bloomPoints.geometry = geometry;
                old.dispose();
            }
            group.rotation.set(0, 0, 0);
            distance = fitDistance();
        };
        applyPreset(preset);

        let coverToken = 0;
        const loader = new THREE.TextureLoader();
        const setCover = (url?: string) => {
            const token = ++coverToken;
            if (!url) {
                uniforms.uHasCover.value = 0;
                return;
            }
            loader.load(url, texture => {
                if (token !== coverToken) {
                    texture.dispose();
                    return;
                }
                texture.minFilter = THREE.LinearFilter;
                texture.magFilter = THREE.LinearFilter;
                texture.generateMipmaps = false;
                previousTexture.dispose();
                previousTexture = coverTexture;
                coverTexture = texture;
                uniforms.uPrevCoverTex.value = previousTexture;
                uniforms.uCoverTex.value = coverTexture;
                // 第一张封面直接显示，之后切歌时新旧封面渐变
                uniforms.uColorMixT.value = uniforms.uHasCover.value > 0.5 ? 0 : 1;
                colorMixTarget = 1;
                uniforms.uHasCover.value = 1;
                uniforms.uBurstAmt.value = Math.max(uniforms.uBurstAmt.value, 0.35);
            });
        };

        const setColors = (background: string, accent: string) => {
            clearColor.set(background).multiplyScalar(0.6);
            starUniforms.uTintColor.value.set(accent);
        };
        setColors(propsRef.current.backgroundColor, propsRef.current.accentColor);

        sceneRef.current = { setCover, setPreset: applyPreset, setColors };
        setCover(propsRef.current.cover);

        // ---- 歌词 ----
        let shownIndex = -2;
        let shownWords: ShownWord[] = [];
        let block: HTMLDivElement | null = null;
        let lastWordIndex = -1;
        const lineEndHold = 1.4;

        const currentLineIndex = (lines: Line[], time: number) => {
            for (let index = lines.length - 1; index >= 0; index -= 1) {
                const line = lines[index];
                if (time < line.startTime) continue;
                const end = Math.max(line.endTime, line.startTime + 0.5);
                return time <= end + lineEndHold ? index : -1;
            }
            return -1;
        };

        const showLine = (lines: Line[], index: number, wordLevel: boolean, showTranslation: boolean) => {
            if (block) {
                const leaving = block;
                const inner = leaving.firstElementChild;
                inner?.classList.remove('mr-enter');
                inner?.classList.add('mr-leave');
                window.setTimeout(() => leaving.remove(), 460);
                block = null;
            }
            shownWords = [];
            lastWordIndex = -1;
            const line = lines[index];
            if (!line || !line.fullText.trim()) return;
            // 外层负责居中，里层负责进出场动画（动画会改 transform）
            const slot = document.createElement('div');
            slot.className = 'mr-slot';
            const next = document.createElement('div');
            next.className = 'mr-block mr-enter';
            slot.appendChild(next);
            const text = document.createElement('div');
            text.className = 'mr-line';
            const words = wordLevel && line.words?.length ? line.words.filter(word => word.text.length > 0) : [];
            if (words.length > 0) {
                for (const word of words) {
                    const span = document.createElement('span');
                    span.className = 'mr-word';
                    span.textContent = word.text;
                    text.appendChild(span);
                    shownWords.push({ el: span, start: word.startTime, end: Math.max(word.endTime, word.startTime + 0.05), progress: -1 });
                }
            } else {
                const span = document.createElement('span');
                span.className = 'mr-word';
                span.textContent = line.fullText;
                span.style.setProperty('--p', '1');
                text.appendChild(span);
            }
            next.appendChild(text);
            if (showTranslation && line.translation?.trim()) {
                const translation = document.createElement('div');
                translation.className = 'mr-trans';
                translation.textContent = line.translation;
                next.appendChild(translation);
            }
            const lineStart = line.startTime;
            next.addEventListener('click', () => propsRef.current.onSeek(lineStart));
            lyricHost.appendChild(slot);
            block = slot;
        };

        // ---- 律动：没有音频数据，跟着歌词打拍子 ----
        let beat = 0;
        let energy = 0;
        let lastNow = performance.now();
        let elapsed = 0;
        let frame = 0;

        const tick = (now: number) => {
            const dt = Math.min(0.1, Math.max(0, (now - lastNow) / 1000));
            lastNow = now;
            const current = propsRef.current;
            const time = current.getTime();
            const lines = current.lines;
            const wordLevel = WORD_LEVEL_FORMATS.has(current.format);

            const index = currentLineIndex(lines, time);
            if (index !== shownIndex) {
                if (index >= 0 && shownIndex !== -2) beat = 1;
                shownIndex = index;
                showLine(lines, index, wordLevel, current.showTranslation);
            }
            let wordIndex = -1;
            shownWords.forEach((word, i) => {
                const progress = Math.min(1, Math.max(0, (time - word.start) / (word.end - word.start)));
                if (time >= word.start) wordIndex = i;
                if (Math.abs(progress - word.progress) > 0.004) {
                    word.progress = progress;
                    word.el.style.setProperty('--p', progress.toFixed(3));
                }
            });
            if (wordIndex > lastWordIndex) {
                beat = Math.max(beat, 0.62);
                lastWordIndex = wordIndex;
            }

            const target = current.playing && !current.staticMode ? 1 : 0;
            energy += (target - energy) * Math.min(1, dt * 1.6);
            beat *= Math.exp(-dt * 5.2);
            if (!current.staticMode) elapsed += dt * (0.3 + 0.7 * energy);
            const groove = 0.5 + 0.5 * Math.sin(elapsed * 1.7);
            uniforms.uTime.value = elapsed;
            uniforms.uBeat.value = beat * energy;
            uniforms.uBass.value = energy * (0.16 + 0.34 * beat + 0.10 * groove);
            uniforms.uMid.value = energy * (0.24 + 0.12 * Math.sin(elapsed * 0.9) + 0.14 * beat);
            uniforms.uTreble.value = energy * (0.14 + 0.24 * beat + 0.06 * Math.sin(elapsed * 3.1));
            uniforms.uEnergy.value = energy * 0.6;
            uniforms.uBurstAmt.value *= Math.exp(-dt * 2.2);
            uniforms.uAlpha.value += (1 - uniforms.uAlpha.value) * Math.min(1, dt * 2.4);
            uniforms.uColorMixT.value += (colorMixTarget - uniforms.uColorMixT.value) * Math.min(1, dt * 1.8);
            if (current.playing) uniforms.uVinylSpin.value += dt * 0.9;
            const starTarget = FRAMING[preset].stars;
            starUniforms.uAlpha.value += (starTarget - starUniforms.uAlpha.value) * Math.min(1, dt * 3);

            // 机位：缓慢环绕，粒子主体放在歌词上方
            const framing = FRAMING[preset];
            const sway = Math.sin(elapsed * 0.11) * 0.16;
            const lift = preset === 'river' ? 0 : -0.28 * distance * tanV;
            const flat = Math.cos(framing.tilt) * distance;
            camera.position.set(Math.sin(sway) * flat, lift + Math.sin(framing.tilt) * distance, Math.cos(sway) * flat);
            camera.lookAt(0, lift, 0);
            if (preset === 'cover') {
                group.rotation.x = Math.sin(elapsed * 0.21) * 0.06;
                group.rotation.y = Math.sin(elapsed * 0.17) * 0.12;
            }

            renderer.setClearColor(clearColor, 1);
            renderer.clear();
            if (starUniforms.uAlpha.value > 0.006) renderer.render(starScene, starCamera);
            renderer.render(scene, camera);
            frame = requestAnimationFrame(tick);
        };
        frame = requestAnimationFrame(tick);

        return () => {
            cancelAnimationFrame(frame);
            observer.disconnect();
            sceneRef.current = null;
            geometry.dispose();
            starGeometry.dispose();
            material.dispose();
            bloomMaterial.dispose();
            starMaterial.dispose();
            dotTexture.dispose();
            coverTexture.dispose();
            previousTexture.dispose();
            renderer.dispose();
            renderer.domElement.remove();
            lyricHost.replaceChildren();
        };
    }, []);

    useEffect(() => {
        sceneRef.current?.setPreset(props.preset);
    }, [props.preset]);

    useEffect(() => {
        sceneRef.current?.setCover(props.cover);
    }, [props.cover]);

    useEffect(() => {
        sceneRef.current?.setColors(props.backgroundColor, props.accentColor);
    }, [props.backgroundColor, props.accentColor]);

    return (
        <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', background: props.backgroundColor }}>
            <style>{LYRIC_STYLE}</style>
            <div ref={hostRef} style={{ position: 'absolute', inset: 0 }} />
            <div ref={lyricRef} className="mr-lyrics" style={{ ['--mr-glow' as string]: `${props.accentColor}99` }} />
        </div>
    );
};

export default MineradioView;
