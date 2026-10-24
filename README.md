# 旅行素材管家 · Travel Media Manager

**按旅行日期和城市，把照片与视频整理到一个文件夹。**

旅行几天、去了几个地方，回来后连接 iPhone，选择日期和城市，就能把这次旅行的素材复制到 Mac 或外置硬盘。也支持从相机存储卡和普通文件夹归档。原文件保持不变。

[English](README.en.md) · [安装说明](docs/INSTALL.md) · [使用说明](docs/USER_GUIDE.md) · [隐私说明](docs/PRIVACY.md) · [参与改进](CONTRIBUTING.md)

![旅行素材归档流程示意](assets/demo.svg)

*上图是流程示意，使用虚构示例，不是实机截图。*

[查看实际应用界面](assets/app-preview.png)（虚构旅行名称，未连接或扫描设备）。

## 当前版本与获取方式

**0.3.0（build 9）社区预览。** 归档核心延续 build 8，公开版本更新应用标识和发布资料。既有本地回归及有限真机检查不代表所有机型、图库或系统版本都已验证。

请查看 [Releases 下载页](https://github.com/waton1990/travel-media-manager/releases)获取实际发布的文件、版本说明和校验值。只有标明为应用安装包的附件才是可运行软件；GitHub 自动提供的 Source code 压缩包是源码，需要自行构建。没有应用附件时，可按下方说明从源码构建。测试包下载、安装与首次打开步骤见[安装说明](docs/INSTALL.md)。

当前已有应用包面向 **Apple Silicon Mac（M 系列）**，采用本地临时签名，尚未完成 Developer ID 签名或 Apple 公证。源码声明最低 macOS 13，但较早 macOS 与 Intel Mac 尚未完成运行验证。当前应用界面为简体中文，英文文档不代表已有英文界面。

## 可以做什么

| 来源 | 筛选与保存 |
| --- | --- |
| iPhone · USB 数据线 | 读取手机索引中明确标记为“由我拍摄”的本机照片和视频，按旅行日期筛选，再勾选城市／地区；“位置未知”可逐项选择 |
| 相机卡／普通文件夹 | 递归扫描支持的照片、视频和音频，按拍摄日期归档，忽略 LRF 等辅助文件 |

- 一次旅行保存到一个 `开始日期_旅行名称` 文件夹，不按城市或日期拆开。
- 来源文件夹和保存位置通过系统窗口选择，不用手写路径。
- 实况照片默认保留静态照片和配套短视频，也可选择仅静态照片；独立拍摄的视频正常导入。
- iPhone 先统一复制，再统一本地校验；完整实况照片额外核对照片和视频的配对标识。
- 保留原文件名，不覆盖已有文件，不修改、移动或删除源文件。

## 快速开始

1. 填写旅行名称、起止日期；iPhone 来源同时核对旅行拍摄时区。
2. 选择来源和保存位置。使用 iPhone 时，先退出 iPhone 镜像，接线、解锁并信任 Mac。
3. 点击“扫描素材”。iPhone 扫描完成后，勾选城市／地区和需要的未知位置素材。
4. 选择完整实况或仅静态照片，核对素材数、实际文件数和空间。
5. 点击“开始归档”，保持设备连接，等待复制与校验完成，再打开结果文件夹。

扫描与预览阶段不复制原片，也不创建旅行目录。完整操作及常见提示见[使用说明](docs/USER_GUIDE.md)。

## 数据与隐私

照片、视频通过 USB 或本地文件系统复制，**不通过 iCloud 导入**。城市优先使用手机已有的有效信息；缺失时会通过 Apple 的系统地理编码服务补查，将照片坐标发送给 Apple，不上传照片或视频内容。

iPhone 扫描会把照片索引快照读到 Mac 的临时目录，再在本机按日期和分类筛选；索引可能包含所选日期以外的元数据。因此，选择三天并不意味着只传输三天的索引。详见[隐私说明](docs/PRIVACY.md)。

## 当前边界

- iPhone 分类、城市和资源关联依赖当前可识别的内部索引格式，可能随 iOS 更新变化；无法可靠识别时会提示或停止。
- 仅在 iCloud 中、手机本地无法读取的原件不会自动下载。
- iPhone 来源不读取语音备忘录、独立音频、隐藏或已删除项目，不重建相册、收藏和编辑历史。
- 目前只支持已识别的实况资源组合；仅静态模式不会绕过资源缺失或关联异常。
- 不支持断点续传、向已有旅行目录追加、自动去重或自动重命名。遇到同名冲突需要调整选择。
- 普通城市按组选择；未知位置可逐项选择。未知列表显示文件名、日期和类型，尚无缩略图预览。
- 这是一款 macOS 应用，没有 Windows、iOS App 或商店上架版本。

## 从源码构建

需要 Apple Silicon Mac、macOS 开发工具链，以及可创建 Python 3.12 环境的 [uv](https://docs.astral.sh/uv/getting-started/installation/)。核心测试使用 Swift Testing，需要提供该框架的 Xcode 或 Command Line Tools。项目的 Swift tools 声明不等于测试工具链的最低版本保证。

在仓库根目录运行：

```sh
bash scripts/build-app.sh
```

构建结果为 `outputs/旅行素材管家.app`。脚本将按锁定版本安装 USB 依赖并打包运行库，首次构建需要联网。完成后的应用无需使用者另外安装 Python 或 uv。

仅编译 Swift 应用目标：

```sh
swift build --product TravelMediaManager
```

该命令不打包 USB 组件；完整 iPhone 功能请使用上面的应用构建脚本。

## 测试

以下检查使用合成数据或内存模拟，不需要连接手机：

```sh
bash scripts/test.sh
python3 -m unittest discover -s Tests/USBHelperTests -v
bash scripts/test-app-model.sh
bash scripts/test-place-resolution.sh
```

build 9 公开源码已在本地重新通过 95 项核心测试、127 项 USB 组件测试、53 项 AppModel 检查和 25 项城市整理检查。测试包构建、启动及 USB 离线自检通过。上述检查不访问真实设备；结果不等于所有系统版本的兼容承诺。GitHub 自动测试的运行状态以 Actions 页面为准。

## 反馈、贡献与后续计划

通过本仓库的 [Issues](https://github.com/waton1990/travel-media-manager/issues) 反馈问题或提出需求。请描述系统版本、设备型号、操作步骤和错误文字，**不要上传私人照片、照片索引、完整设备标识或未脱敏日志**。

提交代码前请阅读[贡献说明](CONTRIBUTING.md)。候选改进见[后续计划](docs/ROADMAP.md)，历史功能变化见[更新记录](CHANGELOG.md)。

## 许可证

本项目原创代码采用 **GNU GPL v3.0 或后续版本（GPL-3.0-or-later）**，详见 [LICENSE](LICENSE)。第三方依赖保留各自的许可证和版权声明；开源不改变它们的要求。软件按许可证提供，不附带适用性保证。
