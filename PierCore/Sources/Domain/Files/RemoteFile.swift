public struct RemoteFile: Equatable, Sendable {
    public let path: String
    public let contents: String
    private init(path: String, contents: String) {
        self.path = path; self.contents = contents
    }

    public static func parse(path: String, contents: String) -> Result<Self, RemoteFileError> {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .failure(.invalidPath) }
        return .success(Self(path: path, contents: contents))
    }

    public func editing(contents: String) -> Self {
        Self(path: path, contents: contents)
    }
}

public enum RemoteFileError: Error, Equatable, Sendable { case invalidPath, invalidEncoding }
