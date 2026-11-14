import SwiftUI
import Combine
import EventKit
import AppKit

enum PomodoroSessionType {
    case work
    case breakTime
}

/// Central session state machine: idle → running → pausedConfirming, across
/// work and break sessions, including infinite-flow (count-up) mode and the
/// long-break cycle after every `sessionsUntilLongBreak` work sessions.
/// Session completion fans out to local history (PomodoroHistoryManager),
/// EventKit or Jarvi calendars, and Jarvi analytics.
class PomodoroManager: ObservableObject {
    @Published var timeRemaining: Int = 0
    @Published var isRunning: Bool = false
    @Published var sessionType: PomodoroSessionType = .work
    @Published var completedToday: Int = 0
    @AppStorage("pomodoro.sessionGoal") var sessionGoal: Int = 8
    
    @AppStorage("pomodoro.autoStartWork") var autoStartWork: Bool = false
    @AppStorage("pomodoro.autoStartBreak") var autoStartBreak: Bool = true
    @AppStorage("break.showTimerOverlay") var showBreakTimerOverlay: Bool = true
    @AppStorage("compact.clockMode") var compactClockMode: String = "countdown"
    
    // Pro Settings
    @AppStorage("pomodoro.longBreakDuration") var longBreakDuration: Int = 20 * 60
    @AppStorage("pomodoro.sessionsUntilLongBreak") var sessionsUntilLongBreak: Int = 4
    /// Work sessions completed since the last long break; persisted so the
    /// long-break cycle survives app restarts. Reset when a long break fires.
    @AppStorage("pomodoro.sessionsInCycle") var sessionsInCycle: Int = 0
    @AppStorage("pomodoro.dndAutoToggle") var dndAutoToggle: Bool = false
    @AppStorage("pomodoro.alarmSoundName") var alarmSoundName: String = "Glass"
    @AppStorage("pomodoro.alarmVolume") var alarmVolume: Double = 0.8
    @AppStorage("pomodoro.enableReminders") var enableReminders: Bool = false {
        didSet { if enableReminders { fetchReminders() } else { loadRecentTasks() } }
    }
    @AppStorage("pomodoro.strictModeEnabled") var strictModeEnabled: Bool = false
    @AppStorage("pomodoro.targetCalendarID") var targetCalendarID: String = ""
    @AppStorage("pomodoro.breakTargetCalendarID") var breakTargetCalendarID: String = ""
    @AppStorage("pomodoro.calendarSource") var calendarSource: String = "mac"
    @AppStorage("pomodoro.todoSource") var todoSource: String = "reminders" {
        didSet { fetchReminders() }
    }
    @AppStorage("pomodoro.targetTodoList") var targetTodoList: String = "" {
        didSet { fetchReminders() }
    }
    
    // Alarm state
    @Published var showingAlert: Bool = false
    @Published var alertTitle: String = ""
    @Published var alertMessage: String = ""
    /// Paused mid-work with the abort confirmation UI showing — the user must
    /// choose to log partial progress, discard, or resume.
    @Published var isPausedConfirming: Bool = false
    
    // Custom Pomodoro task tracking properties
    @Published var currentTask: String = ""
    @Published var recentTasks: [String] = []
    var sessionStartDate: Date?
    /// Titles of tasks completed but not yet removed from the server-side list.
    /// Filters them out of refreshes for 30 s to prevent re-appearance.
    private var pendingCompletions: Set<String> = []

    /// Break activity selected by the user (e.g. "Stretch", "Walk").
    @Published var breakActivity: String = ""
    /// When the current break session actually started (for accurate calendar event duration).
    var breakSessionStart: Date?
    
    // EventKit store for Reminders
    private let eventStore = EKEventStore()
    private var reminderTasks: [String: EKReminder] = [:]
    
    /// Open-ended flow (∞ on the dial): the timer counts up from 0 until manually stopped.
    @AppStorage("pomodoro.infiniteFlow") var isInfiniteFlow: Bool = false {
        didSet {
            if !isRunning && sessionType == .work {
                timeRemaining = isInfiniteFlow ? 0 : workDuration
            }
        }
    }

