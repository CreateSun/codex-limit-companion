import SwiftUI

private let accent = Color.teal

struct CompanionPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var tab = 0
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var confirmSend = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var filtered: [ThreadSummary] {
        model.threads.filter {
            (!selectedOnly || model.selected.contains($0.id)) &&
            (query.isEmpty || ($0.title + $0.project + $0.id).localizedCaseInsensitiveContains(query))
        }.sorted {
            if model.selected.contains($0.id) != model.selected.contains($1.id) { return model.selected.contains($0.id) }
            return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 4) {
                tabButton("额度概览", symbol: "chart.bar.xaxis", value: 0)
                tabButton("会话", symbol: "bubble.left.and.bubble.right", value: 1)
                tabButton("设置", symbol: "slider.horizontal.3", value: 2)
            }.padding(4).background(.primary.opacity(0.045), in: Capsule()).padding(.horizontal, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.error { notice(error, symbol: "wifi.exclamationmark", color: .orange) }
                    if let feedback = model.feedback {
                        HStack(alignment: .top) {
                            notice(feedback, symbol: "info.circle", color: accent)
                            Button { model.feedback = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).padding(.top, 12)
                        }
                    }
                    switch tab {
                    case 1: sessions
                    case 2: settings
                    default: overview
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
            footer
        }
        .frame(width: 400, height: 620)
        .background {
            if reduceTransparency { Rectangle().fill(Color(nsColor: .windowBackgroundColor)) }
            else if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 24).fill(.clear).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
            } else { Rectangle().fill(.ultraThinMaterial) }
        }
        .tint(accent)
        .confirmationDialog("立即发送继续任务消息？", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("发送到 \(model.selected.count) 个会话") { model.sendSelected() }
            Button("取消", role: .cancel) {}
        } message: { Text(model.message) }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: QuotaIcon.mark).renderingMode(.template).resizable().frame(width: 23, height: 23)
                .padding(10).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Companion").font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(model.error != nil ? .orange : model.updatedAt == nil ? .gray : accent).frame(width: 5, height: 5)
                    Text(model.error != nil ? "连接需要检查" : model.updatedAt == nil ? "连接中" : "正在守候你的下一次灵感")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.refresh() } label: {
                if model.refreshing { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
            }.buttonStyle(.plain).padding(8).background(.primary.opacity(0.04), in: Circle())
                .disabled(model.refreshing).help("刷新额度").accessibilityLabel("刷新额度")
        }.padding(20)
    }
    private func tabButton(_ title: String, symbol: String, value: Int) -> some View {
        Button {
            tab = value
            if value == 1 { model.refreshThreadsIfNeeded() }
        } label: {
            HStack(spacing: 5) { Image(systemName: symbol); Text(title) }
                .font(.system(size: 11, weight: tab == value ? .semibold : .medium))
                .frame(maxWidth: .infinity, minHeight: 38)
                .contentShape(Rectangle())
                .background(tab == value ? Color(nsColor: .controlBackgroundColor).opacity(0.85) : .clear, in: Capsule())
                .shadow(color: .black.opacity(tab == value ? 0.06 : 0), radius: 3, y: 1)
        }.buttonStyle(.plain).foregroundStyle(tab == value ? .primary : .secondary)
            .accessibilityAddTraits(tab == value ? [.isSelected] : [])
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.buckets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.error == nil ? "hourglass" : "exclamationmark.icloud").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.error == nil ? "正在读取你的额度…" : "暂时无法获取额度").font(.headline)
                    Text("登录本机 Codex 后，点击右上角刷新。") .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                if model.buckets.count > 1 {
                HStack {
                    Text("菜单栏监控").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("菜单栏监控", selection: $model.bucketID) {
                        if model.current == nil { Text("请选择额度").tag(model.bucketID) }
                        ForEach(model.buckets) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 210)
                }
                }
                if let bucket = model.current, let window = bucket.shortWindow {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(window.title, systemImage: "sparkles").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(model.error != nil ? "上次数据" : bucket.blocked ? "等待恢复" : "可用")
                                .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(accent.opacity(0.10), in: Capsule()).foregroundStyle(accent)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(window.remaining.formatted(.number.precision(.fractionLength(0...1))))
                                .font(.system(size: 58, weight: .light, design: .rounded)).monospacedDigit()
                            Text("%").font(.system(size: 23, weight: .light)).foregroundStyle(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("剩余额度").font(.caption).foregroundStyle(.secondary)
                                Text("已用 \(window.used.formatted(.number.precision(.fractionLength(0...1))))%")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                        progress(window.remaining)
                        resetLine(window)
                    }.padding(18).card(tinted: true)
                }
                Text("全部额度").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(model.buckets) { bucket in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(bucket.name).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if bucket.id == model.bucketID { Text("监控中").font(.system(size: 9, weight: .medium)).foregroundStyle(accent) }
                        }
                        if bucket.windows.isEmpty { Text("暂无可用额度数据").font(.caption).foregroundStyle(.secondary) }
                        ForEach(bucket.windows) { window in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(window.title).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(window.remaining))% 剩余").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                }
                                progress(window.remaining)
                                resetLine(window)
                            }
                        }
                    }.padding(14).card()
                }
                Button { tab = 1; model.refreshThreadsIfNeeded() } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.autoSend ? "恢复后自动继续" : "自动继续已关闭").font(.system(size: 12, weight: .medium))
                            Text("已选择 \(model.selected.count) 个会话").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(14).card()
                }.buttonStyle(.plain)
            }
        }
    }
    private var sessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索会话、项目或 ID", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(11).card()
            HStack {
                Toggle("只看已选 · \(model.selected.count)", isOn: $selectedOnly).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("清空") { model.selected.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.selected.isEmpty)
                Button { model.refreshThreads() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(model.loadingThreads).help("刷新会话")
            }.font(.caption)
            if model.loadingThreads {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.threads.isEmpty ? "正在加载会话…" : "正在刷新，仍可使用现有列表")
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            if let error = model.threadError { notice(error, symbol: "exclamationmark.bubble", color: .orange) }
            if !model.loadingThreads && filtered.isEmpty { Text("没有匹配的会话").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24) }
            LazyVStack(spacing: 7) {
                ForEach(filtered) { thread in
                    Button { model.toggle(thread.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: model.selected.contains(thread.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18)).foregroundStyle(model.selected.contains(thread.id) ? accent : .secondary.opacity(0.4)).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(thread.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                HStack {
                                    Text(thread.project).lineLimit(1)
                                    Spacer()
                                    if let date = thread.updatedAt { Text(date, style: .date).fixedSize() }
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selected.contains(thread.id) ? accent.opacity(0.08) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(model.selected.contains(thread.id) ? accent.opacity(0.25) : .primary.opacity(0.05)))
                    }.buttonStyle(.plain).accessibilityLabel(thread.title + (model.selected.contains(thread.id) ? "，已选中" : "，未选中"))
                }
            }
            let missing = model.selected.subtracting(Set(model.threads.map(\.id)))
            if !missing.isEmpty {
                notice("\(missing.count) 个已选会话不在最近 100 条中，仍会接收消息。", symbol: "info.circle", color: .orange)
                Button("移除未显示的选择") { model.selected.subtract(missing) }.font(.caption)
            }
            Button { confirmSend = true } label: {
                Label(model.sending ? "正在发送…" : "立即发送到 \(model.selected.count) 个会话", systemImage: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.sending || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("额度恢复时会使用这些选择。手动发送会立即继续任务。") .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("自动继续", subtitle: "针对概览页选中的额度")
            VStack(spacing: 0) {
                setting("恢复后发送到已选会话", detail: "定向发送，无需切换前台窗口", value: $model.autoSend)
                Divider().padding(.horizontal, 14)
                setting("额度恢复通知", detail: "恢复可用时发送系统通知", value: $model.notify)
            }.card()
            sectionTitle("菜单栏", subtitle: "图标填充高度表示剩余百分比")
            setting("同时显示百分比", detail: "关闭时仅显示 GPT 图标", value: $model.showPercent).card()
            sectionTitle("继续任务消息", subtitle: "自动与手动发送共用此内容")
            TextEditor(text: $model.message).font(.system(size: 12)).scrollContentBackground(.hidden)
                .frame(height: 70).padding(10).card()
            sectionTitle("前台粘贴", subtitle: "兼容模式 · 会操作当前聚焦的聊天")
            VStack(spacing: 0) {
                setting("额度恢复时自动粘贴", detail: "与定向发送同时开启可能重复提交", value: $model.autoPaste)
                Divider().padding(.horizontal, 14)
                setting("粘贴后按回车发送", detail: "关闭后只填入文本", value: $model.submitPaste).disabled(!model.autoPaste)
            }.card()
            if model.autoPaste { notice("请确保前台是目标聊天。粘贴模式需要辅助功能权限。", symbol: "cursorarrow.click", color: .orange) }
            Text("每 60 秒检查一次；工具需要先观察到额度耗尽，再等待恢复。切换监控额度不会立即触发消息。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let date = model.updatedAt { Text("更新于 \(date.formatted(date: .omitted, time: .shortened))") }
                else { Text("每 60 秒自动更新") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.primary.opacity(0.025))
    }
    private func progress(_ remaining: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.07))
                Capsule().fill(remaining > 30 ? accent : remaining > 10 ? .orange : .red).frame(width: proxy.size.width * remaining / 100)
            }
        }.frame(height: 5).accessibilityLabel("剩余 \(Int(remaining))%")
    }
    private func resetLine(_ window: QuotaWindow) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "clock")
                if let date = window.resetsAt {
                    Text(date, format: .dateTime.month().day().hour().minute())
                    Spacer(minLength: 2)
                    Text(countdown(date, now: context.date))
                } else { Text("重置时间暂不可用") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private func countdown(_ date: Date, now: Date) -> String {
        let mins = Int(ceil(date.timeIntervalSince(now) / 60))
        if mins <= 0 { return "等待额度刷新" }
        if mins >= 1440 { return "\(mins / 1440)天 \((mins % 1440) / 60)小时后重置" }
        if mins >= 60 { return "\(mins / 60)小时 \(mins % 60)分后重置" }
        return "\(mins)分钟后重置"
    }
    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func setting(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .fixedSize().accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
    }
    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension View {
    func card(tinted: Bool = false) -> some View {
        self.background(tinted ? accent.opacity(0.055) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.065), lineWidth: 0.5))
    }
}
