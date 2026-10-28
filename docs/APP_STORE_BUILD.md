# 商店沙盒候选构建

当前脚本生成供本机验证的沙盒候选包，使用已有的 Developer ID Application 身份。它不创建证书、不上传 App Store Connect，也不能替代商店分发签名、真机验收或 App Review。原有 `scripts/build-app.sh` 继续用于直接分发版本。

## 2026-10-28 构建状态

当前候选及独立商店提交包为 **0.3.2 / build12**。已使用实际商店应用与安装包证书签名，并对 `.pkg` 解包后的实际 payload 完成独立审计：50 个 Mach-O 的精确提交证书、同 Team、主应用/组件/动态库权限、hardened runtime 和安全时间戳均通过；安装包提交证书、指纹、可信时间戳与 Apple 证书链通过。主应用和 USB helper 均为 0.3.2 / build12，隐私清单存在，6701 项文件及符号链接与签名副本一致。包 SHA-256 为 `5342608d0f7c0a21af8e4c5d30b54465e59ed4e1993aaea7b7d3b319b600c2be`。

本轮 332 项现有离线检查通过：97 Core、127 USB、23 Packaging、60 Model、25 Place。日志保存在 `work/store-build12/`；包与独立审计报告位于 `outputs/store-distribution/0.3.2-build12/`，报告文件为 `VALIDATION_REPORT.json`。这批离线检查不替代真机或 App Review 验收。

图标已改为用户批准的浅蓝原稿。用户明确授权使用本地脚本精确处理透明边缘；`scripts/prepare-icon-alpha.py` 只处理 alpha 蒙版并保留原稿 RGB 像素，再由图标构建脚本导出 macOS 尺寸。实际包内 `AppIcon.icns` 与 `packaging/AppIcon.icns` 的 SHA-256 一致：`d6f9b8b1e19e2d59d47dba0b81ebcc086700472eb79746806d14cfb02065b1e5`。

build12 未嵌入 provisioning profile，未安装、上传或提交审核。两张商店截图已上传并保存，后台显示 2/10 张，两项文件名均出现且保存按钮已禁用。GPL 组件按用户选择继续保留，等待明确的商店分发授权结论；本地签名和审计通过不解决该事项。后台资料及截图进度见 `docs/APP_STORE_LISTING.md`。

```sh
TRAVEL_STORE_LOCAL_SIGNING_IDENTITY="你的 Developer ID 身份 SHA-1" bash scripts/build-store-app.sh
python3 scripts/verify-store-app.py "outputs/app-store/旅行素材管家.app"
python3 -m unittest discover -s Tests/StorePackagingTests -v
```

脚本完整重建锁定的 Python 3.12.14 及 USB 依赖，输出到 `outputs/app-store/`，验证成功才替换上一次候选包。正式直接分发输出与已安装应用不受此脚本影响。

本机验证确认，ad-hoc 签名搭配 hardened runtime 时，组件加载 Python 动态库会因团队身份不匹配而失败。因此脚本要求显式指定真实 Developer ID 身份，统一签名主程序、组件及动态库，保留 hardened runtime 和库验证，不添加 `disable-library-validation`。

## 包结构与权限

主应用保留原 bundle ID。USB 组件由 PyInstaller 原生 `BUNDLE` 生成到 `Contents/Helpers/USBHelper.app`，其代码和数据分别位于标准 `Frameworks`、`Resources` 目录。主应用通过 `Process` 启动内嵌可执行文件，继续使用原 stdin/stdout JSON 协议；不会通过 Launch Services 单独启动组件。

- 主应用启用 App Sandbox、用户选择文件夹读写、出站网络和 USB 权限。出站网络用于已有的城市名称补查。
- 组件仅携带 `app-sandbox` 和 `inherit`，继承父应用沙盒；动态库与 Python 扩展不附加进程权限。
- 目前声明一个精确到 `/private/var/run/usbmuxd` 的 `temporary-exception.sbpl` 出站连接规则，用于保持原 USB 读取路径。这是拟提交审核的权限例外，不能将本地生效视为 Apple 支持或审核批准；提交时必须如实说明。
- USB 组件只在容器临时目录写入索引快照，通过管道返回媒体数据；主应用负责向用户选择的归档位置写文件。因此组件不需要获得目标文件夹的动态访问权。
- 主包包含 `PrivacyInfo.xcprivacy`。声明须按实际代码和依赖更新，不能以存在该文件推定隐私审核已通过。

默认主应用权限来自 `packaging/store-app.entitlements`。本地实验可用 `TRAVEL_STORE_APP_ENTITLEMENTS` 显式指定另一份文件，校验器会核对实际签名与该文件完全相同；发布前应审查任何变更。不会自动添加全盘访问、系统服务或额外后台进程。

## 验证范围

校验器检查包标识、必要文件、隐私清单可解析性、所有 Mach-O 的相同 Developer ID 身份、hardened runtime 与时间戳、主程序权限、组件继承权限，以及不离开应用包的符号链接。它会拒绝把组件权限附加到动态库，或把旧组件重复打包到 Resources。

