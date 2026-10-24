import AppKit
import SwiftUI
import TravelArchiveCore

struct ArchiveView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var phone: IPhoneSource

    init(model: AppModel) {
        self.model = model
        self.phone = model.phone
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("把这段旅程，收在一起。")
                            .font(.system(size: 26, weight: .semibold))
                        Text("新建旅行归档")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    if model.hasDeviceSelection {
                        DisclosureGroup {
                            inputFields.padding(.top, 16)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("旅行设置 · \(model.travelName)")
                                    .font(.system(size: 14, weight: .medium))
                                Text("\(CaptureDay(date: model.startDate).description) 至 \(CaptureDay(date: model.endDate).description) · 展开修改")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(alignment: .top, spacing: 28) {
                            locationSelection.frame(maxWidth: .infinity, alignment: .topLeading)
                            preview.frame(width: 338, alignment: .topLeading)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 28) {
                            inputFields.frame(maxWidth: .infinity, alignment: .topLeading)
                            preview.frame(width: 338, alignment: .topLeading)
                        }
                    }
                    if let preview = model.preview, !preview.issues.isEmpty {
                        issuesSection(preview)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            footer.padding(.horizontal, 28).padding(.vertical, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    private var inputFields: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 9) {
                fieldLabel("旅行名称")
                TextField("例如：川西自驾", text: $model.travelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .controlSize(.large)
                    .accessibilityLabel("旅行名称")
            }
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 20) {
                    dateField("开始日期", date: $model.startDate)
                    dateField("结束日期", date: $model.endDate)
                }
                Text("包含开始和结束两天的素材")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("素材来源")
                Picker("素材来源类型", selection: $model.sourceKind) {
                    ForEach(AppModel.SourceKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.sourceKind == .folder {
                    folderField(title: "素材文件夹", url: model.sourceURL, symbol: "camera", emptyLabel: "选择素材文件夹…", isSource: true)
                } else {
                    phoneFields
                }
            }
            folderField(title: "保存到", url: model.destinationURL, symbol: "folder", emptyLabel: "选择保存位置…", isSource: false)
            Text(model.inputHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isBusy)
    }

    private var phoneFields: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.system(size: 22)).foregroundStyle(.secondary)
                Picker("选择 iPhone", selection: Binding(
                    get: { phone.selectedDeviceID },
                    set: { phone.selectedDeviceID = $0 }
                )) {
                    Text("请选择 iPhone").tag(nil as String?)
                    ForEach(phone.devices, id: \.id) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(phone.devices.isEmpty)
                Button("查找设备") { model.findPhones() }
            }
            Text(phone.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("旅行拍摄时区")
                Picker("旅行拍摄时区", selection: $model.timeZoneIdentifier) {
                    ForEach(Self.timeZoneChoices, id: \.self) { identifier in
                        Text(Self.timeZoneLabel(identifier)).tag(identifier)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("按此时区判断照片和视频属于哪一天；跨时区旅行请按实际行程选择。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("扫描只读取照片目录信息，再按日期筛选“由我拍摄”的照片和视频，不逐张读取原片。仅复制手机上可读取的原件，不从 iCloud 下载。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("城市优先使用手机已有信息，缺失或无法确认时才通过 Apple 联网补查；照片和视频仅通过数据线读取。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("按开始导入时确认的日期、地点和文件清单归档。先复制全部素材，再统一校验，通过后才显示完成。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("扫描完成后可拔线查看和勾选。开始归档前，接回同一部 iPhone 并解锁，保持连接至完成。扫描与归档期间请先退出 iPhone 镜像。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
    }

    private var locationSelection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("选择城市或地区")
                Spacer()
                Text("已选 \(model.selectedAssetCount) / \(model.matchedAssetCount) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.matchedAssetCount == 0 {
                Text("这个日期范围内没有符合“由我拍摄”的素材。可调整日期后重新扫描。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("按拍摄位置分组。勾选后，只将这些地点的素材放入本次旅行文件夹；默认不选中任何地点。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.locationGroups.filter { !$0.isUnknown }) { group in
                    Toggle(isOn: Binding(
                        get: { model.selectedGroupIDs.contains(group.id) },
                        set: { model.selectLocation(group.id, selected: $0) }
                    )) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(group.name)
                                .font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text("\(group.assets.count) 项素材")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(11)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(model.locationGroups.filter(\.isUnknown)) { group in
                    unknownLocationGroup(group)
                }
            }
        }
        .disabled(model.phase != .ready)
    }

    private func unknownLocationGroup(_ group: DevicePlaceGroup) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("没有可确认的位置，不会自动加入旅行。请根据文件名和拍摄日期逐项勾选。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(group.assets) { asset in
                    Toggle(isOn: Binding(
                        get: { model.selectedUnknownAssetIDs.contains(asset.id) },
                        set: { model.selectUnknownAsset(asset.id, selected: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text("\(asset.captureDay.description) · \(asset.kind.label)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                Text("位置未知").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Text("\(group.assets.count) 项 · 展开选择")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let timeZoneChoices = Array(Set(TimeZone.knownTimeZoneIdentifiers + [TimeZone.current.identifier])).sorted()

    private static func timeZoneLabel(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier),
              let name = zone.localizedName(for: .generic, locale: Locale(identifier: "zh_CN")) else { return identifier }
        return "\(name) · \(identifier)"
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .medium))
    }

    private func dateField(_ title: String, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(title)
            DatePicker(title, selection: date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .controlSize(.large)
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func folderField(title: String, url: URL?, symbol: String, emptyLabel: String, isSource: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(title)
            Button { model.chooseFolder(isSource: isSource) } label: {
                HStack(spacing: 11) {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url?.lastPathComponent ?? emptyLabel)
                            .font(.system(size: 13, weight: url == nil ? .regular : .medium))
                            .lineLimit(2)
                        if let url {
                            Text(url.path)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(url == nil ? "选择…" : "更改…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(13)
                .frame(maxWidth: .infinity, minHeight: 61, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help(url?.path ?? emptyLabel)
            .accessibilityLabel("\(title)：\(url?.path ?? "未选择")，\(url == nil ? "选择文件夹" : "更改文件夹")")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("归档预览").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.statusLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 23))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.folderName)
                        .font(.system(size: 14, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(model.destinationURL?.path ?? "选择保存位置后，在其中新建此文件夹")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Divider()
            if model.sourceKind == .iphone {
                livePhotoImportOptions
                Divider()
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.preview.map { String($0.assetCount ?? $0.fileCount) } ?? "—")
                    .font(.system(size: 31, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(model.sourceKind == .iphone ? "项素材" : "个文件").foregroundStyle(.secondary).font(.system(size: 12))
                Spacer()
                Text(model.preview.map { Self.byteCount($0.totalBytes) } ?? "—")
                    .font(.system(size: 18, weight: .medium))
                    .monospacedDigit()
                    .help(model.preview.map { "\($0.totalBytes) 字节" } ?? "扫描后显示总大小")
            }
            if let preview = model.preview, preview.isDevice {
                Text("实际复制 \(preview.fileCount) 个文件；实况照片按一项素材选择，\(model.livePhotoImportMode == .complete ? "保存照片和配套短视频。" : "仅保存静态照片。")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                mediaRow(.video, symbol: "video")
                mediaRow(.photo, symbol: "photo")
                mediaRow(.audio, symbol: "music.note")
            }
            previewNote
            if model.isBusy { progressView }
            if model.phase == .succeeded, let result = model.result {
                Label("已复制并校验 \(result.fileCount) 个文件。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: model.phase == .cancelled ? "pause.circle" : "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(model.phase == .cancelled ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if model.phase == .failed, model.partialTargetURL != nil {
                        Text("已复制并校验 \(model.completedFiles) 个文件；此次归档尚未完成。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let url = model.partialTargetURL {
                        Text(url.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(21)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
    }

    private var livePhotoImportOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel("实况照片导入方式")
            Picker("实况照片导入方式", selection: Binding(
                get: { model.livePhotoImportMode },
                set: { model.setLivePhotoImportMode($0) }
            )) {
                Text("完整实况照片").tag(LivePhotoImportMode.complete)
                Text("仅静态照片").tag(LivePhotoImportMode.stillOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("实况照片导入方式")
            .disabled(!model.canChangeLivePhotoImportMode)
            Text(model.livePhotoImportMode == .complete
                 ? "保存原始照片和配套短视频，并核验配对关系。单独拍摄的视频照常导入。"
                 : "只保存原始 HEIC/JPEG 照片，不做格式转换；单独拍摄的视频照常导入。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mediaRow(_ kind: MediaKind, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(kind.label)
            Spacer()
            Text(model.preview.map { "\($0.count(kind)) 个" } ?? "—").monospacedDigit()
        }
        .font(.system(size: 13))
    }

    private var previewNote: some View {
        Text(previewNoteText)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var previewNoteText: String {
        guard let preview = model.preview else {
            return model.sourceKind == .iphone
                ? "扫描后先勾选城市或地区，再查看选中素材的数量与大小。点击“开始归档”才创建旅行文件夹并复制素材。"
                : "扫描后查看匹配数量与大小。点击“开始归档”后才创建文件夹并复制素材。"
        }
        if model.hasDeviceSelection && model.matchedAssetCount > 0 && !model.hasPlaceSelection {
            return "请先勾选城市或地区。“位置未知”的素材需展开后逐项选择。"
        }
        if preview.issues.contains(where: \.isBlocking) { return "存在文件冲突、配套文件或读取问题。请处理下方提示后重新扫描。" }
        if preview.fileCount == 0 { return "当前选择没有可归档的素材，不会创建空文件夹。" }
        let excluded = preview.issues.isEmpty ? "" : "部分文件有提示，详见下方。只归档上方统计的已匹配素材。"
        let deviceNote = preview.isDevice ? "所选地点和日期的素材放在同一个旅行文件夹。归档前请连接并解锁同一部 iPhone。" : ""
        return "保留原文件名。\(preview.outsideRangeCount > 0 ? "另有 \(preview.outsideRangeCount) 个素材在日期范围外。" : "")\(deviceNote)\(excluded)"
    }

    @ViewBuilder
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.phase == .scanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.isCancelling ? "正在停止扫描…" : (model.sourceKind == .iphone ? "正在读取日期和地点…" : "已检查 \(model.scanProgress?.visitedFiles ?? 0) 个文件"))
                        .font(.system(size: 12))
                }
                if let value = model.scanProgress {
                    Text(value.currentFile).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                let value = model.archiveProgress
                ProgressView(value: value?.fraction ?? 0)
                    .accessibilityLabel("归档进度")
                HStack {
                    Text(model.isCancelling ? "正在安全停止…" : (model.sourceKind == .iphone
                        ? (value == nil ? "正在确认导入清单…" : (value?.stage == .verifying ? "第二步：统一校验" : "第一步：复制素材"))
                        : (value?.stage == .verifying ? "正在校验" : "正在复制")))
                    Spacer()
                    Text(model.sourceKind == .iphone && value?.stage == .copying
                        ? "已复制 \(value?.copiedFiles ?? 0) / \(model.preview?.fileCount ?? 0)"
                        : "已校验 \(model.completedFiles) / \(model.preview?.fileCount ?? 0)")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if let value {
                    Text(value.currentFile).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Text(model.sourceKind == .iphone
                        ? (value.stage == .copying ? "先复制全部素材，再统一校验；已复制不代表归档完成。" : "正在检查本地副本；实况照片整对通过后才计为完成。")
                        : "当前文件校验完成后，计入已完成数量。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func issuesSection(_ preview: ArchivePreview) -> some View {
        let issues = preview.issues
        return VStack(alignment: .leading, spacing: 12) {
            Label("有 \(issues.count) 项需要注意", systemImage: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(issues.contains(where: \.isBlocking) ? Color.red : Color.orange)
            Text(issues.contains(where: \.isBlocking)
                 ? "以下包含阻止归档的问题，请修正后重新扫描。"
                 : "请查看各项原因；未匹配的文件不会计为归档成功。可以继续归档上方统计的素材。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 13) {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.isBlocking ? "xmark.circle.fill" : "info.circle")
                            .foregroundStyle(issue.isBlocking ? Color.red : Color.orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(issue.name).font(.system(size: 12, weight: .medium))
                                Text(issue.disposition)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(issue.message).font(.system(size: 12))
                            if let location = issue.location {
                                Text(location).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("仅复制素材，原文件保持不变", systemImage: "checkmark.shield")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            if model.isBusy {
                Button(model.isCancelling ? "正在取消…" : "取消任务") { model.cancel() }
                    .disabled(model.isCancelling)
            } else {
                if model.resultURL != nil {
                    Button("在 Finder 中打开") { model.openResult() }
                }
                Button(model.preview == nil ? "扫描素材" : "重新扫描") { model.scan() }
                    .disabled(!model.canScan)
                Button("开始归档") { model.archive() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canArchive)
            }
        }
        .controlSize(.large)
    }

    private var statusColor: Color {
        switch model.phase {
        case .succeeded: return .green
        case .failed: return .red
        case .archiving, .scanning: return .accentColor
        default: return .secondary
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
