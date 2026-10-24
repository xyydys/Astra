# Astra

一个用 SwiftUI 写的 iOS 26+ 原生影音阅读应用，界面采用系统液态玻璃风格，把番剧、影视、漫画、小说、音乐放在同一个 App 里。

应用本身不提供任何内容，也不内置片源、采集站、书源或音源，所有来源都由用户自行导入。

## 功能

- **番剧**：Bangumi 首页 / 搜索 / 详情，兼容 Kazumi 规则，多规则并发搜源，系统播放器（画中画、AirPlay）、选集、续播
- **影视**：豆瓣推荐，苹果 CMS 采集站聚合搜索，支持订阅与 TVBox 配置导入，自动去除 m3u8 内插广告
- **漫画**：分区、排行、搜索，条漫滚动与翻页阅读（首次进入需确认已满 18 岁）
- **小说**：兼容「阅读」3.x 书源格式，Swift 重写的规则引擎，TextKit 排版的阅读器
- **音乐**：兼容洛雪音乐自定义音源，多平台聚合搜索，Folia 歌词动画，后台与锁屏控制
- **其他**：收藏与历史、一键备份恢复、8 款可切换的应用图标

## 编译

推送到 GitHub 后，Actions（macos-26 + Xcode 26）会自动编译出未签名的 ipa，在 Actions 页面下载后自签安装即可。手动运行「Build IPA」时可以自定义包名和显示名。

本地有 Mac 的话：

```bash
brew install xcodegen && xcodegen generate
```

然后打开 `Astra.xcodeproj`。

## 致谢

感谢以下开源项目，本应用的实现参考或使用了它们：

- [Kazumi](https://github.com/Predidit/Kazumi)
- [LibreTV](https://github.com/LibreSpark/LibreTV)
- [Venera](https://github.com/venera-app/venera-configs)
- [阅读 Legado](https://github.com/gedoor/legado)
- [洛雪音乐 LX Music](https://github.com/lyswhut/lx-music-desktop)
- [Folia](https://github.com/chthollyphile/folia-major)
- [SwiftSoup](https://github.com/scinfu/SwiftSoup)

## 许可证

[GPL-3.0](LICENSE)。音乐页的歌词动画来自 Folia（AGPL-3.0），`Tools/FoliaEmbed` 中的相关文件同样按 AGPL-3.0 提供。

请只观看、阅读、收听你有权访问的内容。