实际沙盒运行需要从图形界面启动候选包，检查本地文件夹扫描与归档、组件启动、USB 索引扫描，以及取消和退出后的连接清理。直接从终端运行组件不能证明沙盒继承正确。复制真机素材时，保持源文件不变并核对导入结果。

### 2026-10-27 本机验收结果

同 Team Developer ID 签名的沙盒候选已完成以下实际运行检查。原始验收记录、照片和设备信息只保存在本地，不进入源码仓库。

- 正式应用界面通过系统文件夹选择器选择源与目标，扫描两份合成照片；日期内一份被复制并通过 SHA-256 校验，日期外一份排除，源文件不变。
- 正式界面通过内嵌组件读取真实 USB 设备，三天范围匹配 7 项“由我拍摄”素材：6 张实况照片和 1 段普通视频。完整模式预览 13 个文件；静态模式预览 7 个文件，仍包含普通视频。7 项均采用手机已有地点名称，没有地理编码网络查询。
- 为严格保持用户授权的两项复制范围，独立签名 GUI 验收程序复用同一生产代码、归档引擎、组件和沙盒权限，通过系统文件夹选择器取得目标访问权，仅选择一张完整实况照片和一段普通视频。复制 3 个文件，共 40,516,057 字节；三份手机原件的复制前后 SHA-256 与目标文件全部一致，实况配对、照片解码和视频/音频完整解码均通过。验收完成后关闭设备连接。
- 此轮真实复制验证完整实况模式；仅静态模式完成正式界面预览和已有自动化检查，未另行扩大手机复制范围。

这证明当时设备上的本地沙盒工作流可运行，不代表其他系统版本兼容性、TestFlight 或 App Review 已通过。上述真机验收对应 0.3.2 / build11，不能自动计作 build12 的真机验收；build12 的本轮构建与静态审计结果见本页开头。

在准备商店上传时，还需使用对应开发者团队的商店分发证书及必要的描述文件，验证最终签名包，填写权限例外说明，并完成 App Store Connect 的产品资料和审核信息。当前本地构建脚本不冒充这一步已经完成。

## 生成独立的商店提交包

`package-store-distribution.py` 从已经通过本地校验的候选包生成独立副本，拒绝覆盖现有输出，也不修改原包或执行上传。先检查输入和本机证书清单：

```sh
python3 scripts/package-store-distribution.py \
  "outputs/app-store/旅行素材管家.app" --check-only
```

准备好 **Apple Distribution / Mac App Distribution** 和 **Mac Installer Distribution** 两个签名身份后，显式传入各自的 SHA-1 指纹及团队 ID：

```sh
python3 scripts/package-store-distribution.py \
  "outputs/app-store/旅行素材管家.app" \
  --output "outputs/store-distribution/0.3.2-build12" \
  --app-identity "应用分发证书 SHA-1" \
  --installer-identity "安装包分发证书 SHA-1" \
  --team-id "团队 ID"
```

需要描述文件时增加 `--profile /绝对路径/Store.provisionprofile`。脚本只接受对应本应用的显式商店分发 profile，并核对团队、有效期、签名证书和非开发配置。无受限权限的 Mac 商店应用不必一律嵌入 profile；TestFlight 始终需要 profile，具体最终配置应按实际分发目标验证。

脚本将先验证证书用途，再在副本中按从内到外的顺序签名，以 `productbuild` 生成安装到 `/Applications` 的 `.pkg`，校验提交证书、全部 Mach-O 权限及安装包签名，并保存构建信息和 SHA-256。它保留 USB 权限例外并如实供审核，不把 Developer ID 包当成商店分发包。

提交证书检查采用 Apple WWDR CPS 的 **Mac Application Submission OID `.7`**；安装包采用 **Mac Installer Package Submission OID `.8`**。`.9` 是 Apple 商店重签证书，不能用于判断开发者提交签名。Mac App Store 后续处理仍可能提出新的验证要求。

2026-10-27 已使用实际 Mac App Distribution 与 Mac Installer Distribution 证书生成 0.3.2 / build11 提交包。解包后对实际 payload 的 50 个 Mach-O 再次验证提交证书、团队、权限、runtime 和时间戳均通过；安装包签名的证书指纹与 Apple 证书链也已核对。原 Developer ID 本地候选保持不变。此包未嵌入 profile，未安装、上传或提交审核；可选 profile 路径尚需真实描述文件验收。

`pkgutil` 将开发者提交用的 Mac Installer 证书状态显示为 `signed by a developer certificate issued by Apple (Development)`。校验器兼容这一精确状态文字，同时继续检查提交用途 OID、证书名称与指纹，不接受不受信任或过期状态。签名成功不解决提交材料、第三方许可或审核结果等剩余事项。

参考：[Apple WWDR CPS v3.0](https://images.apple.com/certificateauthority/pdf/Apple_WWDR_CPS_v3.0.pdf)、[正式签名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)、[安装包签名](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)、[描述文件要求](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。

官方参考：[嵌入命令行组件](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)、[沙盒继承](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)、[应用包布局](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)。
