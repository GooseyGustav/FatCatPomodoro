import Foundation

// Music add-on excluded — stub kept so the type name remains available if referenced elsewhere.
/// Intentional stub: the music add-on is excluded from the current release,
/// but the singleton is kept so existing call sites keep compiling.
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    private init() {}
}
