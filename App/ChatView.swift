import SwiftUI

struct ChatView: View {
    @State private var agent = Agent.shared
    @State private var draft = ""
    @State private var settings = false
    @State private var open: Set<UUID> = []
    // only follow new messages when the user is already at the bottom
    @State private var atBottom = true
    @FocusState private var typing: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(agent.items.enumerated()), id: \.element.id) { i, item in
                        if let stamp = stamp(at: i) {
                            Text(stamp)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, i == 0 ? 4 : 18)
                                .padding(.bottom, 8)
                        }
                        row(item, after: i > 0 ? agent.items[i - 1] : nil)
                    }
                    // shown the whole run except while text is streaming in, which is its own sign of life
                    if agent.running, agent.status != "Writing" {
                        HStack(spacing: 8) {
                            Dots().accessibilityHidden(true)
                            Text(Self.label(agent.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 8)
                        .accessibilityElement(children: .combine)
                        .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
            }
            // no animation here, it fires on every streamed token
            .onChange(of: agent.items) {
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: agent.items.count) { old, new in
                // your own message always brings you down
                if new > old, agent.items.last?.kind == .user {
                    atBottom = true
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            .onChange(of: typing) {
                if typing { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .overlay {
            if agent.items.isEmpty { empty }
        }
        .safeAreaBar(edge: .top) { header }
        .safeAreaBar(edge: .bottom) { input }
        .background(Color.black)
        .sheet(isPresented: $settings) { SettingsView() }
    }

    // MARK: header

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            Button { settings = true } label: {
                VStack(spacing: 5) {
                    Image(systemName: "iphone.gen3")
                        .accessibilityHidden(true)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color(white: 0.36), in: .circle)
                    HStack(spacing: 2) {
                        Text(Models.name(agent.model))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassEffect(in: .capsule)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(Models.name(agent.model)), settings")

            Button {
                agent.reset()
                open = []
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            // starting over mid-run would mix the old run into the new chat
            .opacity(agent.items.isEmpty || agent.running ? 0.4 : 1)
            .disabled(agent.items.isEmpty || agent.running)
            .accessibilityLabel("New chat")
            .padding(.top, 3)
            .padding(.trailing, 16)
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        // the header floats over the chat, so it stops growing at the big accessibility sizes
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Tell it what to do on your iPhone.")
                .foregroundStyle(.secondary)
            Text("It can open apps, tap, type and scroll.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .allowsHitTesting(false)
    }

    // MARK: rows

    @ViewBuilder
    private func row(_ item: Agent.Item, after prev: Agent.Item?) -> some View {
        // tighter when the same kind repeats, like messages
        let gap: CGFloat = prev == nil ? 0 : (prev?.kind == item.kind ? 3 : 10)
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Bubble(text: item.text, mine: true)
            }
            .padding(.top, gap)
        case .assistant:
            HStack {
                Bubble(text: item.text, mine: false)
                Spacer(minLength: 60)
            }
            .padding(.top, gap)
        case .tool:
            ToolRow(item: item, open: open.contains(item.id)) {
                if open.contains(item.id) { open.remove(item.id) } else { open.insert(item.id) }
            }
            .padding(.top, prev?.kind == .tool ? 0 : 6)
        case .error:
            Label(item.text, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.text)
        }
    }

    // "Today 20:10" over the first message and after long gaps
    private func stamp(at i: Int) -> AttributedString? {
        let d = agent.items[i].date
        if i > 0, d.timeIntervalSince(agent.items[i - 1].date) < 30 * 60 { return nil }
        let day: String
        if Calendar.current.isDateInToday(d) { day = "Today" }
        else if Calendar.current.isDateInYesterday(d) { day = "Yesterday" }
        else { day = d.formatted(.dateTime.weekday(.wide).day().month()) }
        var s = AttributedString(day)
        s.font = .caption2.weight(.semibold)
        return s + AttributedString(" " + d.formatted(date: .omitted, time: .shortened))
    }

    // MARK: input

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($typing)
                .padding(.leading, 16)
                .padding(.vertical, 10)

            if agent.running {
                Button(action: agent.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 30, height: 30)
                        .background(.white, in: .circle)
                }
                .padding(5)
                .accessibilityLabel("Stop")
            } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.blue, in: .circle)
                }
                .padding(5)
                .accessibilityLabel("Send")
            }
        }
        .frame(minHeight: 40)
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.15), value: agent.running)
    }

    // "Running phone_act" reads better as "Using phone act"
    static func label(_ status: String) -> String {
        guard status.hasPrefix("Running ") else { return status.isEmpty ? "Working" : status }
        return "Using " + status.dropFirst(8).replacingOccurrences(of: "_", with: " ")
    }

    private func send() {
        guard !agent.running else { return }
        agent.send(draft)
        draft = ""
    }
}

struct Bubble: View {
    var text: String
    var mine: Bool

    var body: some View {
        Text(Self.render(text))
            .font(.body)
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(mine ? Color.blue : Color(white: 0.15), in: .rect(cornerRadius: 18))
    }

    // inline markdown only (bold, links). the model's told to keep it plain anyway
    static func render(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

struct ToolRow: View {
    var item: Agent.Item
    var open: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .accessibilityHidden(true)
                    Text(item.text)
                    if !item.detail.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                // looks compact, but the whole row width and 28pt of height take the tap
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!item.detail.isEmpty)
            .accessibilityValue(item.detail.isEmpty ? "" : (open ? "expanded" : "collapsed"))

            if open, !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private var icon: String {
        switch item.text {
        case "Used phone act": "hand.tap"
        case "Used phone look": "eye"
        case "Used phone apps": "square.grid.2x2"
        case "Used current time": "clock"
        default: "wrench"
        }
    }
}

struct Dots: View {
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { ctx in
            let t = still ? 0 : ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    // each dot brightens in turn
                    let phase = (sin(t * 5 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(Color(white: 0.45 + 0.35 * phase))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 13)
            .background(Color(white: 0.15), in: .rect(cornerRadius: 18))
        }
        .accessibilityLabel("Working")
    }
}
