import SwiftUI

/// The macOS 27 SDK declares SwiftUI's `@State` as a compiler macro whose plugin ships only with
/// full Xcode. Referring to the `State` *type* through an alias selects the property wrapper instead,
/// so this target builds with just the Command Line Tools. Use `@ViewState` wherever `@State` is meant.
typealias ViewState<Value> = SwiftUI.State<Value>
