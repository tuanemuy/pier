public actor SessionOperationLease {
    private var isValid = true

    public init() {}

    public func invalidate() {
        isValid = false
    }

    public func check() throws {
        if !isValid { throw CancellationError() }
        try Task.checkCancellation()
    }
}
