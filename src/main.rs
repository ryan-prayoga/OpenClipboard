mod clip;
mod history;
mod shortcut;
mod worker;

use objc2::MainThreadMarker;
use objc2::rc::autoreleasepool;
use objc2_app_kit::NSApplication;

unsafe extern "C" {
    fn oc_install_delegate();
}

fn main() {
    autoreleasepool(|_| {
        let main_thread = MainThreadMarker::new().expect("AppKit requires the main thread");
        let application = NSApplication::sharedApplication(main_thread);
        unsafe { oc_install_delegate() };
        application.run();
    });
}
