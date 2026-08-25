import AppKit

/// `Antarium --preview out.png` renders the whole design system onto light and
/// dark menu-bar strips, so layout, colour and the agent marks can be judged
/// without installing anything.
@MainActor
enum Preview {
    private struct Sample { let label: String; let render: StatusRender }

    static func write(to path: String) -> Bool {
        let samples = makeSamples()
        let scale: CGFloat = 4
        let rowH: CGFloat = 30, labelW: CGFloat = 190, pad: CGFloat = 12
        let widest = samples.map { Renderer.width(for: $0.render) }.max() ?? 120
        let colW = labelW + widest + pad * 3
        let H = CGFloat(samples.count + countSamples.count) * rowH + pad * 2

        let image = Renderer.bitmap(size: NSSize(width: colW * 2, height: H),
                                    scale: scale, appearance: NSAppearance(named: .aqua)!) {
            for (col, appearance) in [(0, NSAppearance(named: .aqua)!),
                                      (1, NSAppearance(named: .darkAqua)!)] {
                let x0 = CGFloat(col) * colW
                // Menu-bar-ish backdrop.
                (col == 0 ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
                NSRect(x: x0, y: 0, width: colW, height: H).fill()

                appearance.performAsCurrentDrawingAppearance {
                    // The optional AGENTS count item, drawn with the gauges so
                    // one sheet covers everything the menu bar can show.
                    for (i, tally) in countSamples.enumerated() {
                        let y = H - pad - CGFloat(samples.count + i + 1) * rowH
                        NSAttributedString(string: tally.0, attributes: [
                            .font: NSFont.systemFont(ofSize: 10),
                            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
                        ]).draw(at: NSPoint(x: x0 + pad, y: y + 9))
                        let img = CountRenderer.image(tally.1, appearance: appearance, scale: scale)
                        img.draw(at: NSPoint(x: x0 + pad + labelW, y: y + (rowH - img.size.height) / 2),
                                 from: .zero, operation: .sourceOver, fraction: 1)
                    }
                    for (i, sample) in samples.enumerated() {
                        let y = H - pad - CGFloat(i + 1) * rowH
                        NSAttributedString(string: sample.label, attributes: [
                            .font: NSFont.systemFont(ofSize: 10),
                            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
                        ]).draw(at: NSPoint(x: x0 + pad, y: y + 9))

                        let img = Renderer.image(sample.render, appearance: appearance, scale: scale)
                        img.draw(at: NSPoint(x: x0 + pad + labelW, y: y + (rowH - img.size.height) / 2),
                                 from: .zero, operation: .sourceOver, fraction: 1)
                    }
                }
            }
        }
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
    }

    /// `remaining` is the underlying headroom; the sample renders it the way
    /// the current meter mode would.
    private static func row(_ remaining: Double, _ reset: String) -> StatusRender.Row {
        let used = 1 - remaining
        let mode = Settings.meterMode
        return StatusRender.Row(
            fill: mode == .used ? used : remaining,
            percentText: Gauge.percentText(mode == .used ? used : remaining),
            resetText: reset,
            severity: Severity.forRemaining(remaining))
    }

    /// AGENTS count badges: a busy machine and an idle one.
    private static var countSamples: [(String, CountItem.Tally)] {
        var busy = CountItem.Tally(); busy.working = 3; busy.waiting = 2
        var quiet = CountItem.Tally(); quiet.waiting = 1; quiet.ended = 2
        return [("AGENTS · 3 working, 2 waiting", busy),
                ("AGENTS · 1 waiting, 2 ended", quiet)]
    }

    private static func makeSamples() -> [Sample] {
        let healthy = [row(0.84, "40m"), row(0.73, "6d")]
        let low     = [row(0.34, "1h"), row(0.58, "3d")]
        let tight   = [row(0.07, "51m"), row(0.19, "2d")]
        // Zero headroom must read red regardless of palette or meter mode.
        let spent   = [row(0.0, "38m"), row(0.003, "4d")]

        var out: [Sample] = []
        out.append(Sample(label: "Claude · healthy",
                          render: StatusRender(agentID: "claude-code", rows: healthy)))
        out.append(Sample(label: "Claude · low",
                          render: StatusRender(agentID: "claude-code", rows: low)))
        out.append(Sample(label: "Claude · critical",
                          render: StatusRender(agentID: "claude-code", rows: tight)))
        out.append(Sample(label: "Claude · exhausted (100%)",
                          render: StatusRender(agentID: "claude-code", rows: spent)))
        out.append(Sample(label: "Claude · stale",
                          render: StatusRender(agentID: "claude-code", rows: low,
                                               message: nil, stale: true)))
        out.append(Sample(label: "ChatGPT",
                          render: StatusRender(agentID: "codex", rows: healthy)))
        out.append(Sample(label: "Kimi · single gauge",
                          render: StatusRender(agentID: "kimi", rows: [row(0.62, "")])))
        out.append(Sample(label: "needs sign-in",
                          render: StatusRender(agentID: "codex", rows: [],
                                               message: "sign in")))
        return out
    }
}
