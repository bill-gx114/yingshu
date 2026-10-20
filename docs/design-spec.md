# 映述设计规范

目标：导入一次出游的素材，边看边说出感想，稍作修改即可导出带个人文字与轻音乐的短片。

0.7增量：小人气泡采用原创黏土旅行者，奶油帽/小背包、珊瑚外套、鼠尾草背带、深绿鞋。角色实际约画高10%，落在左下区域，与气泡一起参与避让。文字气泡使用暖白、深绿灰字、低强度阴影，约0.22秒轻弹，人物1.2秒轻柔侧转后静止。没有发声或嘴型，动作随媒体时间而非界面挂载时间驱动。

曲库结果每行并列“试听片段”与“下载并使用”，分别表达临时听取和保存采用。准备状态可取消，播放状态可停止；曲库折叠区外保留独立的停止/取消入口。错误在原位置说明并保留来源链接。试听不改变已选配乐或影片时间轴。

## 视觉与布局

- 暖白工作区、深炭色影院、珊瑚红口述主操作。配色安静，让照片、视频与用户自己的文字成为主角。
- 三栏编辑器：左侧 198 pt 素材篮，中央预览与口述区，右侧 280 pt 感想面板。主窗口在约 1280 × 800 下应保留可辨认的大画面和完整口述控件。
- 顶栏高度 65 pt，底栏 30 pt，片段条固定 142 pt。片段缩略图固定 107 × 61 pt；进度指示在 overlay 中绘制，不参与布局测量。
- 中文采用系统字体。实时转写与编辑文字 12–13 pt，口述主按钮 14 pt；辅助数字和短标签 9–11 pt。长文件名截取中部，完整名称可悬停查看。
- 使用低强度边界、圆角和局部留白。避免同时陈列功能说明、工程状态与多层重复引导。

## 主流程

1. 素材栏与空状态突出“从相册选择”（系统PhotosPicker，保留完整实况），另提供“从文件导入”和“先试一下”。三步提示概括导入、口述、导出。
2. 用户点击片段或播放画面，按 R 开始口述。主按钮同时显示麦克风/停止图标、状态文字和 R 提示。
3. 录制胶囊右侧菜单选择新感想样式：字幕、贴纸、手记、小人气泡（无声）。四种样式编辑选择使用2×2排列，避免窄栏挤压。录制过程中禁用样式、跳转和结构编辑。
4. 开始口述自动冻结画面与配乐，录制时提供音量反馈与“R 结束后继续播放”。独立AI模式在结束后整句识别整理，等待阶段显示真实状态和取消入口，不显示伪造的逐字转写；系统识别模式可显示实时文字。处理后从同一播放位置续播。
5. 右侧直接显示当前片段的感想。仅选中句展开文字编辑与样式；“显示时间”默认折叠，展开后可改起点、持续时间或选择整段显示。
6. 素材行始终显示独立移除按钮，右键和 Delete 同样可移除，提示原文件保留。片段设置默认折叠，包含照片停留/视频裁剪、前移、后移。配乐面板下提供智能编排开关、重新编排、进度与取消；手调片段显示锁定及恢复自动。
7. 导出时影院内显示进度与取消按钮。文件写入成功后显示“短片已保存”卡片，可立即播放、查看文件或关闭提示。
8. 素材篮导入按钮下放“素材顺序”选择器：拍摄时间、智能叙事、文件名、导入顺序、手动顺序。默认时序；智能叙事需要主动选择。排序过程在原位置显示步骤、百分比和可用的取消入口，不改变中央预览布局。
9. 已验证配对的实况素材在素材行、片段条和当前预览轻量标“实况”，本质播放MOV动态部分；单张HEIC不显示已配对徽标。前移/后移片段自动切为手动顺序，顺序修改可撤销。
10. 预览字幕/贴纸/手记按共享渲染层的真实frame命中，不拦截画面空白；悬停出现细框和“点击修改”提示。点击打开简洁编辑sheet，完成/取消明确。录制中先安全收尾，再编辑最终文字；编辑时保持暂停。错误输入在编辑器内提示，不弹第二个modal。
11. 静态导入与部分导入结果在素材栏汇总成一条可展开提示，可查看详情/清除；不逐张弹“操作未完成”。相册加载显示独立取消按钮及当前阶段，iCloud选中资源可能需联网下载。

## 预览与文字一致性

- 图片与视频等比完整展示，画幅不同的部分留黑。NSImageView 不使用原图固有尺寸参与 SwiftUI 布局，三个原生承载视图均按画布实际尺寸布局。
- 字幕预览调用 `MediaEngine.renderedCaptions`，与导出共用样式、字形、定位和重叠避让规则。父 CALayer 使用输出画布尺寸，锚点置零，再统一缩放。
- 片段移动后，感想跟随片段；删除片段同时删除所属感想。
- 口述用于生成文字，成片保留画面、文字与所选配乐。素材原声静音。

## 反馈与权限

