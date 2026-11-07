// Linux liest den Controllerzustand über explizite IPC-Snapshots. Die
// Persistenz- und Fachlogik bleibt dieselbe; Combine wird nur auf Apple für
// SwiftUI benötigt. Diese Wrapper erzeugen auf Linux keine Benachrichtigungen.
#if !canImport(Combine)
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

public struct SnapshotChangePublisher {
    public func send() {}
}

public extension ObservableObject {
    var objectWillChange: SnapshotChangePublisher { SnapshotChangePublisher() }
}
#endif
