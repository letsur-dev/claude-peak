import SwiftUI

struct UsageView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var updateChecker: UpdateChecker
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showSettings {
                settingsView
            } else if service.needsLogin {
                loginView
            } else if let error = service.error {
                errorView(error)
            } else if let usage = service.usage {
                usageContent(usage)
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            HStack {
                if service.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: showSettings ? "xmark" : "gear")
                }
                .buttonStyle(.borderless)
                if !service.needsLogin && !showSettings {
                    Button("Refresh") {
                        Task { await service.fetchUsage() }
                    }
                    .buttonStyle(.borderless)
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            service.startPolling()
        }
    }

    // MARK: - Settings

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(.headline, design: .monospaced))

            VStack(alignment: .leading, spacing: 6) {
                Text("MENU BAR DISPLAY")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("REFRESH INTERVAL")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.pollingInterval) {
                    ForEach(PollingInterval.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: settings.pollingInterval) { _ in
                    service.restartPolling()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("FLAME ICON")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: {
                        settings.flameMode == .madmax ? .dynamic : settings.flameMode
                    },
                    set: { settings.flameMode = $0 }
                )) {
                    ForEach(FlameMode.pickerCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(settings.flameMode == .madmax)
                .opacity(settings.flameMode == .madmax ? 0.4 : 1)
                HStack {
                    Toggle(isOn: Binding(
                        get: { settings.flameMode == .madmax },
                        set: { settings.flameMode = $0 ? .madmax : .dynamic }
                    )) {
                        Text("🔥 MADMAX")
                            .font(.system(.caption, design: .monospaced))
                            .bold()
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text("\(String(format: "%.0f", activity.tokensPerSecond)) tps")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(tpsMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(tpsMessageColor)
                    .italic()
            }

            if !service.needsLogin {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ACCOUNT")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button("Logout") {
                        service.logout()
                        showSettings = false
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UPDATE AVAILABLE")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack {
                            Text("v\(version) → v\(latest)")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button("Copy brew command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew upgrade claude-peak", forType: .string)
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }
                } else {
                    HStack {
                        Spacer()
                        Text("v\(version)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Login

    private var loginView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            Text("Login Required")
                .font(.system(.headline, design: .monospaced))

            Text("Sign in with your Claude account to view usage.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Login with Claude") {
                service.oauthService.startLogin { result in
                    service.handleLoginResult(result)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            if let error = service.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Usage Content

    @ViewBuilder
    private func usageContent(_ usage: UsageResponse) -> some View {
        sectionHeader("Current Session")
        usageBar(
            label: "5-hour limit",
            bucket: usage.fiveHour
        )

        Divider()

        sectionHeader("Weekly Limits")
        usageBar(
            label: "All models",
            bucket: usage.sevenDay
        )
        if let sonnet = usage.sevenDaySonnet {
            usageBar(
                label: "Sonnet only",
                bucket: sonnet
            )
        }

        Divider()

        sectionHeader("Extra Usage")
        Text(usage.extraUsage.isEnabled ? "Enabled" : "Disabled")
            .font(.system(.body, design: .monospaced))
            .foregroundColor(usage.extraUsage.isEnabled ? .green : .secondary)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private func usageBar(label: String, bucket: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Text("\(bucket.percentage)%")
                    .font(.system(.body, design: .monospaced))
                    .bold()
                    .foregroundColor(colorForPercentage(bucket.percentage))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(colorForPercentage(bucket.percentage))
                        .frame(width: geo.size.width * min(1, CGFloat(bucket.utilization) / 100), height: 8)
                }
            }
            .frame(height: 8)

            Text("Resets in \(bucket.timeUntilReset)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var tpsMessage: String {
        let tps = activity.tokensPerSecond
        if settings.flameMode == .madmax {
            let flames = tps <= 0 ? 0 : min(10, Int(tps / 10000) + 1)
            switch flames {
            case 0:     return "Light it up. If you can."
            case 1...2: return "That's it? Pathetic."
            case 3...4: return "Warming up..."
            case 5...6: return "Now we're cooking."
            case 7...8: return "FEEL THE BURN"
            case 9:     return "ONE MORE. DO IT."
            case 10:    return "WITNESS ME"
            default:    return ""
            }
        }
        if tps <= 0 { return "" }
        if tps > 60000 { return "Full throttle" }
        if tps > 30000 { return "Heating up" }
        return ""
    }

    private var tpsMessageColor: Color {
        let tps = activity.tokensPerSecond
        if settings.flameMode == .madmax {
            let flames = tps <= 0 ? 0 : min(10, Int(tps / 10000) + 1)
            if flames >= 9 { return .red }
            if flames >= 5 { return .orange }
            if flames >= 1 { return .secondary }
        }
        if tps > 60000 { return .orange }
        return .secondary
    }

    private func colorForPercentage(_ pct: Int) -> Color {
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .green
    }
}
