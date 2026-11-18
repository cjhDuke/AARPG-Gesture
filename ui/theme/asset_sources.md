# UI 主题素材来源

- `ui_icons.png`：使用 Kibyra 素材包的 `icons3.png`，256×256。下载及安装步骤见 [源码运行说明](../../README.md#开发)。其他模块通过 AtlasTexture 自行选区，保持最近邻、原生像素或整数倍尺寸。
- 作者 Kibyra；许可依据同目录 `Readme.txt`：允许个人及商业使用，署名可选但欢迎；禁止将原文件直接再分发或转售，禁止冒充原创重新上传素材包。发布游戏时按游戏资源使用，勿另行分发原始素材包。
- `../fonts/dungeon_font.ttf`：使用 vrtxrry 发布的 DungeonFont，许可见 [第三方素材与许可](../../THIRD_PARTY_NOTICES.md)。
- `panel.png`、`selected.png`、`hover.png`、`pressed.png`、`disabled.png` 是本项目按已批准方向程序绘制的 16×16 原生像素九宫格；纹理边距 7，禁止线性过滤。

## 字体设置

标题使用 `ui/fonts/dungeon_font.ttf`（DungeonFont）；导入关闭抗锯齿、hinting、subpixel 和 mipmaps，oversampling=1。正文使用项目既有 `ui/fonts/abaddon_light.ttf`（Abaddon），主题默认 12px，按钮 14px。两款字体均无中文字形，游戏文案保持英文。
