import AppKit
import SwiftUI

/// `Antarium --demo-frames <dir>` draws the README animation.
///
/// The roster is invented. A recording of a real menu bar publishes whatever
/// that machine was doing — project names, folders, spend — and the landing
/// page is the most public thing this repository has. Drawing through the
/// app's own views instead keeps the picture current with the UI and keeps
/// every figure one the app could have produced: a cost only where the
/// bundled price table has a rate, derived from the row's own token counts.
@MainActor
enum DemoScene {
    /// The story's moments: everyone busy, one finishes, a little later.
    static let steps = [0, 1, 2]
    /// The session whose banner the animation shows.
    static let announced = "Payments"

    private struct Seat {
        let dir: String
        let agentID: String
        let host: String
        let model: String?
        let window: Int?
        /// State at each step.
        let states: [AgentRow.State]
        let sent: Int
        let received: Int
        let context: Int?
        let tools: Int?
        let turns: Int?
        let minutesAgo: [Double]
        let capabilities: Set<Capability.Kind>
        let rssMB: Int64
    }

    private static let seats: [Seat] = [
        Seat(dir: "payments", agentID: "claude-code", host: "tmux", model: "claude-opus-5",
             window: 1_000_000, states: [.working, .waiting, .waiting],
             sent: 1_840_000, received: 212_000, context: 318_000, tools: 412, turns: nil,
             minutesAgo: [0, 0, 1], capabilities: [.instruction, .memory, .skills, .mcp, .permission],
             rssMB: 412),
        Seat(dir: "mobile", agentID: "codex", host: "Warp", model: "gpt-5.5",
             window: 400_000, states: [.working, .working, .waiting],
             sent: 2_310_000, received: 96_400, context: 141_000, tools: 268, turns: nil,
             minutesAgo: [0, 0, 0], capabilities: [.instruction, .skills, .mcp],
             rssMB: 238),
        Seat(dir: "storefront", agentID: "claude-code", host: "tmux", model: "claude-sonnet-5",
             window: 1_000_000, states: [.looping, .looping, .looping],
             sent: 5_120_000, received: 388_000, context: 604_000, tools: 1_130, turns: nil,
             minutesAgo: [1, 1, 0], capabilities: [.instruction, .memory, .skills, .permission],
             rssMB: 530),
        Seat(dir: "search", agentID: "cursor", host: "Cursor", model: nil,
             window: nil, states: [.waiting, .waiting, .working],
             sent: 0, received: 0, context: nil, tools: nil, turns: 38,
             minutesAgo: [4, 4, 0], capabilities: [.instruction, .mcp],
             rssMB: 180),
        Seat(dir: "infra", agentID: "copilot-cli", host: "Terminal", model: nil,
             window: nil, states: [.shell, .working, .working],
             sent: 640_000, received: 41_200, context: nil, tools: 87, turns: nil,
             minutesAgo: [0, 0, 0], capabilities: [.instruction, .permission],
             rssMB: 142),
        Seat(dir: "docs", agentID: "claude-code", host: "Terminal", model: "claude-haiku-4-5",
             window: 200_000, states: [.waiting, .waiting, .waiting],
             sent: 310_000, received: 58_000, context: 72_000, tools: 64, turns: nil,
             minutesAgo: [12, 12, 13], capabilities: [.instruction, .memory],
             rssMB: 120),
        Seat(dir: "ledger", agentID: "kimi", host: "tmux", model: nil,
             window: nil, states: [.ended, .ended, .ended],
             sent: 0, received: 0, context: nil, tools: 51, turns: nil,
             minutesAgo: [48, 48, 49], capabilities: [.instruction],
             rssMB: 0),
    ]

