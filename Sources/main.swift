import AppKit

// Menu bar item showing Claude plan usage: "✦ <session %> · <week %>".
//
// Two sources, and the newer reading wins:
//   - the usage API, polled every minute (it rate limits, so we back off on a 429);
//   - the file written by statusline.sh, which Claude Code updates on every status line render.

// MARK: - Settings

let apiPollInterval: TimeInterval = 60
let fileRefreshInterval: TimeInterval = 15

let orangeFromPercent = 80.0
let redFromPercent = 95.0

let usageFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/usage-bar/rate-limits.json")
let usageAPIURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let keychainService = "Claude Code-credentials"

// MARK: - Usage data

struct UsageWindow {
    let percent: Double
    let resetsAt: Date

    /// Percent used right now; a window that has already reset counts as unused.
    func currentPercent(at now: Date) -> Double {
        return resetsAt > now ? percent : 0
    }
}

enum UsageSource: String {
    case claudeCode = "Claude Code"
    case api = "Claude API"
}

struct UsageSnapshot {
    let session: UsageWindow?
    let week: UsageWindow?
    let updatedAt: Date
    let source: UsageSource
}

// MARK: - Reading the file written by statusline.sh

struct StatuslineFile: Decodable {
    struct Window: Decodable {
        let usedPercentage: Double
        let resetsAt: TimeInterval
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let updatedAt: TimeInterval
}

/// Read the latest usage saved by statusline.sh, or nil when there is none.
func readClaudeCodeSnapshot() -> UsageSnapshot? {
    guard let data = try? Data(contentsOf: usageFileURL) else {
        return nil
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    guard let file = try? decoder.decode(StatuslineFile.self, from: data) else {
        return nil
    }

    func window(_ raw: StatuslineFile.Window?) -> UsageWindow? {
        guard let raw else { return nil }
        return UsageWindow(
            percent: raw.usedPercentage,
            resetsAt: Date(timeIntervalSince1970: raw.resetsAt)
        )
    }

    return UsageSnapshot(
        session: window(file.fiveHour),
        week: window(file.sevenDay),
        updatedAt: Date(timeIntervalSince1970: file.updatedAt),
        source: .claudeCode
    )
}

// MARK: - Usage API

enum UsageAPIError: LocalizedError {
    case noLogin
    case rateLimited(retryAfter: TimeInterval)
    case unexpectedResponse(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noLogin:
            return "No Claude Code login found. Run 'claude' and log in."
        case .rateLimited:
            return "Usage API is rate limited. Will retry later."
        case .unexpectedResponse(let statusCode):
            return "Usage API returned HTTP \(statusCode). Will retry later."
        }
    }
}

struct UsageAPIResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String
    }

    let fiveHour: Window?
    let sevenDay: Window?
}

/// Read the Claude Code OAuth access token from the login Keychain.
func readOAuthToken() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", keychainService, "-w"]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any]
    else {
        return nil
    }

    return oauth["accessToken"] as? String
}

/// Parse an API timestamp like "2026-09-24T20:20:00.218162+00:00".
func parseAPIDate(_ text: String) -> Date? {
    let withoutFraction = text.replacingOccurrences(
        of: "\\.\\d+",
        with: "",
        options: .regularExpression
    )
    return ISO8601DateFormatter().date(from: withoutFraction)
}

/// Fetch current usage from the Anthropic OAuth usage endpoint.
func fetchUsageFromAPI() async throws -> UsageSnapshot {
    guard let token = readOAuthToken() else {
        throw UsageAPIError.noLogin
    }

    var request = URLRequest(url: usageAPIURL, timeoutInterval: 10)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    let (data, response) = try await URLSession.shared.data(for: request)
    let httpResponse = response as! HTTPURLResponse

    if httpResponse.statusCode == 429 {
        let retryAfterText = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? ""
        throw UsageAPIError.rateLimited(retryAfter: TimeInterval(retryAfterText) ?? 0)
    }

    guard httpResponse.statusCode == 200 else {
        throw UsageAPIError.unexpectedResponse(statusCode: httpResponse.statusCode)
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let usage = try decoder.decode(UsageAPIResponse.self, from: data)

    func window(_ raw: UsageAPIResponse.Window?) -> UsageWindow? {
        guard let raw, let resetsAt = parseAPIDate(raw.resetsAt) else { return nil }
        return UsageWindow(percent: raw.utilization, resetsAt: resetsAt)
    }

    return UsageSnapshot(
        session: window(usage.fiveHour),
        week: window(usage.sevenDay),
        updatedAt: Date(),
        source: .api
    )
}

// MARK: - Display text

let resetTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE h:mm a"
    return formatter
}()

