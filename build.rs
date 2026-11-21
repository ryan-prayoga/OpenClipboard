use std::{env, path::Path, path::PathBuf, process::Command};

const MACOS_VERSION: &str = "27.0";

fn build_permission_guide(out_dir: &Path) {
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        _ => panic!("OpenClipboard requires an arm64 or x86_64 macOS target"),
    };
    let target = format!("{arch}-apple-macosx{MACOS_VERSION}");
    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-swift-version",
            "6",
            "-target",
            &target,
            "-parse-as-library",
            "-emit-library",
            "-static",
            "-O",
            "-module-name",
            "OpenClipboardPermissions",
            "-emit-objc-header-path",
        ])
        .arg(out_dir.join("OpenClipboardPermissions-Swift.h"))
        .arg("-o")
        .arg(out_dir.join("libopenclipboard_permissions.a"))
        .args([
            "native/AskForPermission/DraggableAppIconView.swift",
            "native/AskForPermission/SystemSettingsWindowTracker.swift",
        ])
        .status()
        .expect("could not invoke the macOS Swift compiler via xcrun");
    assert!(status.success(), "could not build the Accessibility guide");
}

fn main() {
    println!("cargo:rerun-if-changed=native");
    println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
    println!("cargo:rerun-if-env-changed=DEVELOPER_DIR");
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo did not supply OUT_DIR"));
    build_permission_guide(&out_dir);

    cc::Build::new()
        .files([
            "native/AccessibilityGuide.m",
            "native/App.m",
            "native/Clipboard.m",
            "native/Picker.m",
            "native/Results.m",
            "native/Tabs.m",
            "native/Toolbar.m",
        ])
        .include(&out_dir)
        .flag("-fobjc-arc")
        .flag(format!("-mmacosx-version-min={MACOS_VERSION}"))
        .compile("openclipboard_app");
    println!("cargo:rustc-link-lib=static=openclipboard_permissions");
    // Unoptimized Swift objects autolink libswift_Concurrency through @rpath
    // (release builds use the absolute /usr/lib/swift path), so debug and test
    // binaries need the system Swift runtime directory as an rpath.
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
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