    /// The roster at one step. `home` is a parameter so the rows can be
    /// checked without depending on the account running the test.
    static func rows(step: Int, home: String, now: Date) -> [AgentRow] {
        seats.enumerated().map { index, seat in
            let s = max(0, min(step, seat.states.count - 1))
            let cwd = home + "/code/" + seat.dir
            var row = AgentRow(id: "demo-\(seat.dir)", agentID: seat.agentID,
                               name: seat.dir, cwd: cwd, state: seat.states[s])
            row.hostApp = seat.host
            row.model = seat.model
            // Growth between steps, so the later frames read as live.
            let grow = 1 + 0.04 * Double(s)
            if seat.sent > 0 {
                row.sentTokens = Int(Double(seat.sent) * grow)
                row.receivedTokens = Int(Double(seat.received) * grow)
            }
            if let context = seat.context, let window = seat.window {
                row.contextTokens = min(window, Int(Double(context) * grow))
                row.contextWindow = window
            }
            row.toolCalls = seat.tools.map { $0 + 9 * s }
            row.turns = seat.turns.map { $0 + s }
            if let rate = Pricing.rate(for: seat.model) {
                row.costUSD = (Double(row.sentTokens ?? 0) * rate.input
                               + Double(row.receivedTokens ?? 0) * rate.output) / 1_000_000
            }
            let minutes = seat.minutesAgo[min(s, seat.minutesAgo.count - 1)]
            row.lastActivity = now.addingTimeInterval(-minutes * 60)
            row.startedAt = now.addingTimeInterval(-Double(40 + index * 23) * 60)
            if seat.rssMB > 0 { row.rssBytes = seat.rssMB * 1_048_576 }
            if seat.host == "tmux" { row.tmuxTarget = "\(seat.dir):@1.%\(index)" }
            row.context = ProjectContext(capabilities: Capability.Kind.allCases.map { kind in
                seat.capabilities.contains(kind)
                    ? Capability(kind: kind, url: URL(fileURLWithPath: cwd), scope: .project, count: 1)
                    : Capability(kind: kind, url: nil)
            })
            row.activity = activity(seed: index, busy: seat.states[s].isBusy)
            return row
        }
    }

    /// Deterministic sparkline, busier toward the end for agents still at it.
    private static func activity(seed: Int, busy: Bool) -> [Int] {
        (0..<36).map { i in
            let wave = (i * (seed + 3) + seed * 7) % 11
            let ramp = busy && i > 26 ? 4 : 0
            return i < 6 + seed * 2 ? 0 : max(0, wave - 4) + ramp
        }
    }

    static func snapshots(now: Date) -> [Snapshot] {
        func gauge(_ id: String, _ badge: String, _ used: Double, hours: Double) -> Gauge {
            Gauge(id: id, badge: badge, title: id.capitalized, used: used,
                  resetsAt: now.addingTimeInterval(hours * 3600), windowSeconds: nil)
        }
        return [
            Snapshot(providerID: "claude-code",
                     gauges: [gauge("session", "5H", 0.38, hours: 2.3),
                              gauge("weekly", "7D", 0.61, hours: 70)],
                     extras: [], accountLabel: "Max", fetchedAt: now),
            Snapshot(providerID: "codex",
                     gauges: [gauge("session", "5H", 0.22, hours: 3.1),
                              gauge("weekly", "7D", 0.47, hours: 101)],
                     extras: [], accountLabel: "Pro", fetchedAt: now),
            Snapshot(providerID: "cursor",
                     gauges: [gauge("included", "MO", 0.83, hours: 190)],
                     extras: [], accountLabel: "Pro", fetchedAt: now),
        ]
    }

    // MARK: - Frames

    private static let canvas = NSSize(width: 900, height: 600)
    private static let barHeight: CGFloat = 26
    private static let scale: CGFloat = 2

    /// One composed moment of the animation.
    private struct Shot {
        var step: Int
        var alert: CGFloat = 0          // 0 hidden … 1 fully in
        var dashboard: CGFloat = 0      // 0 hidden … 1 fully shown
        var cursor: NSPoint? = nil
        var pressed = false
        var seconds: Double
    }

