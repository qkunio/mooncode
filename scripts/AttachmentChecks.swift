import Foundation

/// Uses the actual ChatModel with a recording demo backend; no real account or model calls.
private actor AttachmentCheckClient: KapServicing {
    struct Upload: Sendable {
        let data: Data
        let name: String
        let mediaType: String
        let file: UploadedFile
    }

    let base = DemoClient(deviceID: "demo-macbook-pro")
    var uploads: [Upload] = []
    var prompts: [PromptBody] = []
    var failNextPrompt = false
    var failUploadAt: Int?
    var uploadAttempts = 0
    var beforeResponse: (@Sendable () async -> Void)?

    func failPromptOnce() { failNextPrompt = true }
    func failUploadOnce(at attempt: Int) { failUploadAt = attempt }
    func echoBeforeResponse(_ callback: @escaping @Sendable () async -> Void) { beforeResponse = callback }

    func uploadFile(_ data: Data, name: String, mediaType: String) async throws -> UploadedFile {
        uploadAttempts += 1
        if uploadAttempts == failUploadAt {
            failUploadAt = nil
            throw KapError.api(code: 50001, message: "test upload failure")
        }
        let file = UploadedFile(id: "upload-\(uploadAttempts)", name: name, mediaType: mediaType, size: data.count)
        uploads.append(Upload(data: data, name: name, mediaType: mediaType, file: file))
        return file
    }

    func sendPrompt(_ body: PromptBody, to sessionID: String) async throws -> PromptAccepted {
        prompts.append(body)
        if failNextPrompt {
            failNextPrompt = false
            throw KapError.api(code: 50001, message: "test prompt failure")
        }
        let accepted = try await base.sendPrompt(body, to: sessionID)
        if let callback = beforeResponse { beforeResponse = nil; await callback() }
        return accepted
    }

    func workspaces() async throws -> [Workspace] { try await base.workspaces() }
    func addWorkspace(root: String) async throws -> Workspace { try await base.addWorkspace(root: root) }
    func browseFs(_ path: String) async throws -> FsBrowse { try await base.browseFs(path) }
    func fsHome() async throws -> FsHome { try await base.fsHome() }
    func sessions(pageSize: Int) async throws -> SessionList { try await base.sessions(pageSize: pageSize) }
    func models() async throws -> [ModelInfo] { try await base.models() }
    func configDefaults() async throws -> ServerConfigDefaults { try await base.configDefaults() }
    func usage() async throws -> PlanUsage { try await base.usage() }
    func userInfo() async throws -> KimiUser? { try await base.userInfo() }
    func status(_ id: String) async throws -> SessionRuntimeStatus { try await base.status(id) }
    func updateProfile(_ id: String, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        try await base.updateProfile(id, agentConfig: agentConfig)
    }
    func renameSession(_ id: String, title: String) async throws -> SessionSummary {
        try await base.renameSession(id, title: title)
    }
    func deleteSession(_ id: String) async throws { try await base.deleteSession(id) }
    func transcript(_ id: String, pageSize: Int, beforeTurn: String?) async throws -> TranscriptPage {
        try await base.transcript(id, pageSize: pageSize, beforeTurn: beforeTurn)
    }
    func undo(_ id: String, count: Int) async throws { try await base.undo(id, count: count) }
    func createSession(in workspace: Workspace, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        try await base.createSession(in: workspace, agentConfig: agentConfig)
    }
    func abort(_ id: String) async throws { try await base.abort(id) }
    func pendingApprovals(_ id: String) async throws -> ApprovalList { try await base.pendingApprovals(id) }
    func resolve(approval id: String, in session: String, with decision: ApprovalDecisionBody) async throws -> Bool {
        try await base.resolve(approval: id, in: session, with: decision)
    }
    func pendingQuestions(_ id: String) async throws -> QuestionList { try await base.pendingQuestions(id) }
    func answer(question id: String, in session: String, with body: QuestionAnswerBody) async throws -> Bool {
        try await base.answer(question: id, in: session, with: body)
    }
    func dismiss(question id: String, in session: String) async throws {
        try await base.dismiss(question: id, in: session)
    }
}

