import ProjectDescription

let project = Project(
    name: "Tarmac",
    settings: .settings(
        base: [
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "SWIFT_VERSION": "6.2",
        ],
        configurations: [
            .debug(
                name: "Debug",
                settings: [
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "-",
                    "CODE_SIGNING_REQUIRED": "NO",
                    "DEVELOPMENT_TEAM": "",
                ]
            ),
            .release(
                name: "Release",
                settings: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                ]
            ),
        ]
    ),
    targets: [
        .target(
            name: "Tarmac",
            destinations: .macOS,
            product: .app,
            bundleId: "studio.seventwo.tarmac",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [:]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            entitlements: .file(path: "Tarmac.entitlements"),
            settings: .settings(
                configurations: [
                    .debug(
                        name: "Debug",
                        settings: [
                            "CODE_SIGN_STYLE": "Manual",
                            "CODE_SIGN_IDENTITY": "-",
                            "CODE_SIGNING_REQUIRED": "NO",
                            "DEVELOPMENT_TEAM": "",
                        ]
                    ),
                    .release(
                        name: "Release",
                        settings: [
                            "CODE_SIGN_IDENTITY": "Apple Development",
                            "CODE_SIGN_STYLE": "Automatic",
                        ]
                    ),
                ]
            )
        ),
        .target(
            name: "TarmacTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "studio.seventwo.tarmac.tests",
            deploymentTargets: .macOS("26.0"),
            sources: ["Tests/**"],
            dependencies: [
                .target(name: "Tarmac"),
            ]
        ),
    ]
)
