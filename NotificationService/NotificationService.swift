import UserNotifications

/// Downloads the camera snapshot / finish photo Bambuddy references in the
/// push and attaches it, so the notification shows the actual print.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        let info = content.userInfo["bambuddy"] as? [String: Any]
        // Bambuddy sends a relative path ("/api/v1/archives/…") when its External URL
        // setting is empty, so resolve against the server address the app saved.
        guard let raw = info?["image_url"] as? String,
              var url = URL(string: raw, relativeTo: ServerConfig.serverURL)?.absoluteURL,
              url.host() != nil else {
            contentHandler(content)
            return
        }

        Task {
            // Snapshot URLs arrive with a token; archive photo URLs need one.
            if !raw.contains("token="), let token = await ServerConfig.streamToken() {
                url.append(queryItems: [URLQueryItem(name: "token", value: token)])
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            ServerConfig.authorize(&request)
            if let result = try? await URLSession.shared.download(for: request),
               (result.1 as? HTTPURLResponse)?.statusCode == 200 {
                let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".jpg")
                try? FileManager.default.moveItem(at: result.0, to: file)
                if let attachment = try? UNNotificationAttachment(identifier: "photo", url: file) {
                    content.attachments = [attachment]
                }
            }
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let content { contentHandler(content) }
    }
}
