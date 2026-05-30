import SwiftUI
import PhotosUI
import BabyLogCore

/// Chat tab root. Projects `ChatViewModel` state onto a scrollable bubble
/// list + bottom composer + backend picker toolbar.
struct ChatTabView: View {

    @Bindable var viewModel: ChatViewModel
    @State var emptyStateViewModel: ChatEmptyStateViewModel?
    /// Fired when the user taps the status card's "last feed" row.
    var onNavigateToFeeds: (() -> Void)? = nil
    /// Fired when the user taps the status card's diaper pill.
    var onNavigateToDiapers: (() -> Void)? = nil
    /// Injectable so tests / previews can swap in a fake. Defaults to the
    /// live `ChatImageProcessor`.
    var imageProcessor: any ChatImageProcessing = ChatImageProcessor()
    @FocusState private var inputFocused: Bool
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var attachmentError: String?
    @State private var isPinnedToBottom: Bool = true
    private static let bottomAnchorID = "chatBottomAnchor"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                if let progress = viewModel.modelLoadProgress {
                    modelLoadingBar(progress: progress)
                }
                if viewModel.selectedBackend == .apple && viewModel.hasTools {
                    appleToolHint
                }
                suggestionStrip
                if let attachment = viewModel.pendingAttachment {
                    attachmentChip(attachment)
                }
                composer
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { backendMenu }
            // Zero-size marker kept in the accessibility tree so UI tests can
            // read `app.staticTexts["chatSelectedBackendMarker"].label`. Lives
            // outside the toolbar so iOS 26's glass chrome doesn't render it
            // as an empty leading bubble.
            .overlay(alignment: .topLeading) {
                Text(viewModel.selectedBackend.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("chatSelectedBackendMarker")
            }
            .alert(
                "Chat error",
                isPresented: Binding(
                    get: { viewModel.error != nil },
                    set: { if !$0 { viewModel.clearError() } }
                ),
                presenting: viewModel.error
            ) { _ in
                Button("OK", role: .cancel) { viewModel.clearError() }
            } message: { err in
                Text(errorCopy(err))
            }
        }
        .accessibilityIdentifier("chatTabRoot")
        .onAppear {
            if viewModel.selectedBackend == .apple {
                viewModel.switchBackend(.gemma)
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty {
                    EmptyChatView(
                        backend: viewModel.selectedBackend,
                        profile: emptyStateViewModel?.profile,
                        summary: emptyStateViewModel?.summary,
                        now: Date(),
                        diapersEnabled: emptyStateViewModel?.diapersEnabled ?? true,
                        onNavigateToFeeds: onNavigateToFeeds,
                        onNavigateToDiapers: onNavigateToDiapers
                    )
                    .padding(.top, 24)
                    .padding(.horizontal, 20)
                    .task(id: viewModel.messages.isEmpty) {
                        await emptyStateViewModel?.refresh()
                    }
                } else {
                    // Pin a single snapshot for this render pass. Reading
                    // `viewModel.messages` live inside the ForEach closure
                    // crashes with an index out-of-range when a mid-stream
                    // backend switch replaces the array between the
                    // enumerated snapshot and the prev/next lookups.
                    let snapshot = viewModel.messages
                    let rows = pairToolMessages(snapshot)
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            let prevRow = index > 0 ? rows[index - 1] : nil
                            let nextRow = index < rows.count - 1 ? rows[index + 1] : nil

                            Group {
                                switch row {
                                case let .toolInvocation(invocation):
                                    let prevWasTool: Bool = {
                                        if case .toolInvocation = prevRow { return true }
                                        return false
                                    }()
                                    ChatToolInvocationCard(invocation: invocation)
                                        .padding(.top, prevWasTool ? 2 : 10)
                                case let .message(msg):
                                    let prevRole: ChatMessage.Role? = {
                                        if case let .message(p) = prevRow { return p.role }
                                        return nil
                                    }()
                                    let nextRole: ChatMessage.Role? = {
                                        if case let .message(n) = nextRow { return n.role }
                                        return nil
                                    }()
                                    let isFirstInGroup = prevRole != msg.role
                                    let isLastInGroup = nextRole != msg.role
                                    ChatMessageRow(
                                        message: msg,
                                        isFirstInGroup: isFirstInGroup,
                                        isLastInGroup: isLastInGroup
                                    )
                                    .padding(.top, isFirstInGroup && index > 0 ? 10 : 0)
                                }
                            }
                            .id(row.id)
                            .transition(.opacity)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                            .onAppear { isPinnedToBottom = true }
                            .onDisappear { isPinnedToBottom = false }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
            .background(backgroundGradient)
            .simultaneousGesture(
                TapGesture().onEnded { inputFocused = false }
            )
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                // A new message was appended. The user's intent on send is
                // to see it — so force-pin and scroll, regardless of where
                // the geometry settled mid-layout.
                guard newCount > oldCount else { return }
                isPinnedToBottom = true
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.text) { _, _ in
                // Streaming text growth: only follow if the user hasn't
                // scrolled away. That way a mid-stream scroll-up sticks.
                guard isPinnedToBottom else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom && !viewModel.messages.isEmpty {
                    scrollToBottomButton {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                        isPinnedToBottom = true
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: isPinnedToBottom)
        }
    }

    private func scrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(Color(.systemBackground))
                )
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        }
        .accessibilityIdentifier("chatScrollToBottomButton")
        .accessibilityLabel("Scroll to latest message")
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                backendTint(viewModel.selectedBackend).opacity(0.08),
                Color(.systemBackground),
            ],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    private func backendTint(_ backend: ChatBackend) -> Color {
        switch backend {
        case .apple: return .blue
        case .gemma: return .green
        case .qwen:  return .purple
        }
    }

    // MARK: - Apple FM tool hint

    private func modelLoadingBar(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Loading model on-device… \(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("chatModelLoadingBar")
    }

    private var appleToolHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Apple on-device chat can't run tools yet. Switch to Gemma to log feeds by voice.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatAppleToolHint")
    }

    // MARK: - Suggestion strip

    /// Dynamic chips the strip renders. Pulled from the empty-state view
    /// model's summary when loaded, otherwise falls back to a neutral
    /// default so the strip is never empty.
    private var suggestionPrompts: [ChatSuggestion] {
        if let loaded = emptyStateViewModel?.summary?.suggestions {
            return loaded
        }
        return ChatEmptyStateSummary.defaultSuggestions(
            now: Date(),
            calendar: .current,
            todayFeedCount: 0,
            lastFeed: nil
        )
    }

    private var suggestionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestionPrompts, id: \.slug) { prompt in
                    Button {
                        // Resolve timestamp at tap time, not at page-load time.
                        viewModel.input = prompt.resolvedText(now: Date())
                        if prompt.autoSend {
                            viewModel.send()
                            inputFocused = false
                        } else {
                            inputFocused = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            chipIcon(for: prompt.slug)
                                .font(.footnote.weight(.medium))
                            Text(prompt.displayText)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(chipTint(for: prompt.slug))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isStreaming)
                    .opacity(viewModel.isStreaming ? 0.5 : 1)
                    .accessibilityLabel(prompt.displayText)
                    .accessibilityHint(
                        prompt.autoSend
                            ? "Sends this message right away."
                            : "Fills the message field so you can edit before sending."
                    )
                    .accessibilityIdentifier("chatSuggestionChip_\(prompt.slug)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("chatSuggestionStrip")
    }

    @ViewBuilder
    private func chipIcon(for slug: String) -> some View {
        switch slug {
        case "feed60", "feedTotal":
            Image(systemName: "waterbottle.fill")
        case "pump20":
            Image(systemName: "drop.triangle.fill")
        default:
            Image(systemName: "sparkles")
        }
    }

    private func chipTint(for slug: String) -> Color {
        switch slug {
        case "feed60", "feedTotal":
            return Theme.feed
        case "pump20":
            return Theme.pumping
        default:
            return Theme.assistant
        }
    }

    // MARK: - Composer

    /// Small rounded card above the composer showing the thumbnail of the
    /// pending attachment plus an X button to clear it.
    private func attachmentChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 10) {
            Group {
                if let ui = UIImage(data: attachment.data) {
                    Image(uiImage: ui)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)

            Text("Image attached")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                viewModel.clearAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attached image")
            .accessibilityHint("Clears the image before sending")
            .accessibilityIdentifier("chatAttachmentRemoveButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .accessibilityIdentifier("chatAttachmentChip")
    }

    @ViewBuilder
    private var photoPickerButton: some View {
        if viewModel.supportsImageInput {
            PhotosPicker(
                selection: $photoPickerItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isStreaming)
            .accessibilityLabel("Attach image")
            .accessibilityHint("Pick a photo to send with your message")
            .accessibilityIdentifier("chatAttachImageButton")
            .onChange(of: photoPickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadPickedImage(newItem) }
            }
        }
    }

    private func loadPickedImage(_ item: PhotosPickerItem) async {
        defer { photoPickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                attachmentError = "Couldn't read that photo."
                return
            }
            let attachment = try await imageProcessor.process(imageData: data)
            await MainActor.run {
                viewModel.attach(attachment)
            }
        } catch {
            attachmentError = "Couldn't prepare that image: \(error)"
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            photoPickerButton
            TextField("Message", text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .accessibilityLabel("Message input")
                .accessibilityIdentifier("chatInputField")
                .disabled(viewModel.isStreaming)

            Button {
                viewModel.toggleDictation()
            } label: {
                Image(systemName: viewModel.isListening ? "stop.circle.fill" : "mic.fill")
                    .font(.title3)
                    .foregroundStyle(viewModel.isListening ? Color.red : Color.accentColor)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(viewModel.isListening ? "Voice input, listening" : "Voice input")
            .accessibilityHint(viewModel.isListening ? "Tap to stop dictating" : "Tap to dictate a message")
            .accessibilityIdentifier("chatMicButton")
            .disabled(viewModel.isStreaming)

            if viewModel.isStreaming {
                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Stop streaming")
                .accessibilityIdentifier("chatStopButton")
            } else {
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("chatSendButton")
                .disabled(
                    viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: - Backend menu

    @ToolbarContentBuilder
    private var backendMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(visibleBackends, id: \.self) { backend in
                    Button {
                        viewModel.switchBackend(backend)
                    } label: {
                        HStack {
                            Text(backendTitle(backend))
                            if viewModel.selectedBackend == backend {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityIdentifier("chatBackendOption_\(backend.rawValue)")
                }
            } label: {
                Label(backendTitle(viewModel.selectedBackend), systemImage: "brain.head.profile")
            }
            .accessibilityLabel("Chat backend picker, \(backendTitle(viewModel.selectedBackend))")
            .accessibilityHint("Tap to switch between Apple and Gemma backends")
            .accessibilityIdentifier("chatBackendMenu")
        }
    }

    private var visibleBackends: [ChatBackend] { [.gemma] }

    private func backendTitle(_ backend: ChatBackend) -> String {
        switch backend {
        case .apple: return "Apple"
        case .gemma: return "Gemma 4"
        case .qwen:  return "Qwen 3"
        }
    }

    private func errorCopy(_ error: ChatViewModel.Error) -> String {
        switch error {
        case .sessionUnavailable:
            return "This backend isn't available right now."
        case let .streamFailed(detail):
            return "The assistant stopped mid-reply: \(detail)"
        case .toolLoopLimitReached:
            return "The assistant kept asking for tools and was stopped after \(ChatViewModel.toolLoopLimit) rounds."
        case let .dictationFailed(detail):
            return detail
        case .attachmentNotSupported:
            return "This chat backend doesn't support images. Switch to Gemma to send the photo."
        }
    }
}

// MARK: - Row

private struct ChatMessageRow: View {
    let message: ChatMessage
    let isFirstInGroup: Bool
    let isLastInGroup: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.role == .assistant {
                avatar
                    .opacity(isFirstInGroup ? 1 : 0)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant,
                   let reasoning = message.reasoning,
                   !reasoning.text.isEmpty {
                    ReasoningDisclosure(text: reasoning.text)
                }
                if message.role == .user,
                   let first = message.attachments.first,
                   let ui = UIImage(data: first.data) {
                    Image(uiImage: ui)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(.separator), lineWidth: 1)
                        )
                        .accessibilityLabel("Attached image")
                        .accessibilityIdentifier("chatUserAttachmentThumbnail")
                }
                if !shouldSuppressBubble {
                    bubble
                }
                if let intent = message.intent {
                    IntentConfirmationCard(intent: intent)
                        .padding(.top, 4)
                }
                if isLastInGroup {
                    Text(timestampLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.tint)
        }
        .frame(width: 26, height: 26)
    }

    @ViewBuilder
    private var bubble: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }
            bubbleContent
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(bubbleColor)
                .foregroundStyle(foreground)
                .clipShape(bubbleShape)
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                .accessibilityIdentifier(
                    message.role == .user ? "chatUserBubble" : "chatAssistantBubble"
                )
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.isStreaming {
            TypingIndicator()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(MarkdownBlockParser.parse(message.text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .prose(let text):
                        Text(Self.inlineMarkdown(text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .table(let header, let rows):
                        MarkdownTableView(header: header, rows: rows)
                    }
                }
            }
        }
    }

    fileprivate static func inlineMarkdown(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: source, options: options) {
            return parsed
        }
        return AttributedString(source)
    }

    private var bubbleShape: some Shape {
        let corner: CGFloat = 18
        let tail: CGFloat = 6
        let isUser = message.role == .user
        return UnevenRoundedRectangle(
            topLeadingRadius: corner,
            bottomLeadingRadius: isUser ? corner : (isLastInGroup ? tail : corner),
            bottomTrailingRadius: isUser ? (isLastInGroup ? tail : corner) : corner,
            topTrailingRadius: corner,
            style: .continuous
        )
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    /// Hide the bubble entirely when a finished assistant message has no
    /// visible text — e.g. a reasoning-only or intent-only shell, or a turn
    /// that produced only whitespace. Reasoning (`ReasoningDisclosure`) and
    /// intent (`IntentConfirmationCard`) render independently above/below, so
    /// the bubble itself would just be an empty grey blob.
    private var shouldSuppressBubble: Bool {
        message.role == .assistant
            && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.isStreaming
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return Color(.secondarySystemBackground)
        case .system, .tool: return Color(.tertiarySystemBackground)
        }
    }

    private var foreground: Color {
        message.role == .user ? .white : .primary
    }

    private var timestampLabel: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: message.timestamp)
    }

    private var accessibilityLabel: String {
        let who = message.role == .user ? "You" : "Assistant"
        let body = message.text.isEmpty ? "streaming" : message.text
        return "\(who): \(body)"
    }
}

