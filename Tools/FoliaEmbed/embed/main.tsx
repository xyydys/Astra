// Astra 内嵌的 Folia 歌词动画入口（AGPL-3.0，派生自 folia-major 的 OBS 浏览器源渲染器）
import { Buffer } from 'buffer';
import React from 'react';
import ReactDOM from 'react-dom/client';
import '../src/i18n/config';
import '../src/index.css';
import EmbedApp from './EmbedApp';

// @ts-ignore
globalThis.Buffer = Buffer;

const root = ReactDOM.createRoot(document.getElementById('root')!);
root.render(<EmbedApp />);
