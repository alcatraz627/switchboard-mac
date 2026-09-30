// WhenPicker.swift
// The one control for picking a time, used by every snooze, timed flip, note
// expiry, reminder and timer: preset chips for the usual "in n hours / days",
// a field that reads "in 90m", "3h", "tomorrow 9am" or "fri 5pm", and a
// calendar with a time field, all previewing the result before it is set.

import AppKit
import SwiftUI

/// A named moment relative to now, such as "in 1 hour" or "tomorrow 9 AM".
struct WhenPreset: Identifiable {
    let label: String
    let date: () -> Date
    var id: String { label }

    static func inMinutes(_ m: Int) -> WhenPreset {
        WhenPreset(label: m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) m") {
            Date().addingTimeInterval(TimeInterval(m * 60))
        }
    }
    static func inDays(_ d: Int) -> WhenPreset {
        WhenPreset(label: d == 7 ? "1 week" : d == 30 ? "1 month" : "\(d) days") { Date().addingTimeInterval(TimeInterval(d * 86400)) }
    }
    static func at(_ label: String, dayOffset: Int, hour: Int, minute: Int = 0) -> WhenPreset {
        WhenPreset(label: label) {
            let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
    }
    static let endOfToday = at("End of day", dayOffset: 0, hour: 23, minute: 59)
    static let tomorrowMorning = at("Tmrw 9 AM", dayOffset: 1, hour: 9)
    static let tonight = at("Tonight 8 PM", dayOffset: 0, hour: 20)

    /// For switches and snoozes: the next hours and days.
    static let short: [WhenPreset] = [inMinutes(30), inMinutes(60), inMinutes(120), inMinutes(240),
                                      endOfToday, tomorrowMorning, inDays(3), inDays(7)]
    /// For notes and reminders: further out.
    static let long: [WhenPreset] = [inMinutes(60), inMinutes(180), tonight, tomorrowMorning,
                                     inDays(3), inDays(7), inDays(30)]
    /// For timers: minutes first.
    static let timer: [WhenPreset] = [inMinutes(1), inMinutes(5), inMinutes(10), inMinutes(15),
                                      inMinutes(25), inMinutes(30), inMinutes(45), inMinutes(60)]
}

enum WhenText {
    /// Reads a typed time: "90m", "in 3h", "2d", "1h30m", or anything
    /// macOS recognises as a date ("tomorrow 9am", "fri 5pm", "2 Oct 14:00").
    static func parse(_ s: String, now: Date = Date()) -> Date? {
        let raw = s.trimmingCharacters(in: .whitespaces)
        var t = raw.lowercased()
        if t.hasPrefix("in ") { t.removeFirst(3) }
        guard !t.isEmpty else { return nil }
        if let secs = duration(t) { return secs > 0 ? now.addingTimeInterval(secs) : nil }

        // macOS reads the time of day; the day itself is worked out here from
        // `now`, because the detector resolves "tomorrow" against the real clock.
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = d.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), let found = m.date else { return nil }
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute], from: found)
        func on(_ day: Date) -> Date? { cal.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) }
        let today = cal.startOfDay(for: now)
        let words = t.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains("today") { return on(today) }
        if words.contains("tomorrow") || words.contains("tmrw") {
            return cal.date(byAdding: .day, value: 1, to: today).flatMap(on)
        }
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if let w = words.first(where: { w in days.contains { w.hasPrefix($0) } }), let idx = days.firstIndex(where: { w.hasPrefix($0) }) {
            // The next such weekday; today's own weekday counts only while its time is ahead.
            let ahead = (idx + 1 - cal.component(.weekday, from: now) + 7) % 7
            guard let candidate = cal.date(byAdding: .day, value: ahead, to: today).flatMap(on) else { return nil }
            return candidate > now ? candidate : cal.date(byAdding: .day, value: 7, to: candidate)
        }
        if t.range(of: #"^\d{1,2}(:\d{2})?\s*(am|pm)?$"#, options: .regularExpression) != nil {
            // A time alone means its next occurrence.
            guard let c = on(today) else { return nil }
            return c > now ? c : cal.date(byAdding: .day, value: 1, to: c)
        }
        return found
    }

    /// Seconds in a typed duration: "90m", "1h30m", "1d 2h", "5 min", "2 hours", "1.5h".
    static func duration(_ t: String) -> TimeInterval? {
        var s = t
        for (words, unit) in [(["minutes", "minute", "mins", "min"], "m"), (["hours", "hour", "hrs", "hr"], "h"), (["days", "day"], "d")] {
            for w in words { s = s.replacingOccurrences(of: #"(\d)\s*"# + w + #"\b"#, with: "$1" + unit, options: .regularExpression) }
        }
        let pair = #"(\d+(?:\.\d+)?)\s*([dhm])"#
        guard s.range(of: "^\\s*(" + pair + "\\s*)+$", options: .regularExpression) != nil,
              let re = try? NSRegularExpression(pattern: pair) else { return nil }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reduce(0) { total, m in
            let n = Double((s as NSString).substring(with: m.range(at: 1))) ?? 0
            let unit = (s as NSString).substring(with: m.range(at: 2))
            return total + n * (unit == "d" ? 86400 : unit == "h" ? 3600 : 60)
        }
    }

    /// "Thu 2 Oct, 5:00 PM · in 3h 20m".
    static func describe(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today', h:mm a" : Calendar.current.isDateInTomorrow(d) ? "'tomorrow', h:mm a" : "EEE d MMM, h:mm a"
        let s = Int(d.timeIntervalSince(now))
        let rel = s <= 0 ? "now" : s < 3600 ? "in \(max(1, s / 60))m" : s < 86400 ? "in \(s / 3600)h \((s % 3600) / 60)m" : "in \(s / 86400)d \((s % 86400) / 3600)h"
        return f.string(from: d) + " · " + rel
    }
}

/// Typed times the picker must read, checked against a fixed "now".
func probeWhen() -> [String] {
    let now = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15, hour: 14, minute: 0))!
    func mins(_ s: String) -> Int? { WhenText.parse(s, now: now).map { Int($0.timeIntervalSince(now) / 60) } }
    func line(_ name: String, _ ok: Bool, _ got: String) -> String { "\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got: \(got))")" }
    // Every relative day is judged against the injected "now" (Wed 15 Jan 2025, 14:00, far from any real today), never the real clock.
    func at(_ s: String) -> String {
        guard let d = WhenText.parse(s, now: now) else { return "nil" }
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: d)
        return "\(c.month!)/\(c.day!) \(c.hour!):\(String(format: "%02d", c.minute!))"
    }
    let cases: [(String, Int)] = [("90m", 90), ("in 3h", 180), ("1h30m", 90), ("2d", 2880), ("1d30m", 1470),
                                  ("5 min", 5), ("10 mins", 10), ("45 minutes", 45), ("2 hours", 120),
                                  ("1 hr 15 min", 75), ("3 days", 4320), ("1.5h", 90)]
    return cases.map { s, want in line("\"\(s)\" is \(want) minutes", mins(s) == want, "\(mins(s) ?? -1)") } + [
        line("tomorrow 9am is the next day at 9", at("tomorrow 9am") == "1/16 9:00", at("tomorrow 9am")),
        line("9am, already past today, is tomorrow at 9", at("9am") == "1/16 9:00", at("9am")),
        line("\" 9am\" with a leading space reads the same", at(" 9am") == "1/16 9:00", at(" 9am")),
        line("5pm, still ahead today, is today", at("5pm") == "1/15 17:00", at("5pm")),
        line("today 9am stays today even though it has passed", at("today 9am") == "1/15 9:00", at("today 9am")),
        line("fri 5pm is the coming Friday", at("fri 5pm") == "1/17 17:00", at("fri 5pm")),
        line("wed 9am, today's weekday but passed, is next week", at("wed 9am") == "1/22 9:00", at("wed 9am")),
        line("an absolute date is kept as written", at("2 Oct 14:30") == "10/2 14:30", at("2 Oct 14:30")),
        line("nonsense reads as nothing", WhenText.parse("blah", now: now) == nil, "a date"),
        line("zero is not a time", WhenText.parse("0m", now: now) == nil, "a date")]
}