@main
struct AttachmentChecks {
    @MainActor
    static func main() async throws {
        let endpoint = Endpoint(baseURL: URL(string: "http://127.0.0.1:1")!, deviceID: "test", displayName: "Test")
        let config = ComposerConfig(permission: .manual, modelID: nil, effort: nil)
        let client = AttachmentCheckClient()
        let workspace = try await client.workspaces().first!
        let session = try await client.createSession(in: workspace, agentConfig: config.patch)
        func makeChat(_ backend: AttachmentCheckClient, session: SessionSummary) -> ChatModel {
            ChatModel(session: session, workspace: workspace, config: config, client: backend,
                      endpoint: endpoint, tokenProvider: { nil }, liveUpdates: false,
                      onSessionCreated: { _ in }, onConfigChanged: { _ in })
        }

        // Four images exceed the JSON parser limit even without base64 inflation.
        let imageBytes = (0..<4).map { Data(repeating: UInt8($0 + 1), count: 1024 * 1024) }
        let chat = makeChat(client, session: session)
        defer { chat.stop() }
        chat.attachments = imageBytes.map { .image(jpeg: $0, thumbnail: Data()) }
            + [.file(name: "notes.txt", mediaType: "text/plain", data: Data("notes".utf8))]
        await chat.send("inspect the images")
        let uploads = await client.uploads
        let prompts = await client.prompts
        precondition(chat.errorMessage == nil && chat.attachments.isEmpty)
        precondition(uploads.count == 5 && prompts.count == 1)
        for i in 0..<4 {
            precondition(uploads[i].data == imageBytes[i] && uploads[i].mediaType == "image/jpeg")
            precondition(uploads[i].name.hasSuffix(".jpg"))
        }
        let encoded = try JSONEncoder().encode(prompts[0])
        precondition(encoded.count < 2048, "Image bytes must not inflate the prompt JSON")
        let content = try JSONDecoder().decode(JSONValue.self, from: encoded)["content"]!.arrayValue!
        precondition(content.count == 6)
        for i in 0..<4 {
            precondition(content[i]["type"]?.stringValue == "image")
            precondition(content[i]["source"]?["kind"]?.stringValue == "file")
            precondition(content[i]["source"]?["file_id"]?.stringValue == uploads[i].file.id)
            precondition(content[i]["source"]?["data"] == nil)
        }
        precondition(content[4]["type"]?.stringValue == "file")
        precondition(content[5]["text"]?.stringValue == "inspect the images")

        // A failed prompt keeps its attachments. Retry must not consume an unrelated new draft.
        let retryClient = AttachmentCheckClient()
        await retryClient.failPromptOnce()
        let retrySession = try await retryClient.createSession(in: workspace, agentConfig: config.patch)
        let retryChat = makeChat(retryClient, session: retrySession)
        defer { retryChat.stop() }
        let image = Attachment.image(jpeg: imageBytes[0], thumbnail: Data())
        retryChat.attachments = [image]
        await retryChat.send("retry the image")
        let failed = retryChat.optimisticPrompts.first!
        precondition(failed.failed && failed.attachmentCount == 1)
        let nextDraft = Attachment.file(name: "next.txt", mediaType: "text/plain", data: Data())
        retryChat.attachments = [nextDraft]
        await retryChat.retry(failed)
        let retryUploads = await retryClient.uploads
        let retryPrompts = await retryClient.prompts
        precondition(retryUploads.count == 2 && retryUploads.allSatisfy { $0.data == imageBytes[0] })
        precondition(retryPrompts.count == 2)
        precondition(retryChat.attachments.map(\.id) == [nextDraft.id])
        precondition(retryChat.optimisticPrompts.count == 1 && !retryChat.optimisticPrompts[0].failed)

        // Interrupted uploads do not submit a partial prompt; all attachments survive the retry.
        let uploadClient = AttachmentCheckClient()
        await uploadClient.failUploadOnce(at: 2)
        let uploadSession = try await uploadClient.createSession(in: workspace, agentConfig: config.patch)
        let uploadChat = makeChat(uploadClient, session: uploadSession)
        defer { uploadChat.stop() }
        uploadChat.attachments = [image, nextDraft]
        await uploadChat.send("both attachments")
        let beforeRetry = await uploadClient.prompts
        precondition(beforeRetry.isEmpty && uploadChat.optimisticPrompts[0].failed)
        precondition(uploadChat.optimisticPrompts[0].attachmentCount == 2)
        await uploadChat.retry(uploadChat.optimisticPrompts[0])
        let afterRetry = await uploadClient.prompts
        precondition(afterRetry.count == 1 && afterRetry[0].content.count == 3)

        // Reject an oversized attachment before any network request.
        let realClient = KapClient(endpoint: endpoint, tokenProvider: { nil })
        do {
            _ = try await realClient.uploadFile(Data(count: Attachment.maxUploadBytes + 1), name: "large.jpg", mediaType: "image/jpeg")
            preconditionFailure("Oversized upload was not rejected")
        } catch let KapError.api(code, message) {
            precondition(code == -1 && message.contains("9 MB"))
        }

        // The original image-only bug: an empty prompt needs receipt identity, not text equality.
        let onlyClient = AttachmentCheckClient()
        let onlySession = try await onlyClient.createSession(in: workspace, agentConfig: config.patch)
        let onlyChat = makeChat(onlyClient, session: onlySession)
        defer { onlyChat.stop() }
        onlyChat.attachments = [image, image]
        await onlyChat.send("")
        precondition(onlyChat.optimisticPrompts.count == 1)
        await onlyChat.reload()
        precondition(onlyChat.optimisticPrompts.isEmpty, "Accepted image-only bubble must disappear")
        let userImages = onlyChat.entries.compactMap { entry -> UserEntry? in
            if case let .user(user) = entry.kind { return user }
            return nil
        }
        precondition(userImages.count == 1 && userImages[0].text.isEmpty && userImages[0].attachments.count == 2)
        precondition(Set(userImages[0].attachments.map(\.id)).count == 2, "Same filenames must keep distinct image identities")
        precondition(userImages[0].attachments.allSatisfy { $0.source != nil })

        // A historical identical message must not swallow the current pending bubble.
        let repeatedClient = AttachmentCheckClient()
        let repeatedSession = try await repeatedClient.createSession(in: workspace, agentConfig: config.patch)
        let repeatedChat = makeChat(repeatedClient, session: repeatedSession)
        defer { repeatedChat.stop() }
        await repeatedChat.send("repeat")
        await repeatedChat.reload()
        await repeatedChat.abort()
        await repeatedChat.reload()
        await repeatedChat.send("repeat")
        precondition(repeatedChat.optimisticPrompts.count == 1, "Old text cannot acknowledge a new submission")
        await repeatedChat.reload()
        precondition(repeatedChat.optimisticPrompts.isEmpty)

        // WS echo can arrive before HTTP acceptance; reconcile again when the receipt arrives.
        let raceClient = AttachmentCheckClient()
        let raceSession = try await raceClient.createSession(in: workspace, agentConfig: config.patch)
        let raceChat = makeChat(raceClient, session: raceSession)
        defer { raceChat.stop() }
        await raceClient.echoBeforeResponse { await raceChat.reload() }
        raceChat.attachments = [image]
        await raceChat.send("")
        precondition(raceChat.optimisticPrompts.isEmpty)

        let mediaSource = AttachmentSource(.object(["kind": .string("session_media"), "fileId": .string("f_photo")]))
        precondition(mediaSource == .sessionMedia("f_photo"))
        let inline = try await realClient.attachmentData(.url(URL(string: "data:image/png;base64,AQID")!), sessionID: "test")
        precondition(inline == Data([1, 2, 3]))
        do {
            _ = try await realClient.attachmentData(.url(URL(string: "file:///tmp/not-an-image")!), sessionID: "test")
            preconditionFailure("Local file URL must not be loaded from a transcript")
        } catch {}
        print("PASS: image uploads, bounded JSON, retry preservation, image-only receipt reconciliation, repeated text, echo-before-response, preview sources and unique attachment identities")
    }
}
