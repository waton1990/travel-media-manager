# Mac App Store 提交材料草稿

本文件是商店适配分支的准备材料，不表示已上传、通过审核或公开上架。正式提交前应填写实际版本、构建号、联系信息及真机验收结果。

## 2026-10-28 准备状态

| 项目 | 已确认状态 |
| --- | --- |
| 商店提交包 | 0.3.2 / build12 已使用商店应用和安装包证书签名，实际 `.pkg` payload 的 50 个 Mach-O 通过证书、团队、权限、runtime 与时间戳审计；未上传构建、未提交审核。 |
| 现有离线检查 | 332 项通过：97 Core、127 USB、23 Packaging、60 Model、25 Place。 |
| 图标 | 使用用户批准的浅蓝原稿；用户明确授权本地 alpha 脚本精确清理透明边缘。包内图标与 `packaging/AppIcon.icns` 一致。 |
| App 隐私 | App Store Connect 的“未收集数据”隐私标签已发布。 |
| 年龄分级与内容版权 | 4+ 与内容版权 No 已保存。取消浏览器离页提示后，页面显示“已保存”，随后成功离开页面且未再出现未保存提示。 |
| 商店截图 | 两张真实应用截图已上传并保存；后台显示 2/10 张，两项文件名均出现，保存按钮已禁用。 |
| 第三方许可 | 按用户选择保留现有 GPL 依赖，等待明确的商店分发授权结论。 |

本地截图位于工作区根目录（不是本仓库根目录）的 `outputs/app-store-screenshots/0.3.2/`：`01-folder-preview.jpg`、`02-archive-complete.jpg`。上传状态证据保存在工作区根目录的 `work/store-submission-2026-10-28/screenshots-uploaded.png`。build12 的构建日志和包审计位置见 `docs/APP_STORE_BUILD.md`；后台字段保存、截图上传和隐私标签发布不表示版本已经提交审核。

## 产品页面

- 名称：旅行素材管家
- 副标题：按日期和城市归档照片与视频
- 主要语言：简体中文
- 平台：macOS
- 套装 ID：`io.github.waton1990.travel-media-manager`
- SKU：`travel-media-manager-macos`
- 建议主类别：摄影
- 支持网址：<https://github.com/waton1990/travel-media-manager/issues>
- 隐私政策：<https://github.com/waton1990/travel-media-manager/blob/main/docs/PRIVACY.md>
- 关键词：旅行,照片,视频,归档,素材,整理,iPhone,实况照片,数据线
- 首发定价：免费（用户已确认）。
- 首发地区：App Store 支持的地区中排除欧盟 27 国，保留 148 个国家或地区（用户已确认）；各地实际可用性仍以当地要求和审核结果为准。新增地区暂不自动加入，避免改变首发范围。

描述：

把一次旅行的照片、视频和音频，整理到一个新的旅行文件夹。

输入旅行名称和日期范围，选择素材来源与保存位置。旅行素材管家会先显示匹配结果，在你确认后复制素材，原文件保持不变。

连接 iPhone 后，可以通过数据线读取“由我拍摄”的照片与视频，按日期和城市或地区筛选。没有可用位置信息的素材单列为“位置未知”，由你查看后选择加入。

实况照片默认保存静态照片与配套短视频，也可以选择只保存静态照片。普通视频仍正常导入。城市名称优先采用手机已有信息，必要时通过 Apple 系统服务查询。

支持从真实文件夹选择相机、存储卡或本地素材，并选择保存位置；无需手写文件路径。只复制支持的照片、视频和音频，忽略 LRF 等辅助文件。归档内容保存在你选择的位置，不依赖 iCloud 传输。

使用 iPhone 来源时，请用数据线连接、解锁并信任这台 Mac。系统版本或照片索引格式变化可能影响兼容性；异常时应用会显示提示，不会删除手机原件。

## 审核说明

以下英文说明随实际候选包更新后用于 App Review Notes，不是发给技术支持的咨询：

Travel Media Manager is a macOS utility that copies selected travel media into a new user-selected folder. It never deletes or modifies source media. There is no app account or login.