/// The popover's body. `choices` adds a segmented pick above (Switch to
/// Allow / Block); `extra` adds actions below such as "Clear" or "End now".
struct WhenPanel: View {
    let title: String
    let presets: [WhenPreset]
    var choices: [String] = []
    var extra: [(String, () -> Void)] = []
    var initial: Date? = nil
    var initialChoice = 0
    let onPick: (Date, Int) -> Void
    var dismiss: () -> Void = {}

    @State private var choice = 0
    @State private var typed = ""
    @State private var custom = Date().addingTimeInterval(3600)
    @State private var showCalendar = false
    @FocusState private var fieldFocused: Bool

    private var typedDate: Date? { WhenText.parse(typed) }

    var body: some View {
        panel.onAppear { choice = initialChoice }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if choices.count > 1 {
                Picker("", selection: $choice) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { i, c in Text(c).tag(i) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(presets) { p in
                    Button { pick(p.date()) } label: {
                        Text(p.label).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help(WhenText.describe(p.date()))
                }
            }
            HStack(spacing: 6) {
                TextField("Or type: 90m, 3h, tomorrow 9am, fri 5pm", text: $typed)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                    .focused($fieldFocused)
                    .onSubmit { if let d = typedDate { pick(d) } }
                Button { withAnimation(.easeOut(duration: 0.15)) { showCalendar.toggle() } } label: {
                    Image(systemName: "calendar").font(.system(size: 12))
                }
                .buttonStyle(.borderless).help("Pick on a calendar")
            }
            if !typed.isEmpty {
                Text(typedDate.map { WhenText.describe($0) } ?? "Not a time I can read yet")
                    .font(.system(size: 11)).foregroundStyle(typedDate == nil ? .orange : .secondary)
            }
            if showCalendar {
                DatePicker("", selection: $custom, in: Date()..., displayedComponents: [.date]).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    DatePicker("", selection: $custom, displayedComponents: [.hourAndMinute]).labelsHidden().datePickerStyle(.field)
                    Text(WhenText.describe(custom)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Set") { pick(custom) }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            if !extra.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    ForEach(Array(extra.enumerated()), id: \.offset) { _, e in
                        Button(e.0) { e.1(); dismiss() }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            if let i = initial { custom = i }
            NSApp.activate(ignoringOtherApps: true)
            fieldFocused = true
        }
    }

    private func pick(_ d: Date) {
        onPick(d, choice)
        dismiss()
    }
}

/// A small icon or label that opens the WhenPanel in a popover.
struct WhenButton<Label: View>: View {
    let title: String
    let presets: [WhenPreset]
    var choices: [String] = []
    var extra: [(String, () -> Void)] = []
    var initial: Date? = nil
    /// Which of `choices` is picked when it opens, such as a reminder's current repeat.
    var initialChoice = 0
    let onPick: (Date, Int) -> Void
    @ViewBuilder let label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                WhenPanel(title: title, presets: presets, choices: choices, extra: extra, initial: initial,
                          initialChoice: initialChoice, onPick: onPick, dismiss: { open = false })
            }
    }
}
