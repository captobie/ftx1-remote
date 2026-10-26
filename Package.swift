// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FTX1Core",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0")
    ],
    products: [
        // The shared logic layer consumed by both the Mac (server/hub) app
        // and the iOS/iPadOS (client) apps.
        .library(
            name: "FTX1Core",
            targets: ["FTX1Core"]
        ),
        // FT8/FT4 decode core. Mac-only in practice (audio-derived, like the
        // waterfall) — kept separate from FTX1Core so the iOS/iPadOS targets
        // (which also build FTX1Core) don't carry a C DSP library they never
        // use.
        .library(
            name: "FT8Kit",
            targets: ["FT8Kit"]
        ),
        // The CW receiver on CWKit (`captobie/cwdecode`), shared by the Mac
        // and the iPad. Separate from FTX1Core for the same reason as
        // FT8Kit: the iPhone doesn't decode CW and shouldn't carry the
        // Core ML model.
        .library(
            name: "FTX1CW",
            targets: ["FTX1CW"]
        ),
    ],
    dependencies: [
        // CWKit. The Mac app target also names it in the Xcode project;
        // keep the two requirements compatible.
        .package(url: "https://github.com/captobie/cwdecode", .upToNextMinor(from: "0.2.1")),
    ],
    targets: [
        .target(
            name: "FTX1Core",
            dependencies: [],
            // DSEG7 Classic (SIL OFL, DSEG-LICENSE.txt) for the VFO boxes'
            // 7-segment digits — see `VFODigitFonts`.
            resources: [.copy("Resources/Fonts")]
        ),
        .target(
            name: "FTX1CW",
            dependencies: ["FTX1Core", .product(name: "CWKit", package: "cwdecode")]
        ),
        .testTarget(
            name: "FTX1CoreTests",
            dependencies: ["FTX1Core"]
        ),
        // Vendored decode-only subset of kgoba/ft8_lib (MIT) + kissfft
        // (BSD-3-Clause) — see Sources/CFT8Lib/LICENSE-ft8lib.txt and
        // Sources/CFT8Lib/fft/LICENSE-kissfft.txt. -Wno-everything silences
        // warnings in third-party code we don't want to edit; safe here
        // since this package is only ever opened as the local/root package,
        // never as a transitive dependency of another SPM package.
        .target(
            name: "CFT8Lib",
            publicHeadersPath: ".",
            cSettings: [
                .unsafeFlags([
                    "-Wno-everything",
                    // common/monitor.c hardcodes `#define LOG_LEVEL LOG_INFO`
                    // before including ft8/debug.h, so it always logs "Block
                    // size = ...", "N_FFT = ...", etc. to stderr on every
                    // monitor_init — fine for ft8_lib's own CLI demo, not for
                    // a live decoder running every 15s in this app. Predefine
                    // LOG_PRINTF as a no-op so debug.h's own `#ifndef
                    // LOG_PRINTF` guard skips its default fprintf definition,
                    // silencing this without editing the vendored source.
                    "-DLOG_PRINTF(...)=",
                ])
            ]
        ),
        .target(
            name: "FT8Kit",
            dependencies: ["CFT8Lib"]
        ),
        .testTarget(
            name: "FT8KitTests",
            dependencies: ["FT8Kit", "CFT8Lib"],
            resources: [.copy("Resources")]
        ),
    ]
)
