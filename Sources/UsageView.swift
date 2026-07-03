import SwiftUI

struct UsageView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var secondaryService: UsageService
    @ObservedObject var codex: CodexService
    @ObservedObject var settings: AppSettings
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var updateChecker: UpdateChecker
    @State private var showSettings = false
    @State private var showAction = false
    @State private var flipTimer: Timer?

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
            secondaryService.startPolling()
            if flipTimer == nil {
                flipTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    Task { @MainActor in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            showAction.toggle()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Settings

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(.headline, design: .monospaced))

            groupHeader("GENERAL")

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
                Text("MESSAGE LANGUAGE")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            groupHeader("CLAUDE")

            VStack(alignment: .leading, spacing: 6) {
                Text("WEEKLY LIMIT")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.weeklyLimitDisplay) {
                    ForEach(WeeklyLimitDisplay.allCases, id: \.self) { option in
                        Text(option == .scoped ? (service.usage?.weeklyScopedLimits.first?.name ?? option.label) : option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("REMOTE SERVER")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Toggle(isOn: $settings.remoteEnabled) {
                    HStack {
                        Text("Enable")
                            .font(.system(.caption, design: .monospaced))
                        if settings.remoteEnabled {
                            Circle()
                                .fill(activity.remoteConnected ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                if settings.remoteEnabled {
                    HStack(spacing: 4) {
                        TextField("Host", text: $settings.remoteHost)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Text(":")
                            .font(.system(.caption, design: .monospaced))
                        TextField("Port", text: Binding(
                            get: { String(settings.remotePort) },
                            set: { settings.remotePort = Int($0) ?? 3200 }
                        ))
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ACCOUNT LABELS")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("Main", text: $settings.mainAccountLabel)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    TextField("Sub", text: $settings.subAccountLabel)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SUB ACCOUNT")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                if secondaryService.needsLogin {
                    Button("Login Sub Account") {
                        secondaryService.oauthService.startLogin { result in
                            secondaryService.handleLoginResult(result)
                        }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Logout Sub") {
                        secondaryService.logout()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
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

            groupHeader("CODEX")

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.codexEnabled) {
                    HStack {
                        Text("Show Codex usage")
                            .font(.system(.caption, design: .monospaced))
                        if settings.codexEnabled && codex.available {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Text("reads ~/.codex")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
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
        if settings.flameMode != .off {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(String(format: "%.0f", activity.tokensPerSecond)) tokens/sec")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    if settings.remoteEnabled && activity.remoteConnected {
                        Text("(+remote)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
                if !tpsMessage.isEmpty {
                    Text(tpsMessage)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(tpsMessageColor)
                        .italic()
                }
            }
            Divider()
        }

        if secondaryService.usage != nil {
            HStack {
                sectionHeader(service.email ?? settings.mainAccountLabel)
                if let plan = service.accountInfo?.planLabel {
                    Spacer()
                    Text(plan)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }
            }
        }
        usageBar(
            label: "5-hour limit",
            bucket: usage.fiveHour
        )

        paceLabel(for: usage.sevenDay)
        weeklyBars(usage)

        if let secondUsage = secondaryService.usage {
            Divider()

            HStack {
                sectionHeader(secondaryService.email ?? settings.subAccountLabel)
                if let plan = secondaryService.accountInfo?.planLabel {
                    Spacer()
                    Text(plan)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            usageBar(label: "5-hour limit", bucket: secondUsage.fiveHour)
            paceLabel(for: secondUsage.sevenDay)
            weeklyBars(secondUsage)

        } else if !secondaryService.needsLogin && secondaryService.isLoading {
            Divider()
            sectionHeader("\(settings.subAccountLabel) Account")
            ProgressView().controlSize(.small)
        }

        if settings.codexEnabled && codex.available {
            Divider()

            HStack {
                sectionHeader("⚡ Codex")
                if let plan = codex.planLabel {
                    Spacer()
                    Text(plan)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            if let codexPrimary = codex.primary {
                codexBar(label: "5-hour limit", window: codexPrimary)
            }
            if let codexSecondary = codex.secondary {
                codexBar(label: "Weekly", window: codexSecondary, showDate: true)
            }
            if !codex.isLive, let asOf = codex.snapshotText {
                Text("as of \(asOf)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }

        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            HStack {
                Spacer()
                Text("v\(version)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.caption2, design: .monospaced))
                .bold()
                .foregroundColor(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.contains("@") ? title : title.uppercased())
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
    }

    private func usageBar(label: String, bucket: UsageBucket, showDate: Bool = false) -> some View {
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

            Text(showDate ? "Resets at \(bucket.resetDateString)" : "Resets in \(bucket.timeUntilReset)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func weeklyBars(_ usage: UsageResponse) -> some View {
        if settings.weeklyLimitDisplay != .scoped {
            usageBar(label: "All models", bucket: usage.sevenDay, showDate: true)
        }
        if settings.weeklyLimitDisplay != .all {
            ForEach(usage.weeklyScopedLimits) { item in
                usageBar(label: "\(item.name) only", bucket: item.bucket, showDate: true)
            }
        }
    }

    private func codexBar(label: String, window: CodexWindow, showDate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Text("\(window.percentage)%")
                    .font(.system(.body, design: .monospaced))
                    .bold()
                    .foregroundColor(colorForPercentage(window.percentage))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(colorForPercentage(window.percentage))
                        .frame(width: geo.size.width * min(1, CGFloat(window.usedPercent) / 100), height: 8)
                }
            }
            .frame(height: 8)

            Text(showDate ? "Resets at \(window.resetDateString)" : "Resets in \(window.timeUntilReset)")
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
        let ko = settings.language == .ko
        if settings.flameMode == .madmax {
            let flames = tps <= 0 ? 0 : min(10, Int(tps / 10000) + 1)
            switch flames {
            case 0:     return ko ? "불 좀 붙혀봐. 춥다야." : "Light it up. If you can."
            case 1...2: return ko ? "겨우 이거?" : "That's it? Pathetic."
            case 3...4: return ko ? "슬슬 가볼까" : "Warming up..."
            case 5...6: return ko ? "제법인데?" : "Now we're cooking."
            case 7...8: return ko ? "미쳤다!!!" : "FEEL THE BURN"
            case 9:     return ko ? "거의 다 왔다!!!" : "ONE MORE. DO IT."
            case 10:    return ko ? "나를 기억해!!!" : "WITNESS ME"
            default:    return ""
            }
        }
        if tps <= 0 { return "" }
        if tps > 60000 { return ko ? "풀로 땡기는 중" : "Full throttle" }
        if tps > 30000 { return ko ? "예열 중" : "Heating up" }
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

    @ViewBuilder
    private func paceLabel(for bucket: UsageBucket) -> some View {
        let pace = bucket.paceMessage(language: settings.language)
        let action = bucket.actionMessage(language: settings.language)
        let msg = showAction ? (action ?? pace) : (pace ?? action)
        if let msg = msg {
            Text(msg)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(paceColor(for: bucket))
                .italic()
                .id(msg)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
        }
    }

    private func paceColor(for bucket: UsageBucket) -> Color {
        guard let ratio = bucket.paceRatio else { return .secondary }
        if ratio < 0.6 { return .green }
        if ratio < 1.1 { return .secondary }
        if ratio < 1.4 { return .orange }
        return .red
    }
}