For folder import, enter a trip name and date range, choose the source and destination using the standard macOS open panel, scan, review the results, and start archiving. Only supported photos, videos and audio with a reliable matching capture date are included. LRF auxiliary files are ignored.

For iPhone import, connect an iPhone by USB, unlock it, and trust the Mac. Select the iPhone source and find the device, then choose a trip name, date range and destination. The app reads photo index snapshots over USB, filters the “Taken by Me” classification locally, and presents city/region groups. Select groups or individual items under “Unknown location”, review, and import. Live Photos default to both original components; a still-only option excludes only their companion video. Independent videos remain eligible.

The bundled helper uses pymobiledevice3 to communicate with the local usbmuxd service, then uses the existing trusted connection and a read-only AFC wrapper. It reads the phone's Photos.sqlite and search-index metadata for classifications, dates, local place names and original paths. These are internal data formats, and the app does not claim they are documented PhotoKit APIs. Metadata snapshots can include dates outside the selected range; filtering happens on the Mac. Original media is requested only for the confirmed import. The helper does not create a new pairing relationship or write to the phone.

The parent app enables App Sandbox. The embedded helper inherits that sandbox and sends media bytes back through pipes; the parent writes files inside the folder selected by the user. Temporary index snapshots are stored in the sandbox temporary directory. The app does not install or run a separate privileged service.

The submitted entitlement set includes the following narrow temporary exception, which is explicitly disclosed for review:

```xml
<key>com.apple.security.temporary-exception.sbpl</key>
<array>
  <string>(allow network-outbound (literal "/private/var/run/usbmuxd"))</string>
</array>
```

The exception permits connecting to that single local socket. It does not grant general filesystem access. The purpose is to retain the USB media workflow described above. Local testing of this entitlement is not a statement of prior Apple approval.

Valid city names already in the phone index are used first. For assets that have coordinates but lack a usable local name, CLGeocoder sends coordinates to Apple's service to obtain a place name. No media is sent for geocoding, and no media or metadata is uploaded to a developer-operated server. The app has no analytics, advertising or tracking SDKs.

## 提交前补齐的实际信息

- 已备妥 0.3.2 / build12 及商店应用、安装包签名；尚需完成构建上传、处理后台校验并提交审核。
- 沙盒候选包的真机日期/城市/“由我拍摄”扫描，以及少量完整实况照片、静态模式和普通视频导入验收。
- 已用合成素材生成并上传两张真实应用截图，后台保存已确认。后续补充截图仍不能包含用户的照片、位置、设备标识或个人路径。
- 审核联系人已由账号持有人提供并填入 Apple 审核资料，不将联系方式写入公开仓库。
- 首发免费、暂不在欧盟发行已经确认。若后续增加欧盟地区，应重新确认 DSA 交易商身份及必要的公开联系方式；审核联系人不等于公开联系方式授权。
- 隐私页面“未收集数据”已发布，后续行为变化仍须复核；本地处理与 Apple 系统服务处理应依据 Apple 的定义区分，不能把没有开发者服务器等同于不发生任何网络请求。
- 按用户选择保留现有依赖，对实际打包的第三方组件取得明确的商店分发授权结论，保留许可证及对应源码获取方式。Apple 审核不能代替第三方许可义务。

2026-10-27 的静态包审查确认，当前组件实际包含 `pymobiledevice3`、`ioregistry`、`pygnuutils` 的 GPLv3 系列代码；已附通知及对应版本源码材料，未发现随包商店授权例外。GPL 与商店附加使用/转让限制的兼容性尚未解决。Apple 标准 EULA 确有开源条款例外，不能据此笼统断言 GPL 一律不能上架，也不能把它当作本包授权问题已经解决。正式分发前仍需处理；仅更改本项目自有代码许可不能替代第三方授权。

参考：[Apple 标准 EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)、[Apple 开发者协议及最低 EULA 条款](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)、[GPLv3](https://www.gnu.org/licenses/gpl-3.0.html)。
