# Native interface decisions

The interface answers: “Is my screen prepared, and how do I restore it?” Recording Mode is the first and largest control; its timer and recovery state come from the same coordinator used by shortcuts.

The design skill dealt Achromatic ledger, seed 1001060864. This is a native SwiftUI/AppKit utility, so system typography, native controls, the requested translucent popover, and system light/dark appearance take precedence over the skill's web-specific fonts and opacity rules. No HTML or browser inspector applies to native view geometry. Visual checks use the running macOS app.

The signature element is a recording card that changes into the restoration control. Chrome remains neutral; red denotes an active recording session. Backdrop gradients and meshes are user-created output, not decorative interface backgrounds. State labels show unknown, partial and unavailable values honestly. There is no sample activity or simulated battery data.

Native visual review: sidebar navigation, actual system permission states and all fourteen backdrop swatches were inspected in the running app. A macOS 27 AppKit-hosting overlap was corrected so the section heading is fully visible. The final backdrop screenshot is saved at `build/Screenshots/Backdrop.png`. System typography and controls supply contrast and keyboard focus behavior; no web inspector result is claimed. Remaining direct popover, display and hardware checks are listed in VERIFICATION.md.