// MARK: - Reasoning disclosure

/// Collapsible "Thoughts" affordance rendered above an assistant bubble
/// when the backend surfaced a `.reasoning` delta. Collapsed by default
/// so a tired parent sees the answer first and can peek at the chain
/// of thought only when curious.
private struct ReasoningDisclosure: View {
    let text: String
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text("Thoughts")
                        .font(.caption.weight(.medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide assistant thoughts" : "Show assistant thoughts")
            .accessibilityIdentifier("chatReasoningToggle")

            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("chatReasoningBody")
            }
        }
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1.0 : 0.35)
            }
        }
        .frame(height: 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                phase = 2
            }
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    await MainActor.run { phase = (phase + 1) % 3 }
                }
            }
        }
        .accessibilityLabel("Assistant is typing")
    }
}

// MARK: - Empty state

private struct EmptyChatView: View {
    let backend: ChatBackend
    let profile: ChildProfile?
    let summary: ChatEmptyStateSummary?
    let now: Date
    var diapersEnabled: Bool = true
    var onNavigateToFeeds: (() -> Void)? = nil
    var onNavigateToDiapers: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var babyName: String { profile?.name ?? "your baby" }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Good night 🌙"
        }
    }

    private var ageLine: String {
        guard let profile else { return babyName }
        let age = ChildAge.shortLabel(dateOfBirth: profile.dateOfBirth, now: now)
        return "\(profile.name) · \(age) old"
    }

    var body: some View {
        VStack(spacing: 22) {
            hero
            if let summary {
                statusCard(summary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("chatEmptyState")
    }

    private var hero: some View {
        VStack(spacing: 2) {
            Text(greeting + ",")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("how is \(babyName) today?")
                .font(.system(size: 32, design: .serif).italic())
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(greeting). \(ageLine).")
    }

    private func statusCard(_ s: ChatEmptyStateSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row: "TODAY" + on-track dot
            HStack(spacing: 0) {
                Text("TODAY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                if s.todayFeedCount > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.growth)
                            .frame(width: 6, height: 6)
                        Text("On track")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Hero number + secondary text side-by-side
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(s.todayFeedVolumeMl)")
                        .font(.system(size: 52, design: .serif).italic())
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.feed)
                        .monospacedDigit()
                    Text("ml")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.feed.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("across \(s.todayFeedCount) feed\(s.todayFeedCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let last = s.lastFeed {
                        Text("last at \(Self.shortTimeFormatter.string(from: last.loggedAt))")
                            .font(.caption)
                            .foregroundStyle(s.isLastFeedStale ? Color.orange : Color.secondary.opacity(0.7))
                    }
                }
            }

            // 24-hour mini bar chart (feed volume per hour)
            let maxHourly = s.todayFeedsByHour.max() ?? 0
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<24, id: \.self) { h in
                    let vol = s.todayFeedsByHour[h]
                    let barH: CGFloat = maxHourly > 0 && vol > 0
                        ? max(4, 28 * CGFloat(vol) / CGFloat(maxHourly))
                        : 3
                    Capsule()
                        .fill(vol > 0 ? Theme.feed : Color(.systemFill).opacity(0.45))
                        .frame(maxWidth: .infinity, minHeight: barH, maxHeight: barH)
                }
            }
            .frame(height: 28)

            // Hour labels
            HStack {
                Text("12 AM")
                Spacer()
                Text("6 AM")
                Spacer()
                Text("Now")
                Spacer()
                Text("6 PM")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatStatusCard")
        .accessibilityLabel(accessibilitySummary(s))
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private func accessibilitySummary(_ s: ChatEmptyStateSummary) -> String {
        var parts = ["Today: \(s.todayFeedVolumeMl) millilitres, \(s.todayFeedCount) feed\(s.todayFeedCount == 1 ? "" : "s")"]
        if let last = s.lastFeed {
            parts.append("last feed at \(Self.shortTimeFormatter.string(from: last.loggedAt))")
            if s.isLastFeedStale { parts.append("overdue") }
        }
        return parts.joined(separator: ". ")
    }
}

private struct StatPill: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String
    var showChevron: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                    Text(value)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - Intent card

private struct IntentConfirmationCard: View {
    let intent: ToolUse

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Confirm") {
                // TODO(chat-merge): hand off to the matching feature repo.
                print("[chat] intent confirm tapped: \(intent)")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("Confirm \(title)")
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("chatIntentCard")
    }

    private var icon: String {
        switch intent {
        case .feed: return "waterbottle.fill"
        case .diaper: return "drop.fill"
        case .growth: return "chart.line.uptrend.xyaxis"
        case .appointment: return "calendar"
        case .milestone: return "star.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var title: String {
        switch intent {
        case .feed: return "Log feed"
        case .diaper: return "Log diaper"
        case .growth: return "Log growth"
        case .appointment: return "Add appointment"
        case .milestone: return "Log milestone"
        case .unknown: return "Not sure"
        }
    }

    private var subtitle: String {
        switch intent {
        case let .feed(d):
            return [d.volumeMl.map { "\($0) ml" }, d.source.map { "\($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        case let .diaper(d): return d.type.map { "\($0)" } ?? "tap to confirm"
        case let .growth(d): return d.weightGrams.map { "\($0) g" } ?? "tap to confirm"
        case let .appointment(d): return d.title ?? "tap to confirm"
        case let .milestone(d): return d.title ?? "tap to confirm"
        case let .unknown(reason): return reason
        }
    }
}

// MARK: - Preview

#Preview {
    let factory = FakeChatSessionFactory { _ in
        .tokensWithIntent(
            ["Sure ", "— ", "logging ", "a ", "120 ", "ml ", "bottle."],
            intent: .feed(FeedDraft(volumeMl: 120, source: .bottle)),
            perTokenDelay: .milliseconds(40)
        )
    }
    let vm = ChatViewModel(
        factory: factory,
        preferenceStore: UserDefaultsChatBackendStore()
    )
    vm.input = "fed 120ml bottle"
    return ChatTabView(viewModel: vm)
}

#if DEBUG
@MainActor
private func makeToolCallPreviewVM() -> ChatViewModel {
    let factory = FakeChatSessionFactory { _ in
        .tokens(["Logging ", "that ", "feed."], perTokenDelay: .milliseconds(30))
    }
    let vm = ChatViewModel(
        factory: factory,
        preferenceStore: UserDefaultsChatBackendStore()
    )
    let callArgs = ToolArguments([
        "volumeMl": .int(120),
        "source": .string("bottle"),
    ])
    var seeded: [ChatMessage] = []
    seeded.append(ChatMessage(role: .user, text: "Baby had 120ml from the bottle"))
    seeded.append(ChatMessage(role: .assistant, text: "Logging that now."))
    seeded.append(ChatMessage(
        role: .tool,
        toolEntry: .call(id: "t1", name: "createFeedLog", arguments: callArgs)
    ))
    seeded.append(ChatMessage(
        role: .tool,
        toolEntry: .result(
            id: "t1",
            name: "createFeedLog",
            result: ToolResult(content: "Logged 120 ml bottle feed.")
        )
    ))
    seeded.append(ChatMessage(role: .assistant, text: "Done — 120 ml bottle feed saved."))
    vm.previewSeed(seeded)
    return vm
}

#Preview("With tool calls") {
    ChatTabView(viewModel: makeToolCallPreviewVM())
}
#endif

// MARK: - Markdown block parser

/// Minimal block-level splitter for assistant messages. `AttributedString(markdown:)`
/// doesn't render GFM pipe tables at all — they land as literal pipes — so we
/// pre-split the text into prose runs and table runs and render tables with a
/// SwiftUI Grid. Everything non-table stays as a single prose block whose
/// inline markdown (bold/italic/code/links) is parsed by AttributedString.
enum MarkdownBlock: Equatable {
    case prose(String)
    case table(header: [String], rows: [[String]])
}

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var i = 0
        while i < lines.count {
            if let (table, consumed) = takeTable(lines, startingAt: i) {
                if !prose.isEmpty {
                    blocks.append(.prose(prose.joined(separator: "\n")))
                    prose.removeAll()
                }
                blocks.append(table)
                i += consumed
            } else {
                prose.append(lines[i])
                i += 1
            }
        }
        if !prose.isEmpty {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.prose(joined))
            }
        }
        return blocks
    }

    /// Try to consume a GFM pipe table starting at `start`. Returns the
    /// parsed block and the number of lines consumed, or nil if the lines
    /// don't form a valid table.
    private static func takeTable(_ lines: [String], startingAt start: Int) -> (MarkdownBlock, Int)? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start]
        let separatorLine = lines[start + 1]
        guard isTableRow(headerLine), isSeparatorRow(separatorLine) else { return nil }
        let header = splitRow(headerLine)
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count, isTableRow(lines[i]) {
            rows.append(splitRow(lines[i]))
            i += 1
        }
        guard !rows.isEmpty else { return nil }
        return (.table(header: header, rows: rows), i - start)
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|")
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let cells = splitRow(trimmed)
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { col in
                    Text(ChatMessageRow.inlineMarkdown(header.indices.contains(col) ? header[col] : ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
                .gridCellColumns(columnCount)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(ChatMessageRow.inlineMarkdown(row.indices.contains(col) ? row[col] : ""))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatMarkdownTable")
    }
}
