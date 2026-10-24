# 维护与发布

后续开发在独立的公开仓库 [waton1990/travel-media-manager](https://github.com/waton1990/travel-media-manager) 中进行。以下命令从仓库根目录执行；发布时使用干净 checkout，避免沿用旧的应用目录、Python 环境或附件。需要 macOS、包含 Swift Testing 的 Xcode 或 Command Line Tools、uv，以及已获仓库发布权限的 GitHub CLI。

## 1. 开发、版本与验证

按 [贡献说明](../CONTRIBUTING.md) 在功能分支开发，例如 `codex/next-release`；较大行为变更先通过 Issue 对齐需求。

- 修改 `packaging/Info.plist` 的 `CFBundleShortVersionString` 和递增的 `CFBundleVersion`，保留应用标识。
- 更新 `CHANGELOG.md`、受影响的使用及隐私说明；README、安装说明与发布说明中的版本、附件名称、兼容范围应一致。
- 若更换依赖或构建运行库，先完成下文的通知与源码复核，再提交最终发布代码。

```sh
bash scripts/test.sh
python3 -m unittest discover -s Tests/USBHelperTests -v
bash scripts/test-app-model.sh
bash scripts/test-place-resolution.sh
python3 scripts/check-public-release.py
```

提交前检查暂存内容，再运行 `python3 scripts/check-public-release.py --tracked`。不要提交媒体、设备索引、配对记录、私人日志或 `work/`、`outputs/`。合并到 `main` 后，确认该提交的 GitHub Actions 通过。CI 只做合成检查，不构建发行包，也不代替真机验收；真机检查应单独记录实际设备、系统和范围。

## 2. 构建与依赖材料

```sh
bash scripts/build-app.sh
codesign --verify --deep --strict "outputs/旅行素材管家.app"
python3 scripts/prepare-source-bundle.py --output work/dependency-sources
```

应用位于 `outputs/旅行素材管家.app`。构建脚本包含 USB 组件构建，使用 `scripts/usb-helper-requirements.lock`，并收集组件通知到 `work/usb-helper/dist/iphone-usb-helper/ThirdParty`。它还会将项目 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md` 和 `third-party/` 复制进应用。

发布前依据 [依赖说明](DEPENDENCIES.md) 核对实际二进制、通知及源码：

- 核对生成的 Python 源码清单与锁文件，更新受影响的 `third-party/` 清单、许可证、原生运行库通知和打包分析记录。收集脚本不会自动证明新依赖已满足全部许可要求。
- `prepare-source-bundle.py` 仅生成 Python 源码合集及其 `.sha256`，**不生成 Rust 源码合集**。`cryptography-rust-sources.tar.gz` 必须对应实际 cryptography 版本的 sdist 中的 `Cargo.lock`，按其中校验值准备 crate 源码，同时核对 `third-party/cryptography-rust-source-manifest.json` 和相关通知。只有依赖及对应源码未变且摘要核对通过时，才复用旧合集；更新版本后重新准备。
- 记录实际 Python、Swift、macOS、依赖及架构信息；不要沿用上次的测试结论。通知或源码需要修正时，先提交修正并重新构建、验证，再定标签。

当前脚本使用 ad-hoc 签名，**没有 Developer ID 签名或 Apple 公证**。发布说明应保持这一事实；签名验证通过不等于通过公证。安装指引沿用 [INSTALL.md](INSTALL.md)，不要要求用户关闭系统安全保护。仅声明实际验证过的芯片、系统和设备范围。

## 3. 冻结新标签与附件

以下 `0.3.1` / build `10` 只是下一次发布的示例，必须与最终 `Info.plist` 一致。确认工作区干净、构建对应当前提交且该提交 CI 已通过，再创建新标签。**旧版本标签和已发布附件不重写；修正已发布版本时使用新版本及新标签。**

```sh
release_version=0.3.1
release_build=10
release_tag="v${release_version}"
git status --short
git tag -a "$release_tag" -m "$release_tag community preview"
git push origin "$release_tag"
mkdir -p work/release
git archive --format=tar.gz --prefix="travel-media-manager-${release_version}/" \
  --output="work/release/travel-media-manager-${release_version}-source.tar.gz" "$release_tag"
ditto -c -k --sequesterRsrc --keepParent "outputs/旅行素材管家.app" \
  "work/release/TravelMediaManager-${release_version}-build${release_build}-arm64.zip"
cp work/dependency-sources/python-dependency-sources.tar.gz* work/release/
```

上例适用于在 Apple Silicon 上验证的 arm64 包；文件名不能代替架构验证。`work/release/` 应为本次新建的附件目录，不混入旧包。

再将已核对的 `cryptography-rust-sources.tar.gz` 及其 `.sha256` 放入该目录。创建 `BUILD_INFO.json`，记录版本、build、`git rev-parse "$release_tag^{commit}"` 得到的完整提交、实际工具链与架构、签名状态、测试范围，以及应用和源码附件的名称、大小与 SHA-256。另写 `work/release/release-notes.md`，说明变更、已知限制、安装入口及哪些检查尚未完成。

在附件定稿后生成总校验清单；当前附件约定共 8 项：应用 ZIP、本项目源码、两份依赖源码、两份依赖摘要、构建信息和总校验清单。

```sh
(
  cd work/release
  shasum -a 256 *.zip *.tar.gz *.sha256 BUILD_INFO.json > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
```

## 4. 草稿、下载复核与公开

```sh
gh release create "$release_tag" --verify-tag --draft --prerelease \
  --title "$release_tag · build $release_build · 社区预览版" \
  --notes-file work/release/release-notes.md
gh release upload "$release_tag" work/release/*.zip work/release/*.tar.gz \
  work/release/*.sha256 work/release/BUILD_INFO.json work/release/SHA256SUMS.txt
gh release download "$release_tag" --dir work/release-download
(
  cd work/release-download
  shasum -a 256 -c SHA256SUMS.txt
)
```

下载目录应事先不存在。将下载的清单与本地已验证的 `SHA256SUMS.txt` 比较，确认所有附件齐全、大小与摘要一致；解压下载的应用，核对版本、架构、许可证及签名；检查下载的项目源码与标签提交一致。检查 Release 正文、README、安装与反馈链接后，才执行：

```sh
gh release edit "$release_tag" --draft=false --prerelease
```

公开后，用未登录的访问方式检查仓库、Release 和附件下载入口。当前 CI 不会自动执行以上发布命令。

## 许可与后续贡献

自己发布和接收贡献均应遵循现有 [LICENSE](../LICENSE)、[NOTICE](../NOTICE)、[第三方通知](../THIRD_PARTY_NOTICES.md) 及 [贡献权利说明](../CONTRIBUTING.md#许可证与贡献权利)。项目采用 GPL-3.0-or-later；收费、升级或增加贡献者不应成为省略对应许可和源码材料的理由。这里是维护流程，不作法律意见，也不替代逐项阅读适用许可证。
