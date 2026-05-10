# apple-cli

A unified command-line interface for Apple's built-in apps — Reminders, Calendar, and Notes — on macOS.

No dependencies. Pure Swift using EventKit and AppleScript.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/tgvdinesh/apple-cli.git
cd apple-cli
make install        # installs to /usr/local/bin/apple
```

Or build locally without installing:

```bash
make build
./apple reminders list
```

## Permissions

On first run, macOS will prompt for access to Reminders and Calendar. Grant access in:

> System Settings → Privacy & Security → Reminders / Calendars

Notes access is handled via AppleScript — no separate permission needed.

## Usage

### Reminders

```bash
# List all reminder lists with counts
apple reminders list

# List items in a specific list
apple reminders list-items "Shopping"
apple reminders list-items "Shopping" --all        # include completed

# Create a reminder
apple reminders create "Shopping" "Buy milk"
apple reminders create "Shopping" "Buy milk" --due 2026-06-01
apple reminders create "Shopping" "Meeting prep" --due "2026-06-01 09:00"

# Complete a reminder
apple reminders complete "Shopping" "Buy milk"

# Delete a reminder
apple reminders delete "Shopping" "Buy milk"

# Delete all reminders in a list
apple reminders clear "Shopping"

# Search across all lists
apple reminders search "milk"
```

### Calendar

```bash
# List all calendars
apple calendar list

# Show upcoming events (default: next 7 days)
apple calendar events
apple calendar events --days 14

# Create an event
apple calendar create "Doctor appointment" --date "2026-06-15 10:30"
apple calendar create "Team sync" --date "2026-06-15 14:00" --calendar "Work" --duration 30
apple calendar create "Anniversary" --date "2026-07-04 19:00" --notes "Reservation at 7pm"
```

### Notes

```bash
# List all note titles
apple notes list
apple notes list --folder "Personal"

# Read a note
apple notes read "Shopping list"

# Create a note
apple notes create "Title" "Body text here"
apple notes create "Title" "Body" --folder "Work"

# Search notes by title or body
apple notes search "recipe"
```

## Why

macOS ships with powerful apps — Reminders, Calendar, Notes — but there's no first-party CLI to script them. This tool fills that gap for automation, AI agents, and shell workflows.

## License

MIT
