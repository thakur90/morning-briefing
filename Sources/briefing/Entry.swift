import BriefingCore
import Foundation

@main
enum Entry {
    static func main() async {
        // Launched by macOS with no arguments (e.g. a notification clicked while the
        // agent wasn't running): open today's briefing instead of printing usage.
        if CommandLine.arguments.count == 1, NotificationAccess.isAvailable, isatty(STDIN_FILENO) == 0 {
            if let page = todaysPage() { openFile(page) }
            return
        }
        await Briefing.main()
    }
}
