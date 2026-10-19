# 展示素材来源

本目录是随仓库保存的静态产品介绍，不依赖外部 CDN、字体、网络服务或 API。直接打开 `index.html`，或通过普通静态文件服务预览。Markdown 文档链接在 GitHub 仓库页面可读，本地浏览器的 Markdown 展示取决于浏览器。

| 素材 | 来源与边界 |
| --- | --- |
| `images/editor.png` | 原样复制 `Tests/output/product-preview-1280x800.png`。由 `Tests/RenderChecks.swift` 渲染真实应用视图；使用 `Resources/demo-coast.png`、`demo-hills.png`、`demo-evening.png` 与预置文字，未读取用户项目、照片、桌面或麦克风。界面图片不证明实际语音识别准确率。 |
| `images/companion.png` | 原样复制 `Tests/output/companion-landscape-1280x800.png`。同一套离屏渲染链路、原创示例插画与无声小人气泡。角色无发声、无嘴型。 |
| `hero.svg` | 为项目创作的矢量产品封面。海岸与口述条属于概念示意，封面内已标明并非应用截图。 |
| `hero.png`、`workflow.png`、`architecture.png` | 对应 SVG 通过系统 WebKit 原样栅格化的展示副本，使仓库页面中的中文排版一致；保留 SVG 作为可缩放源文件。 |
| `workflow.svg` | 依据 `docs/design-spec.md` 与 `docs/本地AI说明.md` 绘制的主流程图。 |
| `architecture.svg` | 依据本地 AI 说明绘制的数据路径图；仅聚焦本地 AI 模式，不把 Apple 系统服务、iCloud 下载或联网曲库涵盖为离线能力。 |

网页中的 R 交互只是状态演示：画面与文字均为预置示例，不访问麦克风，不调用模型，不模拟识别准确率。整理中状态由点击推进，无伪造网络处理或测试成功反馈。

视觉延续 `docs/design-spec.md`：暖白真实编辑器、深炭色影院外框、珊瑚红口述焦点。中文使用系统字体回退，未引入外部字体；支持窄屏、键盘操作与减少动态效果偏好。
