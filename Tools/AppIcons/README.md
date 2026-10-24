# 应用图标

10 款图标由同一套规则生成（`astra_icon.py` 是几何和配色规则，`styles.py` 是各款的材质和颜色）。

```bash
pip install numpy scipy pillow playwright
python3 export_styles.py <输出目录>     # 生成 png/（1024 满版）、preview/、svg/ 和 overview.png
```

生成后放进 `Resources/Assets.xcassets`：

| 编号 | 名称 | 风格键 | 资源 |
|---|---|---|---|
| 01 | 多彩 | chroma | AppIcon-chroma |
| 02 | 柔光（默认） | glow | AppIcon |
| 03 | 糖纸 | sticker | AppIcon-sticker |
| 04 | 蓝图 | blueprint | AppIcon-blueprint |
| 05 | 白 | white | AppIcon-white |
| 06 | 黑 | black | AppIcon-black |
| 07 | 黑金 | gold | AppIcon-gold |
| 08 | 克莱因橙 | klein | AppIcon-klein |
| 09 | 柠檬紫 | lemon | AppIcon-lemon |
| 10 | 红黄 | redyellow | AppIcon-redyellow |

设置页的预览图是 `IconPreview-<风格键>`（240px，同一张图缩小）。新增一款时在 `Sources/Views/AppIconPicker.swift` 的 `AppIconOption` 里加上对应的 case。
