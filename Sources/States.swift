// States.swift
// How every control and reading in the panel looks while it waits, when it
// fails, and how old it is. One set of views so all four tabs behave alike.
// The rules behind them are in docs/dev/design-kit.md, "Pending and failure".

import AppKit
import SwiftUI

/// A small spinner that only appears once a change has been waiting longer
/// than `Pending.showAfter`. Before that it takes the same space, empty.
struct PendingMark: View {
    let since: Date
    /// What the spinner's tooltip says; most waits are a save.
    var help = "Saving…"
    @State private var visible = false

    var body: some View {
        ZStack {
            if visible { ProgressView().sbControlSize(.mini).transition(.opacity) }
        }
        .frame(width: si(18), height: si(14))
        .task(id: since) {
            visible = false
            let wait = max(0, Pending.showAfter - Date().timeIntervalSince(since))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            withAnimation(Motion.fast) { visible = true }
        }
        .help(help)
    }
}

/// The one line a row grows when a change did not stick: what failed, in
/// plain words, with Retry when trying again could help.
struct RowFailure: View {
    let message: String
    var retry: (() -> Void)? = nil
    /// The button's word when the fix is not a retry ("Open Settings").
    var retryLabel = "Retry"
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.sbIcon(9.5))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let retry = retry {
                Button(retryLabel, action: retry).buttonStyle(.link).font(PT.caption)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.sbIcon(8.5, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(PT.caption)
        .foregroundStyle(Color(nsColor: .systemRed))
        .padding(.horizontal, PT.rowH)
        .padding(.bottom, PT.rowV)
    }
}

/// The status line under a reading's header. Ages stay grey until the value is
/// older than `staleAfter`, then turn amber; a failure with nothing to show is
/// red with Retry; an absent source is grey and offers nothing to click.
struct ReadingStatus: View {
    let state: ReadingState
    var staleAfter: TimeInterval = 3600
    var busySince: Date? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            switch state {
            case .loading:
                Text("Reading…").foregroundStyle(.secondary)
            case .fresh(let d):
                Text("as of \(age(d))")
                    .foregroundStyle(Date().timeIntervalSince(d) > staleAfter ? AnyShapeStyle(amber) : AnyShapeStyle(.tertiary))
            case .stale(let d, let why):
                Image(systemName: "exclamationmark.circle").font(.sbIcon(9.5)).foregroundStyle(amber)
                Text("as of \(age(d)) · couldn't refresh: \(why)").foregroundStyle(amber)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill").font(.sbIcon(9.5))
                Text(why).fixedSize(horizontal: false, vertical: true)
            case .unavailable(let why):
                Image(systemName: "minus.circle").font(.sbIcon(9.5)).foregroundStyle(.tertiary)
                Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let since = busySince { PendingMark(since: since) }
            else if let retry = retry, state.canRetry {
                Button(state.isFailure ? "Retry" : "Refresh", action: retry).buttonStyle(.link)
            }
        }
        .font(PT.caption)
        .foregroundStyle(state.isFailure ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
    }

    private var amber: Color { Color(nsColor: .systemOrange) }
}

/// "just now", "4m ago", "3h ago", "2d ago".
func age(_ d: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(d))
    if s < 45 { return "just now" }
    if s < 3600 { return "\(max(1, s / 60))m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}