- 空闲、准备语音、画面暂停录制、整理后续播、语音检查、智能编排、导出中使用明确可区分的文案。
- 项目自动恢复通过状态栏反馈，不遮挡继续工作。权限拒绝、无识别结果、缺失素材与导出失败保留真实错误内容。
- 恢复副本具有尚未保存、等待写入、已保存、失败和未启用五类状态，只有写入成功才显示勾号。失败在原位置用珊瑚色显示并提供重试；悬停显示写入时间或错误。它与 ⌘S 的项目文件保存分别命名。
- 标题旁用小圆点表示命名项目文件仍有修改；标题和保存按钮的悬停文本说明当前路径。⌘S 续存原文件，⇧⌘S 另存，重新打开应用后保留命名文件位置。
- 缺失文件提示放在工作区预览上方；关联 sheet 列出名称、类型、可复制路径与逐项选择入口。核验中冻结关联操作；错误显示在 sheet 内。实况同时选择原照片和 MOV，错误配对或视频范围不足均不改变项目。重新检查与完成保持可发现。
- 打开保存的项目接受已有时间轴；只有后续素材、文字或配乐变化才触发新的节奏检查。重新关联和撤销保留现有创作安排。
- 口述提示右侧的“更多”菜单提供“检查语音识别…”，用于用已知语音文件验证识别链路；不会自动开始麦克风录制。
- 语音服务状态可在录制提示上悬停查看。R、空格与方向键在文本编辑时优先用于输入，不应触发全局剪辑命令。
- 项目保存文件引用；素材保留原位，跨机器携带时需同时带上原素材。该说明放在保存流程与帮助中，主界面仅保留简短提醒。

## 无障碍与自动化标识

所有主要控件具有中文 label；仅图标按钮另外提供 `accessibilityLabel`。稳定标识按功能分组，片段与感想使用 UUID 后缀：

| 区域 | 主要标识 |
| --- | --- |
| 项目 | `project.title`、`project.new`、`project.open`、`project.save`、`project.export` |
| 导入 | `media.import`、`empty.import`、`empty.demo`、`media.remove.UUID` |
| 相册与提示 | `media.photos`、`empty.photos`、`import.photos.cancel`、`import.photos.progress`、`import.summary`、`import.details`、`import.clear` |
| 画面文字编辑 | `preview.caption.UUID`、`captionEditor.sheet`、`captionEditor.text`、`captionEditor.issue`、`captionEditor.save`、`captionEditor.cancel` |
| 顺序 | `order.mode`、`order.reapply`、`order.summary`、`order.progress`、`order.cancel` |
| 预览 | `preview.format`、`preview.canvas`、`playback.seek`、`playback.back`、`playback.toggle` |
| 口述 | `capture.toggle`、`capture.style`、`capture.transcript`、`capture.status`、`capture.more`、`capture.checkSpeech` |
| 感想 | `caption.add`、`caption.add.inspector`、`caption.text.UUID`、`caption.style.UUID`、`caption.timing.UUID`、`caption.start.UUID`、`caption.duration.UUID`、`caption.fill.UUID`、`caption.preview.UUID`、`caption.delete.UUID` |
| 片段 | `media.clip.UUID`、`timeline.clip.UUID`、`clip.settings`、`clip.duration.UUID`、`clip.trimStart.UUID`、`clip.moveEarlier.UUID`、`clip.moveLater.UUID`、`clip.delete.UUID` |
| 配乐 | `music.selection`、`music.volume`、`music.custom` |
| 编排 | `autoEdit.enabled`、`autoEdit.arrange`、`autoEdit.progress`、`autoEdit.cancel`、`autoEdit.summary` |
| 导出 | `export.progress`、`export.cancel`、`export.success`、`export.success.play`、`export.success.reveal`、`export.success.dismiss` |
| 反馈 | `status.message`、`error.dismiss` |
| 保存状态 | `project.unsaved`、`recovery.state`、`recovery.message`、`recovery.retry` |
| 素材修复 | `assets.banner`、`assets.manage`、`assets.sheet`、`assets.list`、`assets.path.ID`、`assets.locate.ID`、`assets.issue`、`assets.progress`、`assets.refresh`、`assets.done`、`assets.complete` |

## 界面验收

- 在约 1280 × 800 窗口分别检查空项目、有素材、长中文感想、录制/整理、导出进度与成功反馈。
- 海岸示例必须同时看到完整天空、太阳与岸线；切换横屏、竖屏、方形仍应完整 fit。
- 选中/播放任意片段时，片段条高度保持 142 pt，不挤压主预览。
- 长中文文件名、长感想和多句列表不会撑宽右栏；右栏可以滚动，主操作不随右栏滚动。
- 正在录制与整理时，跳转、片段结构及项目变更均不可用；文本输入仍能正常接收拼音和空格。
- 导出失败或取消时不显示成功卡；再次成功保存到同一路径仍应显示成功反馈。
