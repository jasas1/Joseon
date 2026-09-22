import AppKit

// Joseon app entry. AppKit lifecycle: the app lives in the menu bar and owns one main window.
#if DEBUG
// JOSEON_SPL_SELFCHECK=1: offline checks (tone generator, calibration arithmetic, dose ledger, preset store). No sound, no window.
if SPLSelfCheck.isRequested { exit(SPLSelfCheck.run()) }
// JOSEON_MEASURE_SELFCHECK=1: drives the whole "Measure your headphone…" controller with a fake input and a fake player. No sound, no microphone, no window.
if MeasureSelfCheck.isRequested { exit(MeasureSelfCheck.run()) }
#endif
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
