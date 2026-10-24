# 第三方组件与源码获取

旅行素材管家的原创源码和文档按 **GPL-3.0-or-later** 发布，完整条款见 [LICENSE](LICENSE)。第三方组件保留各自版权和许可证；本项目不会将它们统一改为 GPL。

## 获取源码和许可证

- 本项目源码：当前仓库中与发行版对应的 Git 标签，包括 `Sources/`、`scripts/`、`Tests/` 和构建配置。
- Python 依赖源码：在同一 [GitHub Release](https://github.com/waton1990/travel-media-manager/releases) 下载 `python-dependency-sources.tar.gz`。其中包含锁定版本的 101 个上游源码归档和逐项 SHA-256、原始下载地址、许可证元数据清单。
- cryptography 的 Rust 依赖源码：同一 Release 提供 `cryptography-rust-sources.tar.gz`，包含其 Cargo.lock 固定的 32 个 registry crate；摘要与锁文件一致，许可文本随包保留。
- 构建版本固定在 [scripts/usb-helper-requirements.lock](scripts/usb-helper-requirements.lock)。下载归档的方法见 [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)。
- 上游原始许可文本保存在 [third-party/notices](third-party/notices)，从相同版本源码补充的文本保存在 [third-party/source-notices](third-party/source-notices)。原生运行库通知见 [third-party/native-notices](third-party/native-notices)。

以上源码提供方式适用于随同本项目发行的对应版本。发布应用二进制时，应同时提供本项目源码与这些依赖源码及 Rust 源码合集；仅链接上游项目首页不替代对应源码交付。宽松许可证组件主要按各自条款保留版权和通知，并非所有依赖都要求交付源码。

## 主要组件

| 组件 | 本次固定版本 | 用途 | 许可说明 |
| --- | --- | --- | --- |
| pymobiledevice3 | 11.32.0 | USB 设备发现、连接和 AFC 读取 | GPL-3.0-or-later |
| ioregistry | 0.0.6 | USB/系统设备信息 | 上游 GPL v3 文本及元数据 |
| pygnuutils | 0.1.1 | 手机读取组件的间接依赖 | 上游 GPL v3 文本 |
| certifi | 2026.7.22 | CA 根证书数据 | MPL-2.0 |
| tqdm | 4.70.1 | 间接依赖 | MPL-2.0 与 MIT，按上游文件声明 |
| Pillow | 12.3.0 | 间接图像支持及其原生库 | MIT-CMU；随包库各自许可见完整 Pillow 通知 |
| cryptography | 50.0.2 | 连接加密支持 | Apache-2.0 或 BSD-3-Clause；OpenSSL 单独列明 |
| PyInstaller | 6.16.0 | 构建 USB 组件 | GPL v2 或后续版本，附构建产物例外；个别文件 Apache-2.0 |
| CPython | 3.12.14 | 内置 Python 运行库 | PSF 与其组成部分的许可证 |

PyInstaller 的例外适用于其构建产物，并不豁免被打包依赖自身的许可条件。原始 PyInstaller 例外文本随通知保存。

`dependencies.json` 是 101 个构建环境分发包的超集清单，不表示每个包都在程序运行时加载。`bundled-python-inventory.json` 记录既有打包分析匹配的 36 个分发包，是核对依据，不替代逐项二进制检查。源代码归档保留超集，有助于重新构建和核查。

## 保留上游声明

This software is based in part on the work of the Independent JPEG Group.

This software uses the FreeType Project. Its copyright notices and license are reproduced in `third-party/notices/pillow/LICENSE`.

Pillow 的 wheel 随包许可证比源码包的顶层许可证更完整；两者分别保留，不用较短源码文本替换原生库通知。某些包的元数据与许可文件表述不一致（例如 `remotezip2`），两者原样保留；这些表述不构成本项目对上游重新授权。
