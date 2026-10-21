# 展示素材来源

本目录保存映述的产品介绍与可复现展示素材。图像、字体回退和交互不依赖外部 CDN、账号或 API。下载完整仓库后可以直接打开 `index.html`；GitHub 文件页展示 HTML 源码。

| 素材 | 来源与边界 |
| --- | --- |
| `images/editor.png` | 复制自 `Tests/output/product-preview-1280x800.png`。`Tests/RenderChecks.swift` 离屏渲染真实 SwiftUI 视图，使用三张原创示例插画和预置文字，不读取用户照片、桌面或麦克风。 |
| `my-companion.png` | 复制自 Tests/RenderChecks.swift 的 760 × 660 真实 SwiftUI 编辑器离屏渲染，使用预设个人造型和虚构昵称，展示照片入口，不读取用户照片；这张界面图不代表真人照片转换案例。 |
| `images/companion.png` | 复制自同一套离屏渲染链路的无声小人气泡视图，保留作为界面素材。 |
| `images/caption-*.png` | `scripts/make-showcase-outputs.swift` 调用应用真实的 `CaptionImageExporter.export`，以 `Resources/demo-coast.png` 和同一句预置感想生成字幕、贴纸、手记、小人气泡。每张均为 1920 × 1080。 |
| `images/export-*.png` | 同一导出器用小人气泡生成横屏 1920 × 1080、竖屏 1080 × 1920、方形 1080 × 1080。完整保留应用的等比显示与黑边。 |
| `hero.svg` / `hero.png` | 以真实编辑器视图为主体的产品封面。界面来自真实渲染，内容是预置示例。 |
| `captions.svg` / `captions.png` | 四张实际 PNG 输出的对照排版，图片等比完整显示；文字与角色位置沿用应用结果。 |
| `exports.svg` / `exports.png` | 三个完整输出画幅的对照排版，未裁切黑边或重新放置感想。 |
| `workflow.svg` / `workflow.png` | 依据应用的暂停、口述、落字与续播行为绘制的流程示意。 |
| `architecture.svg` / `architecture.png` | 模型准备完成、未开启可选云端整理时的独立本地 AI 路径。模型下载、曲库、系统语音和 iCloud 的范围分别说明。 |

SVG 是可编辑的排版源，图片以相对路径引用同目录的 `images/`；请保留目录结构。PNG 通过系统 WebKit 栅格化，供 GitHub 稳定显示中文和嵌入图像。两组示例输出与拼版均可重建：

```sh
bash scripts/make-showcase-outputs.sh
python3 scripts/make-showcase-graphics.py
swift scripts/render-showcase.swift
```

命令在仓库根目录执行，需要 macOS 和 Swift 工具链。输出脚本只读取仓库原创画面与角色，将临时导出批次中的七张公开 PNG 复制到本目录，不复制原文索引或文件路径；不会读取用户项目、语音设置、照片库、钥匙串或麦克风。

展示图不能作为语音识别准确率证据。网页中的 R 交互同样只推进固定示例状态，不访问麦克风、不调用模型；“整理中”由点击继续，没有伪造实时识别或成功测试。

视觉延续 `docs/design-spec.md` 的暖白、深绿与珊瑚红；使用系统中文字体。网页支持窄屏、键盘与减少动态效果偏好。
