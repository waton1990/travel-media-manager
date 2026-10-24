# 依赖、许可与可重建来源

## 依赖范围

Swift 应用使用 macOS 系统框架；本仓库没有打包 Apple 系统框架的副本。iPhone 读取组件由项目自己的 Python 代码与锁定依赖构建，打包后用户不需要另装 Python。

- 主要 USB 库：`pymobiledevice3==11.32.0`。
- 完整构建锁文件：`scripts/usb-helper-requirements.lock`，共 101 个分发包。
- 构建环境许可清单：`third-party/notices/dependencies.json`。
- 逐项源码与摘要：`third-party/python-source-manifest.json`。
- cryptography 的 Rust crate 来源与摘要：`third-party/cryptography-rust-source-manifest.json`，共 32 个固定版本。
- 主要 copyleft 包安装源码与上游 sdist 的比较记录：`third-party/copyleft-source-verification.json`。
- 既有 PyInstaller 分析清单：`third-party/bundled-python-inventory.json`。其 36 个分发包匹配结果只针对本次组件构建，升级后应重新核对。

本项目没有修改这些上游 Python 分发包的源码。项目的读取限制、数据解析、日期筛选和复制校验代码在自己的源码文件中维护。

## 下载固定版本的依赖源码

使用 Python 3.9 或更新版本，在仓库目录执行：

```sh
python3 scripts/prepare-source-bundle.py --output work/dependency-sources
```

脚本从官方 PyPI 获取锁文件中每个精确版本的 source distribution，按 PyPI 公布的 SHA-256 验证后保存。它不会安装或执行下载的代码，不访问 iPhone，也不读取照片。生成：

- `source-archives/`：原始源码压缩包。
- `python-source-manifest.json`：包名、版本、来源和摘要。
- `python-dependency-sources.tar.gz`：可随 Release 分发的依赖源码合集。
- `python-dependency-sources.tar.gz.sha256`：合集摘要。

如果任何版本缺少源码或摘要不匹配，脚本报告失败。它只检查 Python 源码归档，不会据此自动判定一个新二进制已满足全部许可要求。

## 构建与重新发布

应用构建步骤见主 README。第三方依赖的源码归档保留其原始构建文件；项目自己的 `scripts/build-usb-helper.sh` 和 `scripts/build-app.sh` 记录组装步骤。对第三方原生库重新编译时，还需要对应上游工具链和文档，不能把 Python lockfile 当作所有原生构建环境的完整描述。

发布每个包含 USB 组件的二进制时：

1. 保存准确的源代码标签、依赖版本、运行库版本及构建脚本。
2. 把本项目 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md` 和 `third-party/` 通知集合与应用一起提供。
3. 在相同 Release 中提供应用对应的本项目源码、`python-dependency-sources.tar.gz` 及 `cryptography-rust-sources.tar.gz`；更新后重新生成清单及 SHA-256。
4. 核对新 wheel 是否加入其他原生库，保留它们要求的许可证、版权与 NOTICE；不能只依据 Python 包的顶层 SPDX 标签。
5. 对 GPL/LGPL/MPL 等组件按实际许可证履行源码、修改通知及替换/重建等适用义务。当前归档包含原始固定版本源码，项目没有另行限制用户依许可证复制、修改或再分发这些组件的权利。

## 当前原生运行库

本次核对的构建运行库为 CPython 3.12.14，通知按相同版本的 python-build-standalone 20260901 Apple Silicon 发行归档补充。该上游归档已按 GitHub 公布的 SHA-256 核验；记录的是通知来源，不声称本地已重定位／签名的运行库与上游二进制逐字节相同。Python 的 SSL 为 OpenSSL 3.5.8，cryptography wheel 内的 SSL 为 OpenSSL 4.0.3；它们属于不同打包部分，通知分别保留。

Pillow 的完整 wheel 许可文件涵盖其所带的 AOM、Brotli、FreeType、HarfBuzz、Little CMS、libavif、JPEG、LZMA、PNG、TIFF、WebP、OpenJPEG、Xau/Xcb 和 zlib 等通知。原生库以实际分发的 wheel 内容为准，不能仅凭应用自身未直接调用某项功能而省略其打包材料。

cryptography 的 Rust 源码合集来自其 50.0.2 sdist 内的 `Cargo.lock`。所有 32 个 registry crate 均从 crates.io 下载，并按锁文件中的 SHA-256 核验；它是包含测试和平台依赖的超集，各 crate 的许可原文保存在 `third-party/native-notices/cryptography-rust/`。上游完整源码与锁文件可用于核对后续构建。

这份记录用于说明当前提供了哪些材料，不是对所有未来依赖版本的自动许可认证。Apple 的签名、公证及安全兼容性测试属于另外的发行步骤。
