# 第三方组件 / Third-Party Notices

LiteMD 本体以 MIT 许可证发布，详见 [LICENSE](LICENSE)。应用里还包含下列第三方组件，各自遵循原有的许可证。

LiteMD itself is released under the MIT License (see [LICENSE](LICENSE)). The application also includes the following third-party components, each under its own license.

| 组件 / Component | 用途 / Used for | 许可证 / License | 许可证文件 / License file |
| --- | --- | --- | --- |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown 解析（CommonMark + GFM） | Apache-2.0 with Runtime Library Exception | 见上游仓库 / upstream repository |
| [KaTeX](https://github.com/KaTeX/KaTeX) | 预览里的数学公式 | MIT | [katex/LICENSE.txt](Apps/macOS/LiteMD/Resources/PreviewLibraries/katex/LICENSE.txt) |
| [highlight.js](https://github.com/highlightjs/highlight.js) | 预览里的代码高亮 | BSD-3-Clause | [highlight/LICENSE.txt](Apps/macOS/LiteMD/Resources/PreviewLibraries/highlight/LICENSE.txt) |
| [Mermaid](https://github.com/mermaid-js/mermaid) | 预览里的图表 | MIT | [mermaid/LICENSE.txt](Apps/macOS/LiteMD/Resources/PreviewLibraries/mermaid/LICENSE.txt) |
| [Philosopher](https://github.com/alexeiva/philosopher) | 品牌字标 “LiteMD” | SIL Open Font License 1.1 | [Fonts/OFL.txt](Apps/macOS/LiteMD/Resources/Fonts/OFL.txt) |

KaTeX、highlight.js 与 Mermaid 随应用一起打包，预览在完全离线的情况下也能渲染，运行时不会请求任何外部地址。

KaTeX, highlight.js and Mermaid are bundled with the app so that previews render fully offline; nothing is fetched at runtime.
