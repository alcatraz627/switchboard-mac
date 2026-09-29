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
        let t = s.lowercased().replacingOccurrences(of: "in ", with: "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let r = t.range(of: #"^(\d+(\.\d+)?)\s*(d|h|m)(\s*(\d+)\s*m)?$"#, options: .regularExpression), r == t.startIndex..<t.endIndex {
            let unit = t.first { "dhm".contains($0) }!
            let n = Double(t.prefix { $0.isNumber || $0 == "." }) ?? 0
            var secs = n * (unit == "d" ? 86400 : unit == "h" ? 3600 : 60)
            if unit == "h", let m = t.range(of: #"(\d+)\s*m$"#, options: .regularExpression) {
                secs += (Double(t[m].filter(\.isNumber)) ?? 0) * 60
            }
            return secs > 0 ? now.addingTimeInterval(secs) : nil
        }
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = d.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), var date = m.date else { return nil }
        // "9am" with no day means the next 9 AM.
        if date <= now, m.range.length == (s as NSString).length, !s.lowercased().contains("today") {
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
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
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 14, minute: 0))!
    func mins(_ s: String) -> Int? { WhenText.parse(s, now: now).map { Int($0.timeIntervalSince(now) / 60) } }
    func line(_ name: String, _ ok: Bool, _ got: String) -> String { "\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got: \(got))")" }
    let tomorrow9 = WhenText.parse("tomorrow 9am", now: now).map { Calendar.current.dateComponents([.day, .hour], from: $0) }
    return [line("90m is 90 minutes", mins("90m") == 90, "\(mins("90m") ?? -1)"),
            line("in 3h is 180 minutes", mins("in 3h") == 180, "\(mins("in 3h") ?? -1)"),
            line("1h30m is 90 minutes", mins("1h30m") == 90, "\(mins("1h30m") ?? -1)"),
            line("2d is two days", mins("2d") == 2880, "\(mins("2d") ?? -1)"),
            line("tomorrow 9am is the next day at 9", tomorrow9?.day == 1 && tomorrow9?.hour == 9, "\(String(describing: tomorrow9))"),
            line("nonsense reads as nothing", WhenText.parse("blah", now: now) == nil, "a date")]
}

/// The popover's body. `choices` adds a segmented pick above (Switch to
/// Allow / Block); `extra` adds actions below such as "Clear" or "End now".
struct WhenPanel: View {
    let title: String
    let presets: [WhenPreset]
    var choices: [String] = []
    var extra: [(String, () -> Void)] = []
    var initial: Date? = nil
    let onPick: (Date, Int) -> Void
    var dismiss: () -> Void = {}

    @State private var choice = 0
    @State private var typed = ""
    @State private var custom = Date().addingTimeInterval(3600)
    @State private var showCalendar = false
    @FocusState private var fieldFocused: Bool

    private var typedDate: Date? { WhenText.parse(typed) }

    var body: some View {
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
    let onPick: (Date, Int) -> Void
    @ViewBuilder let label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                WhenPanel(title: title, presets: presets, choices: choices, extra: extra, initial: initial,
                          onPick: onPick, dismiss: { open = false })
            }
    }
}
