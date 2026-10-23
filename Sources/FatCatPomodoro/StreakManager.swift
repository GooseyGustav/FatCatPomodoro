import Foundation

/// Tracks consecutive-day focus streaks, persisted in UserDefaults under `streak.*` keys.
/// A streak counts calendar days with at least one completed session, not session counts.
class StreakManager: ObservableObject {
    static let shared = StreakManager()

    @Published private(set) var currentStreak: Int
    @Published private(set) var longestStreak: Int
    private var lastCompletionDate: Date?

    private init() {
        currentStreak = UserDefaults.standard.integer(forKey: "streak.current")
        longestStreak = UserDefaults.standard.integer(forKey: "streak.longest")
        lastCompletionDate = UserDefaults.standard.object(forKey: "streak.lastCompletionDate") as? Date
    }

    /// Records a completed session toward the streak. Same-day completions are ignored
    /// (a day only counts once); a completion the day after the last one extends the streak;
    /// any longer gap resets it to 1. Longest streak and last-completion date are persisted.
    func recordSession() {
        let calendar = Calendar.current
        let today = Date()

        if let last = lastCompletionDate {
            if calendar.isDateInToday(last) {
                return // already counted today
            } else if calendar.isDateInYesterday(last) {
                currentStreak += 1
            } else {
                currentStreak = 1
            }
        } else {
            currentStreak = 1
        }

        longestStreak = max(longestStreak, currentStreak)
        lastCompletionDate = today

        UserDefaults.standard.set(currentStreak, forKey: "streak.current")
        UserDefaults.standard.set(longestStreak, forKey: "streak.longest")
        UserDefaults.standard.set(today, forKey: "streak.lastCompletionDate")
    }

    var catEmoji: String {
        return "😺" // Real face cat only, no variety
    }

    var catName: String {
        return "Fat Cat"
    }
}
