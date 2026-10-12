# Codevator 应用图标

使用内置 image_gen 生成。原始透明 PNG 为 `code-elevator-icon.png`，macOS 各尺寸资源位于 `Codevator/Assets.xcassets/AppIcon.appiconset`。保留透明外缘，覆盖 16、32、128、256、512 pt 的 1x/2x 图标。正式应用资源使用由这些 PNG 生成的 `Codevator/AppIcon.icns`，通过 CFBundleIconFile 注册，并在启动时显式加载到 applicationIconImage，避免运行图标为空。

代码符号是视觉中心，电梯门表示编程工作区；左侧导轨、楼层停靠点和上下箭头表示在项目及 worktree 之间切换。深靛蓝衬托青绿色代码与当前楼层。

## 生成提示词

Use case: logo-brand. Asset type: production macOS app icon for Code Elevator, native coding workspace manager. Create ONE polished square 1024x1024 app icon, straight-on view, no mockup, no captions, no letters or words. Core idea: coding is the dominant function; a slim left-side elevator shaft travels between projects/worktrees. Design a premium restrained macOS icon: a dark midnight-indigo rounded-square tile with generous transparent outer margin, softly beveled edges and subtle dimensional finish. Center-right is a large luminous mint/cyan code glyph </> inside a simple elevator cabin frame with two minimal vertical door panels, code symbol clearly foremost and highly legible. Left quarter shows a slim integrated elevator rail with three small floor indicators, one mint illuminated cabin/stop aligned to the middle floor, and tiny upward/downward chevrons conveying traversal. Unify cabin and rail as one compact symbol, avoid visual clutter. Large bold geometric forms, crisp balanced optical spacing, strong contrast, restrained cyan glow, no excessive neon, no tiny text, no building illustration, no people, no gradients outside the icon tile. Transparent canvas outside rounded square. Icon occupies about 84% of canvas with macOS-style rounded corners; beautiful at 32px as well as 1024px. No watermark. Output icon only.
