fn main() {
    println!("cargo:rerun-if-changed=native");
    println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
    cc::Build::new()
        .files([
            "native/AccessibilityGuide.m",
            "native/App.m",
            "native/Clipboard.m",
            "native/Picker.m",
            "native/Results.m",
            "native/Toolbar.m",
        ])
        .flag("-fobjc-arc")
        .flag("-mmacosx-version-min=27.0")
        .compile("openclipboard_app");
    for framework in [
        "AppKit",
        "ApplicationServices",
        "QuartzCore",
        "ServiceManagement",
        "ImageIO",
        "UniformTypeIdentifiers",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
