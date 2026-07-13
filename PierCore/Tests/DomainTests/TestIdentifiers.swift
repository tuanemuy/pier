import PierDomain

func sessionID(_ rawValue: String) throws -> SessionID {
    try SessionID.parse(rawValue).get()
}

func windowID(_ rawValue: String) throws -> WindowID {
    try WindowID.parse(rawValue).get()
}

func paneID(_ rawValue: String) throws -> PaneID {
    try PaneID.parse(rawValue).get()
}
