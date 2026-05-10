// apple.swift — Unified macOS CLI for Reminders, Calendar, and Notes
//
// Build:   swiftc apple.swift -o apple
// Install: make install
//
// All three domains use AppleScript via osascript — no EventKit TCC prompts needed.
// Permissions are handled by Reminders, Calendar, and Notes apps themselves.
//
// REMINDERS
//   apple reminders list
//   apple reminders list-items "List" [--all]
//   apple reminders create "List" "Title" [--due YYYY-MM-DD]
//   apple reminders complete "List" "Title"
//   apple reminders delete "List" "Title"
//   apple reminders clear "List"
//   apple reminders search "text"
//
// CALENDAR
//   apple calendar list
//   apple calendar events [--days N]             (default 7)
//   apple calendar create "Title" --date "YYYY-MM-DD HH:MM" [--calendar "name"] [--duration N] [--notes "text"]
//
// NOTES
//   apple notes list [--folder "name"]
//   apple notes read "Title"
//   apple notes create "Title" "Body" [--folder "name"]
//   apple notes search "text"

import Foundation

// MARK: - Globals

let args = CommandLine.arguments

// MARK: - Helpers

func fail(_ msg: String) -> Never {
    fputs("Error: \(msg)\n", stderr)
    exit(1)
}

func usage() -> Never {
    print("""
apple <domain> <command> [args]

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

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

// MARK: - AppleScript runner

@discardableResult
func run(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try? p.run()
    p.waitUntilExit()
    let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errOut = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if p.terminationStatus != 0 && !errOut.isEmpty {
        fputs("AppleScript error: \(errOut)\n", stderr)
    }
    return output
}

// MARK: - Date parsing

struct ParsedDate {
    var year, month, day, hour, minute: Int
}

func parseDate(_ s: String) -> ParsedDate? {
    let fmts = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
    for fmt in fmts {
        let df = DateFormatter()
        df.dateFormat = fmt
        if let d = df.date(from: s) {
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            return ParsedDate(
                year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                hour: c.hour ?? 0, minute: c.minute ?? 0
            )
        }
    }
    return nil
}

// MARK: - Reminders

func remindersCommand(_ cmd: String) {
    switch cmd {

    case "list":
        let result = run("""
        tell application "Reminders"
            set output to ""
            repeat with l in lists
                set incomplete to count (reminders of l whose completed is false)
                set completed to count (reminders of l whose completed is true)
                set output to output & name of l & "  incomplete:" & incomplete & "  completed:" & completed & "\\n"
            end repeat
            return output
        end tell
        """)
        print(result.isEmpty ? "(no lists)" : result)

    case "list-items":
        guard args.count >= 4 else { fail("Usage: apple reminders list-items \"List\" [--all]") }
        let list = esc(args[3])
        let showAll = args.contains("--all")
        let filter = showAll ? "" : "whose completed is false"
        let result = run("""
        tell application "Reminders"
            set output to ""
            repeat with r in (reminders of list "\(list)" \(filter))
                set status to "[x] "
                if completed of r is false then set status to "[ ] "
                set output to output & status & name of r & "\\n"
            end repeat
            return output
        end tell
        """)
        print(result.isEmpty ? "(empty)" : result)

    case "create":
        guard args.count >= 5 else { fail("Usage: apple reminders create \"List\" \"Title\" [--due YYYY-MM-DD]") }
        let list = esc(args[3]); let title = esc(args[4])
        var script = """
        tell application "Reminders"
            with timeout of 10 seconds
                make new reminder in list "\(list)" with properties {name:"\(title)"}
            end timeout
        end tell
        """
        if let dateStr = arg(after: "--due"), let d = parseDate(dateStr) {
            script = """
            tell application "Reminders"
                with timeout of 10 seconds
                    set dueDate to current date
                    set year of dueDate to \(d.year)
                    set month of dueDate to \(d.month)
                    set day of dueDate to \(d.day)
                    set hours of dueDate to \(d.hour)
                    set minutes of dueDate to \(d.minute)
                    set seconds of dueDate to 0
                    make new reminder in list "\(list)" with properties {name:"\(title)", due date:dueDate}
                end timeout
            end tell
            """
        }
        run(script)
        print("Created: \(args[4])")

    case "complete":
        guard args.count >= 5 else { fail("Usage: apple reminders complete \"List\" \"Title\"") }
        let list = esc(args[3]); let title = esc(args[4])
        run("""
        tell application "Reminders"
            with timeout of 10 seconds
                set r to first reminder of list "\(list)" whose name is "\(title)" and completed is false
                set completed of r to true
            end timeout
        end tell
        """)
        print("Completed: \(args[4])")

    case "delete":
        guard args.count >= 5 else { fail("Usage: apple reminders delete \"List\" \"Title\"") }
        let list = esc(args[3]); let title = esc(args[4])
        run("""
        tell application "Reminders"
            with timeout of 10 seconds
                delete (first reminder of list "\(list)" whose name is "\(title)")
            end timeout
        end tell
        """)
        print("Deleted: \(args[4])")

    case "clear":
        guard args.count >= 4 else { fail("Usage: apple reminders clear \"List\"") }
        let list = esc(args[3])
        let count = run("""
        tell application "Reminders"
            with timeout of 30 seconds
                set n to count reminders of list "\(list)"
                delete reminders of list "\(list)"
                return n
            end timeout
        end tell
        """)
        print("Cleared \(count) reminder(s) from '\(args[3])'")

    case "search":
        guard args.count >= 4 else { fail("Usage: apple reminders search \"text\"") }
        let query = esc(args[3])
        let result = run("""
        tell application "Reminders"
            set output to ""
            repeat with l in lists
                repeat with r in reminders of l
                    if name of r contains "\(query)" then
                        set status to "[x] "
                        if completed of r is false then set status to "[ ] "
                        set output to output & status & "[" & name of l & "] " & name of r & "\\n"
                    end if
                end repeat
            end repeat
            return output
        end tell
        """)
        print(result.isEmpty ? "No results for '\(args[3])'" : result)

    default:
        fail("Unknown command '\(cmd)'. Run 'apple' for usage.")
    }
}

// MARK: - Calendar

func calendarCommand(_ cmd: String) {
    switch cmd {

    case "list":
        let result = run("""
        tell application "Calendar"
            set output to ""
            repeat with c in calendars
                set output to output & "• " & name of c & "\\n"
            end repeat
            return output
        end tell
        """)
        print(result.isEmpty ? "(no calendars)" : result)

    case "events":
        let days = Int(arg(after: "--days") ?? "7") ?? 7
        let result = run("""
        tell application "Calendar"
            set startDate to current date
            set endDate to startDate + (\(days) * days)
            set output to ""
            repeat with c in calendars
                repeat with e in (every event of c whose start date >= startDate and start date <= endDate)
                    set output to output & "[" & name of c & "] " & summary of e & "  —  " & (start date of e as string) & "\\n"
                end repeat
            end repeat
            return output
        end tell
        """)
        print(result.isEmpty ? "No events in the next \(days) days" : result)

    case "create":
        guard args.count >= 4 else { fail("Usage: apple calendar create \"Title\" --date \"YYYY-MM-DD HH:MM\" [--calendar name] [--duration N] [--notes text]") }
        let title = esc(args[3])
        guard let dateStr = arg(after: "--date"), let d = parseDate(dateStr) else {
            fail("--date is required. Format: YYYY-MM-DD HH:MM")
        }
        let calName = esc(arg(after: "--calendar") ?? "")
        let duration = Int(arg(after: "--duration") ?? "60") ?? 60
        let notes = arg(after: "--notes").map { "set description of newEvent to \"\(esc($0))\"" } ?? ""
        let calTarget = calName.isEmpty ? "first calendar" : "first calendar whose name is \"\(calName)\""
        run("""
        tell application "Calendar"
            set startDate to current date
            set year of startDate to \(d.year)
            set month of startDate to \(d.month)
            set day of startDate to \(d.day)
            set hours of startDate to \(d.hour)
            set minutes of startDate to \(d.minute)
            set seconds of startDate to 0
            set endDate to startDate + (\(duration) * minutes)
            set targetCal to \(calTarget)
            tell targetCal
                set newEvent to make new event with properties {summary:"\(title)", start date:startDate, end date:endDate}
                \(notes)
            end tell
        end tell
        """)
        print("Created: \(args[3]) on \(dateStr)")

    default:
        fail("Unknown command '\(cmd)'. Run 'apple' for usage.")
    }
}

// MARK: - Notes

func notesCommand(_ cmd: String) {
    switch cmd {

    case "list":
        let folder = arg(after: "--folder")
        let source = folder.map { "notes of folder \"\(esc($0))\"" } ?? "notes"
        let result = run("""
        tell application "Notes"
            set output to ""
            repeat with n in \(source)
                set output to output & name of n & "\\n"
            end repeat
            return output
        end tell
        """)
        print(result.isEmpty ? "(no notes)" : result)

    case "read":
        guard args.count >= 4 else { fail("Usage: apple notes read \"Title\"") }
        let result = run("""
        tell application "Notes"
            return body of (first note whose name is "\(esc(args[3]))")
        end tell
        """)
        print(result.isEmpty ? "(not found or empty)" : result)

    case "create":
        guard args.count >= 5 else { fail("Usage: apple notes create \"Title\" \"Body\" [--folder name]") }
        let folder = arg(after: "--folder") ?? "Notes"
        run("""
        tell application "Notes"
            make new note at folder "\(esc(folder))" with properties {name:"\(esc(args[3]))", body:"\(esc(args[4]))"}
        end tell
        """)
        print("Created note '\(args[3])' in '\(folder)'")

    case "search":
        guard args.count >= 4 else { fail("Usage: apple notes search \"text\"") }
        let query = esc(args[3])
        let result = run("""
        tell application "Notes"
            set output to ""
            repeat with n in notes
                if name of n contains "\(query)" or body of n contains "\(query)" then
                    set output to output & name of n & "\\n"
                end if
            end repeat
            return output
        end tell
        """)
        print(result.isEmpty ? "No notes matching '\(args[3])'" : result)

    default:
        fail("Unknown command '\(cmd)'. Run 'apple' for usage.")
    }
}

// MARK: - Main

guard args.count >= 3 else { usage() }

switch args[1] {
case "reminders": remindersCommand(args[2])
case "calendar":  calendarCommand(args[2])
case "notes":     notesCommand(args[2])
case "--help", "help", "-h": usage()
default: fail("Unknown domain '\(args[1])'. Use: reminders, calendar, notes")
}
