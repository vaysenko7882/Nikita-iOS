import Foundation
import UIKit
import Display

enum PeerInfoClassicMetrics {
    static var isEnabled: Bool {
        return ClassicDesign.isEnabled
    }

    static var rowVerticalInset: CGFloat {
        return isEnabled ? 12.0 : 16.0
    }

    static var rowIconSize: CGFloat {
        return isEnabled ? 29.0 : 30.0
    }

    static var separatorRightInset: CGFloat {
        return isEnabled ? 0.0 : 16.0
    }

    static var extractedBackgroundDiameter: CGFloat {
        return isEnabled ? 28.0 : 52.0
    }

    static var labeledValueVerticalInset: CGFloat {
        return isEnabled ? 11.0 : 15.0
    }

    static var headerButtonCornerRadius: CGFloat {
        return isEnabled ? 11.0 : 16.0
    }

    static var editingFieldVerticalInset: CGFloat {
        return isEnabled ? 11.0 : 15.0
    }
}
