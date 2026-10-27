// AMLL 的 PixiRenderer 背景依赖 Pixi v7 的几个包；内嵌页面只用 MeshGradientRenderer，
// 打包时把这些包换成这里的空实现（真的用到时会直接报错，而不是悄悄出问题）
class Unavailable {
    constructor() {
        throw new Error('PixiRenderer 没有打包进 Astra，请改用 MeshGradientRenderer');
    }
}

export const Application = Unavailable;
export const Texture = Unavailable;
export const Container = Unavailable;
export const Sprite = Unavailable;
export const BlurFilter = Unavailable;
export const BulgePinchFilter = Unavailable;
export const ColorMatrixFilter = Unavailable;
export const utils = {};
