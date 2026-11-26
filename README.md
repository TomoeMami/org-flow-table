# org-flow-table

在普通 Org buffer 中把 Org 表格渲染为像素对齐、响应式的控件（widget）。它只依赖
Emacs 和 Org：单元格用 `window-text-pixel-size` 测量、由本包自行布局、用 overlay 绘制。

## 上游项目

本项目的前身是 `org-table-widget`（原作者 [yibie](https://github.com/yibie)），
早期基于 [TextUI](https://github.com/yibie/textui) 实现表格的像素布局。

## 改名原因

0.4.0 起本包彻底移除了 TextUI 依赖，改为基于 Emacs 自身的
`window-text-pixel-size` 与 overlay 自行测量和布局，不再是一个「TextUI widget」。
旧名 `org-table-widget` 沿用上游名称、其仓库路径在上游并不存在，容易引起混淆；
新名 `org-flow-table` 更能反映其响应式换行与回流（reflow）的布局方式。

## 与上游项目的主要差异

- **移除 TextUI 依赖**：`Package-Requires` 仅列出 Emacs（29.1+）与 Org（9.6+），
  无需安装、克隆任何第三方库，也无需向 `load-path` 添加额外路径。
- **保留 Org 源表格原貌**：渲染为 `| cell | cell |` 行与 `|---+---|` 分隔线，
  表头加粗、整行斑马纹，不再绘制外框与 Unicode 制表符。
- **逐行渲染、原地编辑**：每一行用独立 overlay 渲染，point 所在行保留为源文本，
  可直接原地编辑，无需先按键；其余行保持渲染，编辑不会展开整张表。
- **吸顶表头与终端渲染**：新增滚动时吸顶表头，以及可选的终端渲染
  （`org-flow-table-enable-in-terminal`）。
- **全部公开命名改为 `org-flow-table-` 前缀**：库名、模式、命令、选项与 face
  统一前缀，旧名不作别名保留。

## 安装方式

尚未上 MELPA。用 `package-vc` 安装：

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/TomoeMami/org-flow-table" "v0.4.0")
```

或克隆仓库后手动加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/org-flow-table")
(require 'org-flow-table)
```
