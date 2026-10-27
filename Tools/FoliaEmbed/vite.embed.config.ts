// 用 Folia 自己的 vite 配置打包内嵌页面：只换入口、去掉 PWA，产物用相对路径；另外加上 AMLL 需要的别名
import { fileURLToPath } from 'node:url';
import type { ConfigEnv, UserConfig } from 'vite';
import foliaConfig from './vite.config.ts';

export default async function embedConfig(env: ConfigEnv): Promise<UserConfig> {
    const base = await foliaConfig(env);
    const plugins = (base.plugins ?? []).flat().filter((plugin: any) => {
        const name: string = plugin?.name ?? '';
        return !name.startsWith('vite-plugin-pwa') && name !== 'folia-dev-lyric-proxy';
    });
    const pixiStub = fileURLToPath(new URL('./embed/pixiStub.ts', import.meta.url));
    const pixiPackages = ['app', 'core', 'display', 'sprite', 'filter-blur', 'filter-bulge-pinch', 'filter-color-matrix'];
    const baseAlias = base.resolve?.alias;
    const alias = [
        ...(Array.isArray(baseAlias)
            ? baseAlias
            : Object.entries(baseAlias ?? {}).map(([find, replacement]) => ({ find, replacement: String(replacement) }))),
        // AMLL 的 Pixi 背景用不到，换成空实现（见 embed/pixiStub.ts）
        ...pixiPackages.map(name => ({ find: `@pixi/${name}`, replacement: pixiStub })),
    ];
    return {
        ...base,
        base: './',
        publicDir: false,
        plugins,
        resolve: { ...base.resolve, alias },
        build: {
            ...base.build,
            outDir: 'dist-embed',
            emptyOutDir: true,
            sourcemap: false,
            reportCompressedSize: false,
            chunkSizeWarningLimit: 4000,
            rollupOptions: {
                ...base.build?.rollupOptions,
                input: { index: 'folia-embed.html' },
            },
        },
    };
}