    /// Seconds of work done in the current session — valid for both count-up and countdown.
    var elapsedWorkSeconds: Int {
        isInfiniteFlow ? timeRemaining : workDuration + extendedSeconds - timeRemaining
    }

    /// A work session that was started and not yet completed/discarded —
    /// running or merely paused. Paused sessions must keep showing the frozen
    /// timer, not the start page.
    var hasActiveWorkSession: Bool {
        sessionType == .work && sessionStartDate != nil
    }

    @Published var workDuration: Int = 25 * 60 {
        didSet {
            if !isRunning && sessionType == .work && !isInfiniteFlow {
                timeRemaining = workDuration
            }
        }
    }
    @Published var breakDuration: Int = 5 * 60 {
        didSet {
            if !isRunning && sessionType == .breakTime {
                timeRemaining = breakDuration
            }
        }
    }
    
    /// Shown by the one-minute-warning popup: offers to extend the running
    /// session before it ends. AppDelegate observes this to show/hide the
    /// prompt window.
    @Published var showExtendPrompt: Bool = false
    /// Seconds added via extendSession(by:) during the current session — kept
    /// separate from workDuration so the dial's preset is untouched and
    /// elapsed-time logging stays correct.
    private var extendedSeconds: Int = 0

    private var timer: AnyCancellable?
    private var lastUpdate: Date?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.timeRemaining = self.isInfiniteFlow ? 0 : self.workDuration
        
        // Observe history changes to keep counter accurate
        PomodoroHistoryManager.shared.$history
            .receive(on: RunLoop.main)
            .sink { [weak self] history in
                let calendar = Calendar.current
                self?.completedToday = history.filter { calendar.isDateInToday($0.startDate) }.count
            }
            .store(in: &cancellables)
            
        // Observe when available todo lists finish loading in the background on startup, then fetch the tasks
        JarviManager.shared.$availableTodoLists
            .receive(on: RunLoop.main)
            .sink { [weak self] lists in
                guard let self = self else { return }
                if JarviManager.shared.isLinked && self.todoSource == "jarvi" {
                    self.fetchReminders()
                }
            }
            .store(in: &cancellables)

        observeMidnight()
        observeSleepWake()
        setupJarviRemoteObserver()
        
