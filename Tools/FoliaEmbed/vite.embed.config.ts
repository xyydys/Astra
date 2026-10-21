// 用 Folia 自己的 vite 配置打包内嵌页面：只换入口、去掉 PWA，产物用相对路径
import type { ConfigEnv, UserConfig } from 'vite';
import foliaConfig from './vite.config.ts';

export default async function embedConfig(env: ConfigEnv): Promise<UserConfig> {
    const base = await foliaConfig(env);
    const plugins = (base.plugins ?? []).flat().filter((plugin: any) => {
        const name: string = plugin?.name ?? '';
        return !name.startsWith('vite-plugin-pwa') && name !== 'folia-dev-lyric-proxy';
    });
    return {
        ...base,
        base: './',
        publicDir: false,
        plugins,
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
