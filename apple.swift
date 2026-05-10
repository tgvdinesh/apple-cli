// apple.swift — Unified Apple OS CLI (Reminders, Calendar, Notes)
//
// Build: swiftc apple.swift -o apple
//
// REMINDERS
//   apple reminders list
//   apple reminders list-items "List" [--all]
//   apple reminders create "List" "Title" [--due YYYY-MM-DD | "YYYY-MM-DD HH:MM"]
//   apple reminders complete "List" "Title"
//   apple reminders delete "List" "Title"
//   apple reminders clear "List"
//   apple reminders search "text"
//
// CALENDAR
//   apple calendar list
//   apple calendar events [--days N]            (default 7)
//   apple calendar create "Title" --date "YYYY-MM-DD HH:MM" [--calendar "name"] [--duration N] [--notes "text"]
//
// NOTES
//   apple notes list [--folder "name"]
//   apple notes read "Title"
//   apple notes create "Title" "Body" [--folder "name"]
//   apple notes search "text"

import EventKit
import Foundation

// MARK: - Globals

let store = EKEventStore()
let sema = DispatchSemaphore(value: 0)
let args = CommandLine.arguments

// MARK: - Helpers

func fail(_ msg: String) -> Never {
    fputs("Error: \(msg)\n", stderr)
    exit(1)
}

func usage() -> Never {
    print("""
apple <domain> <command> [args]

Domains: reminders, calendar, notes

REMINDERS
  apple reminders list
  apple reminders list-items "List" [--all]
  apple reminders create "List" "Title" [--due YYYY-MM-DD]
  apple reminders complete "List" "Title"
  apple reminders delete "List" "Title"
  apple reminders clear "List"
  apple reminders search "text"

CALENDAR
  apple calendar list
  apple calendar events [--days N]
  apple calendar create "Title" --date "YYYY-MM-DD HH:MM" [--calendar "name"] [--duration N] [--notes "text"]

NOTES
  apple notes list [--folder "name"]
  apple notes read "Title"
  apple notes create "Title" "Body" [--folder "name"]
  apple notes search "text"
""")
    exit(0)
}

func arg(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else { return nil }
    return args[args.index(after: i)]
}

func parseDate(_ s: String) -> DateComponents? {
    for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        let df = DateFormatter()
        df.dateFormat = fmt
        if let d = df.date(from: s) {
            return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        }
    }
    return nil
}

func shortDate(_ d: Date) -> String {
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .short
    return df.string(from: d)
}

// MARK: - AppleScript runner (for Notes)

