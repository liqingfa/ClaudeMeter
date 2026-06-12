import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var modelScope: Scope = .sevenDay

    enum Scope: String, CaseIterable, Identifiable {
        case all = "全部"
        case thirtyDay = "30天"
        case sevenDay = "7天"
        var id: String { rawValue }
    }

    private var snap: UsageSnapshot { state.snapshot }
    private var models: [ModelUsage] {
        switch modelScope {
        case .all:       return snap.modelsAll
        case .thirtyDay: return snap.models30d
        case .sevenDay:  return snap.models7d
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            quotaSection
            Divider()
            modelSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundStyle(.tint)
            Text("Claude Code")
                .font(.headline)
            Spacer()
            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(state.isRefreshing ? 360 : 0))
                    .animation(state.isRefreshing
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default, value: state.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("立即刷新")
            .disabled(state.isRefreshing)
        }
    }

    /// Subscription quota windows, or a friendly note when there is no
    /// subscription quota (API key / Bedrock / not logged in).
    @ViewBuilder private var quotaSection: some View {
        switch snap.quotaState {
        case .unavailable:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("未检测到 Claude 订阅额度")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("可能在用 API Key / Bedrock，或尚未登录 —— 仅显示本地各模型用量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "info.circle")
            }
            .foregroundStyle(.secondary)

        default:
            VStack(alignment: .leading, spacing: 12) {
                WindowRow(title: "5 小时额度", window: snap.fiveHour)
                WindowRow(title: "周额度", window: snap.sevenDay)

                if snap.quotaState == .needsLogin {
                    Label("凭证已过期，请打开 Claude Code 重新登录。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if snap.quotaState == .rateLimited {
                    Label("请求过于频繁，已自动降频，稍后自动恢复（显示的是上次数据）。",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if snap.quotaState == .unknown, let e = snap.error {
                    Label(e, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("各模型用量")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $modelScope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            if models.isEmpty {
                Text("窗口内暂无记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let maxActive = models.map(\.activeTokens).max() ?? 1
                ForEach(models) { m in
                    ModelRow(model: m, maxActive: maxActive)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if snap.updatedAt > .distantPast {
                Text("更新于 \(snap.updatedAt, format: .dateTime.hour().minute().second())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

// MARK: - Rate-limit window row

private struct WindowRow: View {
    let title: String
    let window: WindowUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(window.map { Fmt.percent($0.utilization) } ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.map { Fmt.color(for: $0.fraction) } ?? .secondary)
            }

            ProgressBar(fraction: window?.fraction ?? 0,
                        color: window.map { Fmt.color(for: $0.fraction) } ?? .gray)

            if let w = window {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("\(Fmt.remaining(until: w.resetsAt)) 后刷新")
                    Text("·").foregroundStyle(.tertiary)
                    Text(Fmt.resetClock(w.resetsAt))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Per-model row

private struct ModelRow: View {
    let model: ModelUsage
    let maxActive: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.displayName)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(Fmt.tokens(model.activeTokens))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressBar(
                fraction: maxActive > 0 ? Double(model.activeTokens) / Double(maxActive) : 0,
                color: .accentColor, height: 4
            )
        }
    }
}

// MARK: - Reusable bar

private struct ProgressBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}
