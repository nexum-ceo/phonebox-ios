import AppIntents
import SwiftUI
import WidgetKit

/// The counterpart of the Android app's Quick Settings tile (PanelTile.kt): a control for the Control Center (and the
/// Lock Screen / Action button) that brings the panel to the front. Like the tile, it only opens the app and has no
/// state of its own. Add it with Control Center > + > PhoneBox.
@main
struct PhoneBoxControls: WidgetBundle {
    var body: some Widget { OpenPanelControl() }
}

struct OpenPanelControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "net.oxog.phonebox.deskpanel.open") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "phonebox://open")!)) {
                Label("PhoneBox", systemImage: "square.grid.2x2")
            }
        }
        .displayName("PhoneBox")
    }
}