func runScript(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func escapeAS(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

// MARK: - EventKit: shared access

func withRemindersAccess(_ block: @escaping () -> Void) {
    store.requestFullAccessToReminders { granted, _ in
        guard granted else { fail("Reminders access denied — grant permission in System Settings > Privacy > Reminders") }
        block()
    }
}

func withCalendarAccess(_ block: @escaping () -> Void) {
    store.requestFullAccessToEvents { granted, _ in
        guard granted else { fail("Calendar access denied — grant permission in System Settings > Privacy > Calendars") }
        block()
    }
}

// MARK: - Reminders helpers

func reminderCalendars() -> [EKCalendar] {
    store.calendars(for: .reminder).sorted { $0.title < $1.title }
}

func reminderCalendar(named name: String) -> EKCalendar? {
    store.calendars(for: .reminder).first { $0.title.lowercased() == name.lowercased() }
}

func fetchReminders(in cal: EKCalendar, completion: @escaping ([EKReminder]) -> Void) {
    store.fetchReminders(matching: store.predicateForReminders(in: [cal])) { completion($0 ?? []) }
}

// MARK: - Reminders commands

func remindersCommand(_ cmd: String) {
    switch cmd {

    case "list":
        withRemindersAccess {
            let cals = reminderCalendars()
            let group = DispatchGroup()
            var results = [(String, Int, Int)]()
            let lock = NSLock()
            for cal in cals {
                group.enter()
                fetchReminders(in: cal) { rem in
                    let inc = rem.filter { !$0.isCompleted }.count
                    let comp = rem.filter { $0.isCompleted }.count
                    lock.lock(); results.append((cal.title, inc, comp)); lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                for (title, inc, comp) in results.sorted(by: { $0.0 < $1.0 }) {
                    print("\(title)  incomplete:\(inc)  completed:\(comp)")
                }
                sema.signal()
            }
        }

    case "list-items":
        guard args.count >= 4 else { fail("Usage: apple reminders list-items \"List\" [--all]") }
        let listName = args[3]
        let showAll = args.contains("--all")
        withRemindersAccess {
            guard let cal = reminderCalendar(named: listName) else { fail("List '\(listName)' not found") }
            fetchReminders(in: cal) { rem in
                let items = (showAll ? rem : rem.filter { !$0.isCompleted })
                    .sorted { ($0.title ?? "") < ($1.title ?? "") }
                if items.isEmpty { print("(empty)") }
                for r in items {
                    let status = r.isCompleted ? "[x]" : "[ ]"
                    var due = ""
                    if let dc = r.dueDateComponents, let d = Calendar.current.date(from: dc) {
                        due = "  due:\(shortDate(d))"
                    }
                    print("\(status) \(r.title ?? "(no title)")\(due)")
                }
                sema.signal()
            }
        }

    case "create":
        guard args.count >= 5 else { fail("Usage: apple reminders create \"List\" \"Title\" [--due YYYY-MM-DD]") }
        let listName = args[3]; let title = args[4]
        var dc: DateComponents? = nil
        if let dateStr = arg(after: "--due") { dc = parseDate(dateStr) ?? { fail("Invalid date. Use YYYY-MM-DD or 'YYYY-MM-DD HH:MM'") }() }
        withRemindersAccess {
            guard let cal = reminderCalendar(named: listName) else { fail("List '\(listName)' not found") }
            let r = EKReminder(eventStore: store)
            r.title = title; r.calendar = cal; r.dueDateComponents = dc
            try? store.save(r, commit: true)
            print("Created: \(title)")
            sema.signal()
        }

    case "complete":
        guard args.count >= 5 else { fail("Usage: apple reminders complete \"List\" \"Title\"") }
        let listName = args[3]; let title = args[4]
        withRemindersAccess {
            guard let cal = reminderCalendar(named: listName) else { fail("List '\(listName)' not found") }
            fetchReminders(in: cal) { rem in
                guard let r = rem.first(where: { $0.title?.lowercased() == title.lowercased() && !$0.isCompleted }) else {
                    fail("Reminder '\(title)' not found in '\(listName)'")
                }
                r.isCompleted = true
                try? store.save(r, commit: true)
                print("Completed: \(title)")
                sema.signal()
            }
        }

    case "delete":
        guard args.count >= 5 else { fail("Usage: apple reminders delete \"List\" \"Title\"") }
        let listName = args[3]; let title = args[4]
        withRemindersAccess {
            guard let cal = reminderCalendar(named: listName) else { fail("List '\(listName)' not found") }
            fetchReminders(in: cal) { rem in
                guard let r = rem.first(where: { $0.title?.lowercased() == title.lowercased() }) else {
                    fail("Reminder '\(title)' not found in '\(listName)'")
                }
                try? store.remove(r, commit: true)
                print("Deleted: \(title)")
                sema.signal()
            }
        }

    case "clear":
        guard args.count >= 4 else { fail("Usage: apple reminders clear \"List\"") }
        let listName = args[3]
        withRemindersAccess {
            guard let cal = reminderCalendar(named: listName) else { fail("List '\(listName)' not found") }
            fetchReminders(in: cal) { rem in
                for r in rem { try? store.remove(r, commit: false) }
                try? store.commit()
                print("Cleared \(rem.count) reminder(s) from '\(listName)'")
                sema.signal()
            }
        }

    case "search":
        guard args.count >= 4 else { fail("Usage: apple reminders search \"text\"") }
        let query = args[3].lowercased()
        withRemindersAccess {
            let cals = reminderCalendars()
            let group = DispatchGroup()
            var results = [(String, String, Bool)]()
            let lock = NSLock()
            for cal in cals {
                group.enter()
                fetchReminders(in: cal) { rem in
                    let hits = rem.filter { ($0.title ?? "").lowercased().contains(query) }
                    lock.lock(); hits.forEach { results.append((cal.title, $0.title ?? "", $0.isCompleted)) }; lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                if results.isEmpty { print("No results for '\(query)'") }
                for (list, title, done) in results.sorted(by: { $0.0 < $1.0 }) {
                    print("\(done ? "[x]" : "[ ]") [\(list)] \(title)")
                }
                sema.signal()
            }
        }

    default:
        fail("Unknown reminders command '\(cmd)'. Run 'apple' for usage.")
    }
}

// MARK: - Calendar commands

func calendarCommand(_ cmd: String) {
    switch cmd {

    case "list":
        withCalendarAccess {
            let cals = store.calendars(for: .event).sorted { $0.title < $1.title }
            for cal in cals { print("• \(cal.title)") }
            sema.signal()
        }

    case "events":
        let days = Int(arg(after: "--days") ?? "7") ?? 7
        withCalendarAccess {
            let now = Date()
            let end = Calendar.current.date(byAdding: .day, value: days, to: now)!
            let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
            if events.isEmpty { print("No events in the next \(days) days") }
            for e in events {
                let cal = e.calendar.title
                let start = shortDate(e.startDate)
                print("[\(cal)] \(e.title ?? "(no title)")  —  \(start)")
                if let notes = e.notes, !notes.isEmpty { print("  Notes: \(notes)") }
            }
            sema.signal()
        }

    case "create":
        guard args.count >= 4 else { fail("Usage: apple calendar create \"Title\" --date \"YYYY-MM-DD HH:MM\" [--calendar name] [--duration N] [--notes text]") }
        let title = args[3]
        guard let dateStr = arg(after: "--date"), let dc = parseDate(dateStr),
              let startDate = Calendar.current.date(from: dc) else {
            fail("--date is required. Format: YYYY-MM-DD HH:MM")
        }
        let calName = arg(after: "--calendar")
        let duration = Int(arg(after: "--duration") ?? "60") ?? 60
        let notes = arg(after: "--notes")
        withCalendarAccess {
            let cal: EKCalendar
            if let name = calName {
                guard let found = store.calendars(for: .event).first(where: { $0.title.lowercased() == name.lowercased() }) else {
                    fail("Calendar '\(name)' not found")
                }
                cal = found
            } else {
                cal = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first!
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(TimeInterval(duration * 60))
            event.calendar = cal
            event.notes = notes
            try? store.save(event, span: .thisEvent, commit: true)
            print("Created event '\(title)' on \(shortDate(startDate)) in '\(cal.title)'")
            sema.signal()
        }

    default:
        fail("Unknown calendar command '\(cmd)'. Run 'apple' for usage.")
    }
}

// MARK: - Notes commands (via AppleScript)

func notesCommand(_ cmd: String) {
    switch cmd {

    case "list":
        let folder = arg(after: "--folder")
        let script: String
        if let f = folder {
            script = """
            tell application "Notes"
                set output to ""
                repeat with n in notes of folder "\(escapeAS(f))"
                    set output to output & name of n & "\n"
                end repeat
                return output
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                set output to ""
                repeat with n in notes
                    set output to output & name of n & "\n"
                end repeat
                return output
            end tell
            """
        }
        let result = runScript(script)
        if result.isEmpty { print("(no notes)") } else { print(result) }
        sema.signal()

    case "read":
        guard args.count >= 4 else { fail("Usage: apple notes read \"Title\"") }
        let title = escapeAS(args[3])
        let script = """
        tell application "Notes"
            set n to first note whose name is "\(title)"
            return body of n
        end tell
        """
        let result = runScript(script)
        if result.isEmpty { print("(note not found or empty)") } else { print(result) }
        sema.signal()

    case "create":
        guard args.count >= 5 else { fail("Usage: apple notes create \"Title\" \"Body\" [--folder \"name\"]") }
        let title = escapeAS(args[3])
        let body = escapeAS(args[4])
        let folder = arg(after: "--folder") ?? "Notes"
        let script = """
        tell application "Notes"
            make new note at folder "\(escapeAS(folder))" with properties {name:"\(title)", body:"\(body)"}
        end tell
        """
        _ = runScript(script)
        print("Created note '\(args[3])' in '\(folder)'")
        sema.signal()

    case "search":
        guard args.count >= 4 else { fail("Usage: apple notes search \"text\"") }
        let query = escapeAS(args[3])
        let script = """
        tell application "Notes"
            set output to ""
            repeat with n in notes
                if name of n contains "\(query)" or body of n contains "\(query)" then
                    set output to output & name of n & "\n"
                end if
            end repeat
            return output
        end tell
        """
        let result = runScript(script)
        if result.isEmpty { print("No notes matching '\(args[3])'") } else { print(result) }
        sema.signal()

    default:
        fail("Unknown notes command '\(cmd)'. Run 'apple' for usage.")
    }
}

// MARK: - Main

guard args.count >= 3 else { usage() }
let domain = args[1]
let command = args[2]

switch domain {
case "reminders": remindersCommand(command)
case "calendar":  calendarCommand(command)
case "notes":     notesCommand(command)
default:          fail("Unknown domain '\(domain)'. Use: reminders, calendar, notes")
}

sema.wait()