    /// Writes numbered PNGs and an ffmpeg concat list (`frames.txt`) holding
    /// each frame's duration.
    static func writeFrames(to dir: String) -> Bool {
        let now = Date()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { return false }

        for snapshot in snapshots(now: now) {
            QuotaStore.shared.admit(providerID: snapshot.providerID)
            QuotaStore.shared.set(providerID: snapshot.providerID, snapshot: snapshot)
        }

        let dark = NSAppearance(named: .darkAqua)!
        let menuItemX = menuItems(rows: Self.rows(step: 1, home: home, now: now), now: now,
                                  appearance: dark)[0].x   // left edge of the AGENTS item
        let target = NSPoint(x: menuItemX + 24, y: canvas.height - barHeight / 2)
        let start = NSPoint(x: canvas.width * 0.46, y: canvas.height * 0.42)

        var shots: [Shot] = [Shot(step: 0, seconds: 1.4)]
        for i in 1...6 { shots.append(Shot(step: 1, alert: CGFloat(i) / 6, seconds: 0.05)) }
        shots.append(Shot(step: 1, alert: 1, seconds: 1.8))
        for i in 1...8 {
            let t = ease(CGFloat(i) / 8)
            shots.append(Shot(step: 1, alert: 1,
                              cursor: NSPoint(x: start.x + (target.x - start.x) * t,
                                              y: start.y + (target.y - start.y) * t),
                              seconds: 0.05))
        }
        shots.append(Shot(step: 1, alert: 1, cursor: target, pressed: true, seconds: 0.2))
        for i in 1...5 {
            let t = CGFloat(i) / 5
            shots.append(Shot(step: 1, alert: 1 - t, dashboard: t, cursor: target, seconds: 0.05))
        }
        shots.append(Shot(step: 1, dashboard: 1, cursor: target, seconds: 3.2))
        shots.append(Shot(step: 2, dashboard: 1, cursor: target, seconds: 3.2))

        // Rendered once per step and appearance, then composed per frame.
        var dashboards: [Int: NSImage] = [:]
        var alerts: [Int: NSImage] = [:]
        for step in steps {
            let rows = Self.rows(step: step, home: home, now: now)
            AgentStore.shared.adoptForPreview(rows)
            dashboards[step] = snapshot(DashboardView(store: AgentStore.shared, onSettings: {},
                                                      onTogglePin: {}, singleColumn: true),
                                        appearance: dark)
            if let row = rows.first(where: { $0.coreName == announced }) {
                alerts[step] = snapshot(AgentAlert.previewCard(row), appearance: dark)
            }
        }

        var list = ""
        for (index, shot) in shots.enumerated() {
            let rows = Self.rows(step: shot.step, home: home, now: now)
            let image = Renderer.bitmap(size: canvas, scale: scale, appearance: dark) {
                dark.performAsCurrentDrawingAppearance {
                    drawWallpaper()
                    drawMenuBar(rows: rows, now: now, appearance: dark)
                    if shot.alert > 0, let alert = alerts[shot.step] {
                        let x = canvas.width - alert.size.width - 14
                        let y = canvas.height - barHeight - 10 - alert.size.height
                            + (1 - ease(shot.alert)) * (alert.size.height + 24)
                        drawCard(alert, at: NSPoint(x: x, y: y), radius: 14,
                                 fraction: min(1, shot.alert * 1.4))
                    }
                    if shot.dashboard > 0, let panel = dashboards[shot.step] {
                        drawPanel(panel, anchorX: menuItemX, fraction: shot.dashboard)
                    }
                    if let point = shot.cursor { drawCursor(at: point, pressed: shot.pressed) }
                }
            }
            let name = String(format: "frame-%03d.png", index)
            guard let rep = image.representations.first as? NSBitmapImageRep,
                  let png = rep.representation(using: .png, properties: [:]) else { return false }
            do { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
            catch { return false }
            list += "file '\(name)'\nduration \(shot.seconds)\n"
        }
        // The concat demuxer ignores the last duration unless the file repeats.
        list += "file '\(String(format: "frame-%03d.png", shots.count - 1))'\n"
        do {
            try list.write(toFile: dir + "/frames.txt", atomically: true, encoding: .utf8)
        } catch { return false }
        print("wrote \(shots.count) frames to \(dir)")
        return true
    }

    private static func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    private static func snapshot<V: View>(_ view: V, appearance: NSAppearance) -> NSImage {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let image = NSImage(size: host.bounds.size)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    private static func drawWallpaper() {
        let rect = NSRect(origin: .zero, size: canvas)
        NSGradient(colors: [NSColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1),
                            NSColor(red: 0.10, green: 0.16, blue: 0.33, alpha: 1),
                            NSColor(red: 0.24, green: 0.14, blue: 0.36, alpha: 1)])?
            .draw(in: rect, angle: 35)
        for (x, y, r, c) in [(0.22, 0.30, 260.0, NSColor.systemTeal),
                             (0.78, 0.12, 300.0, NSColor.systemPurple),
                             (0.55, 0.75, 220.0, NSColor.systemBlue)] {
            let center = NSPoint(x: canvas.width * x, y: canvas.height * y)
            NSGradient(starting: c.withAlphaComponent(0.22), ending: c.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: r, options: [])
        }
    }

    private static let clock = NSAttributedString(string: "Mon 9:41", attributes: [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ])

    /// The status items, right-aligned against the clock, with their x.
    private static func menuItems(rows: [AgentRow], now: Date,
                                  appearance: NSAppearance) -> [(image: NSImage, x: CGFloat)] {
        var images = [CountRenderer.image(CountItem.Tally(rows), appearance: appearance, scale: scale)]
        for snapshot in snapshots(now: now) {
            let render = StatusRender(agentID: snapshot.providerID,
                                      rows: StatusRender.rows(for: snapshot, mode: .remaining, now: now))
            images.append(Renderer.image(render, appearance: appearance, scale: scale))
        }
        let gap: CGFloat = 14
        var x = canvas.width - clock.size().width - 14 - gap
            - images.reduce(0) { $0 + $1.size.width } - gap * CGFloat(images.count - 1)
        return images.map { image in
            defer { x += image.size.width + gap }
            return (image, x)
        }
    }

    private static func drawMenuBar(rows: [AgentRow], now: Date, appearance: NSAppearance) {
        let bar = NSRect(x: 0, y: canvas.height - barHeight, width: canvas.width, height: barHeight)
        NSColor(white: 0.08, alpha: 0.55).setFill()
        bar.fill()
        for item in menuItems(rows: rows, now: now, appearance: appearance) {
            item.image.draw(at: NSPoint(x: item.x, y: bar.midY - item.image.size.height / 2),
                            from: .zero, operation: .sourceOver, fraction: 1)
        }
        clock.draw(at: NSPoint(x: canvas.width - clock.size().width - 14,
                               y: bar.midY - clock.size().height / 2))
    }

    /// A rounded, shadowed card behind a snapshot, the way a panel sits on
    /// the desktop.
    private static func drawCard(_ image: NSImage, at origin: NSPoint, radius: CGFloat,
                                 fraction: CGFloat) {
        let frame = NSRect(origin: origin, size: image.size)
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45 * fraction)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor(white: 0.13, alpha: 0.97 * fraction).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: fraction)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.12 * fraction).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    private static func drawPanel(_ panel: NSImage, anchorX: CGFloat, fraction: CGFloat) {
        let x = min(canvas.width - panel.size.width - 10, anchorX - 40)
        let y = canvas.height - barHeight - 6 - panel.size.height + (1 - ease(fraction)) * 12
        drawCard(panel, at: NSPoint(x: x, y: y), radius: 12, fraction: fraction)
    }

    private static func drawCursor(at point: NSPoint, pressed: Bool) {
        let image = NSCursor.arrow.image
        let hot = NSCursor.arrow.hotSpot
        let size = pressed ? NSSize(width: image.size.width * 0.9, height: image.size.height * 0.9)
                           : image.size
        image.draw(in: NSRect(x: point.x - hot.x, y: point.y - size.height + hot.y,
                              width: size.width, height: size.height))
    }
}