        if enableReminders || JarviManager.shared.isLinked {
            fetchReminders()
        } else {
            loadRecentTasks()
        }
    }
    
    private func setupJarviRemoteObserver() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("JarviTokenChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchReminders()
        }
        
        NotificationCenter.default.addObserver(
            forName: Notification.Name("JarviTodosUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchReminders()
        }
        
        NotificationCenter.default.addObserver(
            forName: Notification.Name("JarviStartPomodoro"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let userInfo = notification.userInfo else { return }
            let title = userInfo["title"] as? String ?? ""
            let workMins = userInfo["workDurationMins"] as? Int ?? 25
            self.workDuration = workMins * 60
            if let breakMins = userInfo["breakDurationMins"] as? Int {
                self.breakDuration = max(0, breakMins) * 60
            }
            self.currentTask = title
            self.sessionType = .work
            self.reset()
            self.start()
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("JarviRemoteControl"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let userInfo = notification.userInfo else { return }
            let action = userInfo["action"] as? String ?? ""
            let components = userInfo["components"] as? URLComponents
            
            if action == "/start" {
                let title = components?.queryItems?.first(where: { $0.name == "title" })?.value ?? ""
                let durationStr = components?.queryItems?.first(where: { $0.name == "duration" })?.value
                let isBreak = components?.queryItems?.first(where: { $0.name == "isBreak" })?.value == "true" ||
                              components?.queryItems?.first(where: { $0.name == "type" })?.value == "break"
                
                if let durMins = durationStr, let mins = Int(durMins) {
                    if isBreak {
                        self.breakDuration = mins * 60
                    } else {
                        self.workDuration = mins * 60
                    }
                }
                
                self.currentTask = isBreak ? "" : title
                self.sessionType = isBreak ? .breakTime : .work
                self.reset()
                self.start()
            } else if action == "/pause" {
                if self.isRunning {
                    self.handleAbortClick()
                }
            } else if action == "/complete" || action == "/stop" {
                if self.isRunning {
                    self.completeSession()
                }
            } else if action == "/discard" {
                self.discardAndReset()
            }
        }
    }
    
    private func loadRecentTasks() {
        recentTasks = UserDefaults.standard.stringArray(forKey: "pomodoro.recentTasks") ?? []
    }
    
    // MARK: - Task Sources

    /// Refresh the task list from the configured source (Apple Reminders via
    /// EventKit, or Jarvi), falling back to the manually saved recents when
    /// no live source is enabled. Jarvi results are filtered against
    /// `pendingCompletions` so just-completed tasks don't reappear.
    func fetchReminders() {
        if !enableReminders && !JarviManager.shared.isLinked {
            loadRecentTasks()
            return
        }
        if todoSource == "reminders" {
            CalendarManager.shared.fetchRemindersFromEventKit(calendarID: targetTodoList) { [weak self] tasks in
                guard let self = self else { return }
                self.recentTasks = tasks
            }
        } else {
            JarviManager.shared.fetchTodos(list: targetTodoList) { [weak self] tasks in
                guard let self = self else { return }
                // Filter out tasks that were just completed but not yet removed server-side
                self.recentTasks = tasks.filter { fetchedTask in
                    !self.pendingCompletions.contains { pendingTask in
                        pendingTask.caseInsensitiveCompare(fetchedTask.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                    }
                }
            }
        }
    }
    
    private func fetchRemindersInternal() {
        fetchReminders()
    }

    /// Persist the current task to the local recents list (most recent first,
    /// capped at 10). No-op while a live todo source is active.
    func saveTaskToRecent() {
        if enableReminders || JarviManager.shared.isLinked { return } // Don't mix manual recent tasks with live Jarvi todos
        
        let title = currentTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        recentTasks.removeAll { $0 == title }
        recentTasks.insert(title, at: 0)
        if recentTasks.count > 10 { recentTasks = Array(recentTasks.prefix(10)) }
        UserDefaults.standard.set(recentTasks, forKey: "pomodoro.recentTasks")
    }

    /// Remove a task locally and mark it complete in the backing source.
    /// Deliberately skips an immediate Jarvi re-fetch — it races with
    /// completeGoogleTask and can wipe the list with stale data.
    func removeTaskFromRecent(_ title: String) {
        recentTasks.removeAll { $0 == title }
        UserDefaults.standard.set(recentTasks, forKey: "pomodoro.recentTasks")
        
        if todoSource == "reminders" {
            CalendarManager.shared.completeReminder(title: title, calendarID: targetTodoList)
        } else if todoSource != "jarvi" && !JarviManager.shared.isLinked {
            // Only send standalone TASK_COMPLETED webhook if completeGoogleTask was not/will not be called
            JarviManager.shared.sendEvent(type: "TASK_COMPLETED", sessionId: UUID().uuidString, title: title, list: targetTodoList)
        }
        
        if enableReminders {
            fetchReminders() // Refresh Apple Reminders (local, safe to re-fetch immediately)
        }
        // Jarvi todos: skip immediate re-fetch. The local removal above is already correct,
        // and an instant re-fetch races with completeGoogleTask — returning stale or empty
        // data that wipes the whole list.
    }
    
    /// Mark a task done everywhere it lives: the todo source, and — when it is
    /// the actively running session — the target calendar, local history, and
    /// streak. Registers the title as a pending completion so background
    /// refreshes don't resurrect it before the server catches up.
    func completeTask(_ title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskTitle = trimmedTitle.isEmpty ? "Completed Task" : trimmedTitle
        
        let isActiveSession = (title == currentTask) && (sessionStartDate != nil)
        
        // Calculate session durations if this was the active task running, or default duration
        let startDate = sessionStartDate ?? Date().addingTimeInterval(-Double(workDuration))
        let endDate = Date()
        let durationMinutes = sessionStartDate != nil ? max(1, Int(endDate.timeIntervalSince(startDate)) / 60) : max(1, workDuration / 60)
        
        if todoSource == "jarvi" || JarviManager.shared.isLinked {
            JarviManager.shared.completeGoogleTask(taskTitle: taskTitle, listId: targetTodoList, durationMinutes: durationMinutes)
        }
        
        if isActiveSession {
            // Log to target calendar when task is marked completed
            let cleanCalendarId = targetCalendarID.isEmpty ? "primary" : targetCalendarID
            if calendarSource == "jarvi" || calendarSource == "google" {
                JarviManager.shared.addGoogleCalendarEvent(title: taskTitle, startDate: startDate, endDate: endDate, calendarId: cleanCalendarId)
            } else {
                CalendarManager.shared.addEvent(title: taskTitle, startDate: startDate, endDate: endDate, calendarIdentifier: targetCalendarID)
            }
            
            // Log to local history database and streak
            let durationSeconds = max(60, Int(endDate.timeIntervalSince(startDate)))
            PomodoroHistoryManager.shared.logSession(title: taskTitle, startDate: startDate, endDate: endDate, durationSeconds: durationSeconds)
            StreakManager.shared.recordSession()
            
            if isRunning {
                pause()
            }
            sessionStartDate = nil
            currentTask = ""
        } else if title == currentTask {
            // It was the current task but no session started yet.
            currentTask = ""
        }
        
        // Optimistically remove from local list and track as pending completion
        // so it doesn't reappear when JarviTodosUpdated triggers a re-fetch
        pendingCompletions.insert(taskTitle)
        removeTaskFromRecent(title)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.pendingCompletions.remove(taskTitle)
        }
    }
    
    /// Complete whatever task is currently entered, if any.
    func completeCurrentTask() {
        let title = currentTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        completeTask(title)
    }

    // MARK: - Sleep/Wake Auto-Pause

    /// Auto-pause while the user is away. System sleep alone is NOT enough:
    /// in clamshell mode (external display + power) closing the lid never
    /// sleeps the Mac, so the timer would keep counting all night. Screen
    /// sleep covers that case. On return, the session resumes and the
    /// wall-clock anchors are shifted so logged durations exclude the gap.
    private var autoPauseStart: Date?

    /// Hook both system sleep AND display sleep notifications — see
    /// `autoPauseStart` for why display sleep matters (clamshell mode).
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.autoPauseForAbsence()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.autoResumeFromAbsence()
            }
        }
    }

    /// Silently pause when the machine or screens sleep and record when the
    /// gap began. Guarded so overlapping sleep notifications don't double-fire.
    private func autoPauseForAbsence() {
        guard isRunning, autoPauseStart == nil else { return }
        autoPauseStart = Date()
        pause(true) // silent — not a user action
    }

    /// Resume on wake, shifting the wall-clock anchors forward by the sleep
    /// gap so logged durations only count time actually spent at the Mac.
    private func autoResumeFromAbsence() {
        guard let pausedAt = autoPauseStart else { return }
        autoPauseStart = nil
        let gap = Date().timeIntervalSince(pausedAt)
        if gap > 0 {
            sessionStartDate = sessionStartDate?.addingTimeInterval(gap)
            breakSessionStart = breakSessionStart?.addingTimeInterval(gap)
        }
        start()
    }

    private func observeMidnight() {
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.completedToday = PomodoroHistoryManager.shared.todaysHistory.count
        }
    }

    // MARK: - Session Control

    /// Primary play/pause control for the UI.
    func toggle() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }
    
    /// Stop-button handler. Sessions of 10 seconds or less are treated as
    /// accidental clicks and auto-discarded without prompting; anything longer
    /// pauses and asks whether to log partial progress or discard.
    func handleAbortClick() {
        let elapsedSeconds = elapsedWorkSeconds

        // If under 10 seconds, immediately discard and reset without prompting
        if elapsedSeconds <= 10 {
            self.discardAndReset()
            return
        }
        
        // Pause the countdown immediately
        pause()
        isPausedConfirming = true
    }
    
    /// Log an interrupted session — calendar, local history, and Jarvi
    /// analytics, all tagged "(Partial)" — then reset. Sub-10-second sessions
    /// are discarded instead of logged.
    func logPartialProgress() {
        let elapsedSeconds = elapsedWorkSeconds
        guard elapsedSeconds > 10 else {
            discardAndReset()
            return
        }
        
        let startDate = sessionStartDate ?? Date().addingTimeInterval(-Double(elapsedSeconds))
        let endDate = Date()
        let durationMins = elapsedSeconds / 60
        
        let trimmedTask = currentTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskTitle = trimmedTask.isEmpty ? "FatCatFlow Session" : trimmedTask
        
        // Log to calendar
        if calendarSource == "jarvi" || calendarSource == "google" {
            JarviManager.shared.addGoogleCalendarEvent(title: "\(taskTitle) (Partial)", startDate: startDate, endDate: endDate, calendarId: targetCalendarID)
        } else {
            CalendarManager.shared.addEvent(title: "\(taskTitle) (Partial)", startDate: startDate, endDate: endDate, calendarIdentifier: targetCalendarID)
        }
        
        // Record local history database
        PomodoroHistoryManager.shared.logSession(title: "\(taskTitle) (Partial)", startDate: startDate, endDate: endDate, durationSeconds: elapsedSeconds)
        
        // Send to Jarvi by AsIfThatWorks
        JarviManager.shared.logPomodoroSession(durationMinutes: max(1, durationMins), taskName: taskTitle, interrupted: true)
        
        // Reset everything
        self.reset()
    }
    
    /// Abandon the session without logging it anywhere; also clears the task.
    func discardAndReset() {
        self.currentTask = ""
        self.reset()
    }
    
    /// Start or resume the current session. The first start of a work session
    /// stamps `sessionStartDate` and saves the task to recents; also toggles
    /// DND if enabled and announces FLOW_START/BREAK_START to Jarvi.
    func start() {
        isRunning = true
        isPausedConfirming = false
        lastUpdate = Date()

        if sessionType == .work {
            if sessionStartDate == nil {
                sessionStartDate = Date()
                saveTaskToRecent()
            }
            if dndAutoToggle { NotificationManager.shared.setDND(enabled: true) }
            let upcomingBreakMins = (sessionsInCycle + 1 >= sessionsUntilLongBreak) ? longBreakDuration / 60 : breakDuration / 60
            // 0 minutes signals an open-ended (∞) flow session
            JarviManager.shared.sendFatcatEvent("FLOW_START", title: currentTask, workDurationMins: isInfiniteFlow ? 0 : workDuration / 60, breakDurationMins: upcomingBreakMins)
        } else {
            // It's a break
            JarviManager.shared.sendFatcatEvent("BREAK_START")
        }
        
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }
    
    // silent=true for internal stops (completeSession, startWorkSession) — no outbound event.
    /// Stop the countdown. The `silent` flag suppresses the outbound Jarvi
    /// pause event — used when a different event (e.g. COMPLETED) is emitted
    /// by the caller instead.
    func pause(_ silent: Bool = false) {
        if isRunning && !silent {
            if sessionType == .work {
                JarviManager.shared.sendFatcatEvent("FLOW_PAUSE", title: currentTask, workDurationMins: workDuration / 60, breakDurationMins: breakDuration / 60)
            } else {
                JarviManager.shared.sendFatcatEvent("BREAK_PAUSE")
            }
        }
        isRunning = false
        showExtendPrompt = false
        timer?.cancel()
        timer = nil
        if dndAutoToggle { NotificationManager.shared.setDND(enabled: false) }
    }

    /// Start a break and associate it with a chosen activity title.
    /// Calling this when a break is already running just updates the activity label.
    func startBreakWithActivity(_ activity: String) {
        breakActivity = activity
        if sessionType != .breakTime {
            sessionType = .breakTime
            timeRemaining = breakDuration
        }
        if !isRunning {
            breakSessionStart = Date()
            start()
        } else if breakSessionStart == nil {
            breakSessionStart = Date()
        }
    }
    
    /// Return the current session type to its idle, full-duration state
    /// (0 for ∞ flow, which counts up).
    func reset() {
        pause()
        isPausedConfirming = false
        showExtendPrompt = false
        extendedSeconds = 0
        sessionStartDate = nil
        if sessionType == .work {
            timeRemaining = isInfiniteFlow ? 0 : workDuration
        } else {
            timeRemaining = breakDuration
        }
    }
    
    /// Extend the running session from the one-minute-warning popup. The
    /// added time is tracked separately so logging and the progress ring stay
    /// accurate and the dial's configured duration is untouched.
    func extendSession(by minutes: Int) {
        defer { showExtendPrompt = false }
        guard isRunning, minutes > 0 else { return }
        timeRemaining += minutes * 60
        if !(isInfiniteFlow && sessionType == .work) {
            extendedSeconds += minutes * 60
        }
    }

    /// Asymmetric by design: skipping work completes the session (full
    /// logging fan-out via completeSession), while skipping a break just
    /// starts the next work session without logging.
    func skip() {
        isPausedConfirming = false
        if sessionType == .work {
            completeSession()
        } else {
            startWorkSession()
        }
    }
    
    /// One-second heartbeat: counts up in ∞ flow, otherwise counts down and
    /// rolls into the next phase at zero. Also drives strict-mode browser-tab
    /// enforcement every 5 seconds during work.
    private func tick() {
        // Infinite flow: count upwards until the user stops the session
        if isInfiniteFlow && sessionType == .work {
            timeRemaining += 1
            if strictModeEnabled && timeRemaining % 5 == 0 {
                enforceStrictMode()
            }
            return
        }
        if timeRemaining > 0 {
            timeRemaining -= 1
            // One-minute warning: offer to extend before the session rolls
            // over. Re-fires after an extension when 60 s is reached again.
            if timeRemaining == 60 {
                showExtendPrompt = true
            }
            if strictModeEnabled && sessionType == .work && timeRemaining % 5 == 0 {
                enforceStrictMode()
            }
        } else {
            showExtendPrompt = false
            if sessionType == .work {
                completeSession()
            } else {
                startWorkSession()
            }
        }
    }
    
    private func enforceStrictMode() {
        let script = """
        set blocklist to {"youtube.com", "twitter.com", "x.com", "facebook.com", "reddit.com", "instagram.com"}
        
        -- Safari
        if application "Safari" is running then
            tell application "Safari"
                set winList to every window
                repeat with win in winList
                    set tabList to every tab of win
                    repeat with t in tabList
                        set tabURL to URL of t
                        repeat with blockedDomain in blocklist
                            if tabURL contains blockedDomain then
                                close t
                                exit repeat
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end if
        
        -- Google Chrome
        if application "Google Chrome" is running then
            tell application "Google Chrome"
                set winList to every window
                repeat with win in winList
                    set tabList to every tab of win
                    repeat with t in tabList
                        set tabURL to URL of t
                        repeat with blockedDomain in blocklist
                            if tabURL contains blockedDomain then
                                close t
                                exit repeat
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end if
        """
        
        DispatchQueue.global(qos: .background).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }
    
    /// Finish a work session: fan out to Jarvi analytics/events, the chosen
    /// calendar (EventKit or Jarvi/Google), local history, and the streak,
    /// then advance the long-break cycle and queue the appropriate break.
    /// Called on a break, it simply defers to startWorkSession().
    private func completeSession() {
        pause(true) // silent: COMPLETED event is sent below, not FLOW_PAUSE
        isPausedConfirming = false
        showExtendPrompt = false
        extendedSeconds = 0
        if sessionType == .work {
            sessionsInCycle += 1
            
            let trimmedTask = currentTask.trimmingCharacters(in: .whitespacesAndNewlines)
            let taskTitle = trimmedTask.isEmpty ? "FatCatFlow Session" : trimmedTask

            // Actual focused time — equals the planned duration at natural
            // completion, the counted-up time for ∞, and the partial time
            // when the user hits Finish early.
            let flowSeconds = elapsedWorkSeconds
            let flowMins = max(1, flowSeconds / 60)

            JarviManager.shared.logPomodoroSession(durationMinutes: flowMins, taskName: taskTitle, interrupted: false)
            JarviManager.shared.sendFatcatEvent("COMPLETED", title: taskTitle, workDurationMins: flowMins, breakDurationMins: breakDuration / 60)

            // If not linked to Jarvi, we send FLOW_END as a fallback webhook.
            // If linked, logPomodoroSession (analytics) and the Calendar block are sufficient.
            if !(todoSource == "jarvi" || JarviManager.shared.isLinked) {
                JarviManager.shared.sendEvent(type: "FLOW_END", sessionId: UUID().uuidString, title: taskTitle, workMins: flowMins, breakMins: breakDuration / 60)
            }

            // Capture date bounds and durations
            let startDate = sessionStartDate ?? Date().addingTimeInterval(-Double(flowSeconds))
            let endDate = Date()
            let duration = Int(endDate.timeIntervalSince(startDate))
            
            // Trigger calendar event creation based on selected source
            let cleanCalendarId = targetCalendarID.isEmpty ? "primary" : targetCalendarID
            if calendarSource == "jarvi" || calendarSource == "google" {
                JarviManager.shared.addGoogleCalendarEvent(title: taskTitle, startDate: startDate, endDate: endDate, calendarId: cleanCalendarId)
            } else {
                CalendarManager.shared.addEvent(title: taskTitle, startDate: startDate, endDate: endDate, calendarIdentifier: targetCalendarID)
            }
            
            // Record local history database
            PomodoroHistoryManager.shared.logSession(title: taskTitle, startDate: startDate, endDate: endDate, durationSeconds: duration)
            StreakManager.shared.recordSession()
            
            sessionStartDate = nil
            
            alertTitle = "Flow Session Complete 😺"
            alertMessage = sessionsInCycle >= sessionsUntilLongBreak ? "Time for a LONG break! You earned it." : "Time for a break! Your fat cat is waiting."
            showingAlert = true
            
            NotificationManager.shared.sessionComplete(isBreak: true)
            sessionType = .breakTime
            
            if sessionsInCycle >= sessionsUntilLongBreak {
                timeRemaining = longBreakDuration
                sessionsInCycle = 0 // Reset cycle
            } else {
                timeRemaining = breakDuration
            }
            
            if autoStartBreak { start() }
        } else {
            startWorkSession()
        }
    }
    
    /// End the break — logging the chosen activity to the calendar, honoring
    /// the Pro break-calendar override — and arm a fresh work session.
    private func startWorkSession() {
        pause(true) // silent: break ending naturally, not a user pause
        isPausedConfirming = false
        showExtendPrompt = false
        extendedSeconds = 0

        // Log break activity to calendar if user chose one
        let breakEnd = Date()
        let breakStart = breakSessionStart ?? breakEnd.addingTimeInterval(-Double(breakDuration))
        let activityTitle = breakActivity.isEmpty ? "Break" : "\(breakActivity) Break"
        if !breakActivity.isEmpty {
            Task { @MainActor in
                let actualBreakID = StoreManager.shared.isUnlocked ? breakTargetCalendarID : ""
                let actualTargetCalendarID = actualBreakID.isEmpty ? targetCalendarID : actualBreakID
                let cleanCalendarId = actualTargetCalendarID.isEmpty ? "primary" : actualTargetCalendarID
                if calendarSource == "jarvi" || calendarSource == "google" {
                    JarviManager.shared.addGoogleCalendarEvent(title: activityTitle, startDate: breakStart, endDate: breakEnd, calendarId: cleanCalendarId)
                } else {
                    CalendarManager.shared.addEvent(title: activityTitle, startDate: breakStart, endDate: breakEnd, calendarIdentifier: actualTargetCalendarID)
                }
            }
        }
        breakActivity = ""
        breakSessionStart = nil

        JarviManager.shared.sendFatcatEvent("BREAK_END")
        JarviManager.shared.sendEvent(type: "BREAK_END", sessionId: UUID().uuidString, title: activityTitle, workMins: workDuration / 60, breakMins: breakDuration / 60)
        
        currentTask = ""
        sessionStartDate = nil
        
        alertTitle = "Break's Over 😸"
        alertMessage = "Ready for another flow session?"
        showingAlert = true
        
        NotificationManager.shared.sessionComplete(isBreak: false)
        sessionType = .work
        timeRemaining = isInfiniteFlow ? 0 : workDuration
        if autoStartWork { start() }
    }
    
    var timeString: String {
        let totalSeconds = abs(timeRemaining)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var progress: Double {
        if isInfiniteFlow && sessionType == .work { return 0 } // no end → no ring
        let base = sessionType == .work ? Double(workDuration) : Double(breakDuration)
        let total = base + Double(extendedSeconds) // extensions stretch the ring, not rewind it
        guard total > 0 else { return 0 }
        return 1.0 - (Double(timeRemaining) / total)
    }
}
