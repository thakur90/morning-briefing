import Foundation

public struct BriefingFiles: Codable, Sendable, Equatable {
    public var html: URL
    public var markdown: URL
    public var context: URL
}

/// Writes `YYYY-MM-DD.html`, `.md` and `.context.json` to the output folder, atomically
/// (temp file + rename), so a half-finished run never leaves a partial briefing.
public struct OutputWriter: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(config: Config, paths: AppPaths = AppPaths()) {
        self.init(directory: paths.expand(config.outputDir))
    }

    public func files(for date: String) -> BriefingFiles {
        BriefingFiles(
            html: directory.appending(path: "\(date).html"),
            markdown: directory.appending(path: "\(date).md"),
            context: directory.appending(path: "\(date).context.json"))
    }

    @discardableResult
    public func write(_ briefing: Briefing, html: String, markdown: String) throws -> BriefingFiles {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = files(for: briefing.context.date)
        try JSONEncoder.briefing.encode(briefing).write(to: files.context, options: .atomic)
        try Data(markdown.utf8).write(to: files.markdown, options: .atomic)
        try Data(html.utf8).write(to: files.html, options: .atomic)  // last: its presence means "done"
        return files
    }

    /// The saved briefing for `date` (from its .context.json), if any.
    public func loadBriefing(for date: String) -> Briefing? {
        guard let data = try? Data(contentsOf: files(for: date).context) else { return nil }
        return try? JSONDecoder.briefing.decode(Briefing.self, from: data)
    }

    /// Today's briefing page, if it has been generated.
    public func existingPage(for date: String) -> URL? {
        let url = files(for: date).html
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
