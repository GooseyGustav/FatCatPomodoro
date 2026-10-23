import Foundation
import EventKit

/// EventKit facade for local calendars and Apple Reminders. The app
/// deliberately delegates cloud sync to macOS — iCloud/Google/Exchange
/// accounts configured in System Settings surface here as EKCalendars —
/// instead of shipping per-provider API clients.
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()
    
    let eventStore = EKEventStore()
    @Published var availableCalendars: [EKCalendar] = []
    @Published var availableTodoLists: [EKCalendar] = []
    
    private init() {
        requestAccess()
        requestReminderAccess()
    }
    
    /// Ensure calendar authorization, prompting only when needed; populates
    /// `availableCalendars` on success. Handles both the macOS 14
    /// fullAccess/writeOnly model and the legacy `.authorized` raw value.
    func requestAccess(completion: @escaping (Bool) -> Void = { _ in }) {
        let status = EKEventStore.authorizationStatus(for: .event)
        let hasAccess: Bool
        if #available(macOS 14.0, *) {
            hasAccess = (status == .fullAccess || status == .writeOnly)
        } else {
            hasAccess = (status.rawValue == 3)
        }
        
        if hasAccess {
            fetchCalendars()
            completion(true)
            return
        }
        
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                if granted { self?.fetchCalendars() }
                completion(granted)
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                if granted { self?.fetchCalendars() }
                completion(granted)
            }
        }
    }
    
    /// Reminders counterpart of `requestAccess`; populates
    /// `availableTodoLists` on success.
    func requestReminderAccess(completion: @escaping (Bool) -> Void = { _ in }) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let hasAccess: Bool
        if #available(macOS 14.0, *) {
            hasAccess = (status == .fullAccess || status == .writeOnly)
        } else {
            hasAccess = (status.rawValue == 3)
        }
        
        if hasAccess {
            fetchTodoLists()
            completion(true)
            return
        }
        
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { [weak self] granted, error in
                if granted { self?.fetchTodoLists() }
                completion(granted)
            }
        } else {
            eventStore.requestAccess(to: .reminder) { [weak self] granted, error in
                if granted { self?.fetchTodoLists() }
                completion(granted)
            }
        }
    }
    
    /// Load event calendars, preferring writable ones but falling back to the
    /// full list so the picker is never empty on read-only accounts.
    func fetchCalendars() {
        DispatchQueue.main.async {
            let all = self.eventStore.calendars(for: .event)
            let modifiable = all.filter { $0.allowsContentModifications }
            self.availableCalendars = modifiable.isEmpty ? all : modifiable
        }
    }
    
    /// Load reminder lists, with the same writable-first fallback as
    /// `fetchCalendars()`.
    func fetchTodoLists() {
        DispatchQueue.main.async {
            let all = self.eventStore.calendars(for: .reminder)
            let modifiable = all.filter { $0.allowsContentModifications }
            self.availableTodoLists = modifiable.isEmpty ? all : modifiable
        }
    }
    
    /// Save a session event, requesting access on demand and retrying once
    /// granted. Falls back from the requested calendar to the system default,
    /// then to any writable calendar, so a stale or read-only
    /// `calendarIdentifier` never silently loses the event.
    func addEvent(title: String, startDate: Date, endDate: Date, calendarIdentifier: String?) {
        let status = EKEventStore.authorizationStatus(for: .event)
        let hasAccess: Bool
        if #available(macOS 14.0, *) {
            hasAccess = (status == .fullAccess || status == .writeOnly)
        } else {
            hasAccess = (status.rawValue == 3)
        }
        guard hasAccess else {
            print("CalendarManager: No access to calendars. Prompting for access.")
            requestAccess { granted in
                if granted {
                    self.addEvent(title: title, startDate: startDate, endDate: endDate, calendarIdentifier: calendarIdentifier)
                }
            }
            return
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        
        var targetCalendar: EKCalendar? = nil
        if let id = calendarIdentifier, !id.isEmpty {
            targetCalendar = eventStore.calendar(withIdentifier: id)
        }
        if targetCalendar == nil || targetCalendar?.allowsContentModifications == false {
            targetCalendar = eventStore.defaultCalendarForNewEvents
        }
        if targetCalendar == nil || targetCalendar?.allowsContentModifications == false {
            targetCalendar = eventStore.calendars(for: .event).first(where: { $0.allowsContentModifications })
        }
        
        guard let calendar = targetCalendar, calendar.allowsContentModifications else {
            print("CalendarManager: No writable calendar found to save event \"\(title)\".")
            return
        }
        
        event.calendar = calendar
        
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            print("CalendarManager: Successfully saved event \"\(title)\" to \(calendar.title)")
        } catch {
            print("CalendarManager: Failed to save event: \(error)")
        }
    }
    
    /// Fetch incomplete reminder titles from one list (or all lists when
    /// `calendarID` is empty), requesting access first if needed. The
    /// completion is always delivered on the main queue.
    func fetchRemindersFromEventKit(calendarID: String = "", completion: @escaping ([String]) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let hasAccess: Bool
        if #available(macOS 14.0, *) {
            hasAccess = (status == .fullAccess || status == .writeOnly)
        } else {
            hasAccess = (status.rawValue == 3)
        }
        guard hasAccess else {
            requestReminderAccess { granted in
                if granted {
                    self.fetchRemindersFromEventKit(calendarID: calendarID, completion: completion)
                } else {
                    DispatchQueue.main.async { completion([]) }
                }
            }
            return
        }
        
        var calendars: [EKCalendar]? = nil
        if !calendarID.isEmpty, let cal = eventStore.calendar(withIdentifier: calendarID) {
            calendars = [cal]
        }
        
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        eventStore.fetchReminders(matching: predicate) { reminders in
            let titles = reminders?.compactMap { $0.title } ?? []
            DispatchQueue.main.async {
                completion(titles)
            }
        }
    }
    
    /// Mark the first incomplete reminder matching `title` as completed.
    /// Matches by exact title because the app tracks tasks as plain strings,
    /// not EventKit identifiers.
    func completeReminder(title: String, calendarID: String?) {
        var calendars: [EKCalendar]? = nil
        if let cid = calendarID, !cid.isEmpty, let cal = eventStore.calendar(withIdentifier: cid) {
            calendars = [cal]
        }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        eventStore.fetchReminders(matching: predicate) { reminders in
            if let reminder = reminders?.first(where: { $0.title == title }) {
                reminder.isCompleted = true
                do {
                    try self.eventStore.save(reminder, commit: true)
                    print("CalendarManager: Completed reminder \"\(title)\"")
                } catch {
                    print("Error completing reminder in EventKit: \(error)")
                }
            }
        }
    }
}