func percentText(_ window: UsageWindow?, at now: Date) -> String {
    guard let window else { return "–" }
    return "\(Int(window.currentPercent(at: now).rounded()))%"
}

func windowLine(_ label: String, _ window: UsageWindow?, at now: Date) -> String {
    guard let window else { return "\(label): not available" }

    let percent = percentText(window, at: now)
    let resets = resetTimeFormatter.string(from: window.resetsAt)
    return "\(label): \(percent) (resets \(resets))"
}

/// Orange or red when a limit is nearly used up; nil keeps the normal menu bar color.
func warningColor(forPercent percent: Double) -> NSColor? {
    if percent >= redFromPercent {
        return .systemRed
    }
    if percent >= orangeFromPercent {
        return .systemOrange
    }
    return nil
}

// MARK: - Menu bar app

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var fileTimer: Timer?
    private var apiTimer: Timer?

    private var claudeCodeSnapshot: UsageSnapshot?
    private var apiSnapshot: UsageSnapshot?
    private var apiProblem: String?
    private var rateLimitedUntil = Date.distantPast
    private var isFetchingFromAPI = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()

        fileTimer = Timer.scheduledTimer(withTimeInterval: fileRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFromFile()
            }
        }

        // Its own timer, so polls land exactly apiPollInterval apart.
        apiTimer = Timer.scheduledTimer(withTimeInterval: apiPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAPI()
            }
        }
    }

    /// The most recently updated reading from either source.
    private var snapshot: UsageSnapshot? {
        return [claudeCodeSnapshot, apiSnapshot]
            .compactMap { $0 }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Refresh from both sources right now (launch and the "Refresh now" menu item).
    @objc private func refresh() {
        refreshFromFile()
        pollAPI()
    }

    private func refreshFromFile() {
        claudeCodeSnapshot = readClaudeCodeSnapshot()
        updateTitle()
    }

    /// Fetch usage from the API unless a request is running or the server asked us to wait.
    private func pollAPI() {
        guard Date() >= rateLimitedUntil, !isFetchingFromAPI else { return }

        isFetchingFromAPI = true

        Task {
            do {
                apiSnapshot = try await fetchUsageFromAPI()
                apiProblem = nil
            } catch UsageAPIError.rateLimited(let retryAfter) {
                apiProblem = UsageAPIError.rateLimited(retryAfter: retryAfter).errorDescription
                rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            } catch {
                apiProblem = error.localizedDescription
            }

            isFetchingFromAPI = false
            updateTitle()
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }

        guard let snapshot else {
            button.title = "✦ …"
            return
        }

        let now = Date()
        let sessionPercent = snapshot.session?.currentPercent(at: now) ?? 0
        let weekPercent = snapshot.week?.currentPercent(at: now) ?? 0
        let title = "✦ C \(percentText(snapshot.session, at: now)) · W \(percentText(snapshot.week, at: now))"

        // The bar takes the color of whichever limit is fuller.
        if let color = warningColor(forPercent: max(sessionPercent, weekPercent)) {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: color]
            )
        } else {
            button.title = title
        }
    }

    // MARK: Dropdown menu

    /// Rebuild the dropdown each time it opens so ages and reset times are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        guard let snapshot else {
            addInfoLine("Waiting for usage data from Claude Code…", to: menu)
            addProblemAndActions(to: menu)
            return
        }

        addInfoLine(windowLine("Current session", snapshot.session, at: now), to: menu)
        addInfoLine(windowLine("Current week", snapshot.week, at: now), to: menu)
        menu.addItem(.separator())

        let age = RelativeDateTimeFormatter().localizedString(for: snapshot.updatedAt, relativeTo: now)
        addInfoLine("Updated \(age) · from \(snapshot.source.rawValue)", to: menu)

        addProblemAndActions(to: menu)
    }

    private func addProblemAndActions(to menu: NSMenu) {
        if let apiProblem {
            addInfoLine(apiProblem, to: menu)
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
    }

    private func addInfoLine(_ text: String, to menu: NSMenu) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
