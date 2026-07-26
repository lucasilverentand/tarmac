import ProjectDescription

let developmentTeam = "96452FLT2P"
let developmentSigningIdentity = "Apple Development: Luca Silverentand (R377UCHFT2)"

let debugSigningSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": .string(developmentSigningIdentity),
    "CODE_SIGNING_ALLOWED": "YES",
    "CODE_SIGNING_REQUIRED": "YES",
    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
    "DEVELOPMENT_TEAM": .string(developmentTeam),
]

let releaseSigningSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Developer ID Application",
    "DEVELOPMENT_TEAM": .string(developmentTeam),
]

let project = Project(
    name: "Tarmac",
    settings: .settings(
        base: [
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CURRENT_PROJECT_VERSION": "1",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "MARKETING_VERSION": "0.1.0",
            "SWIFT_VERSION": "6.2",
        ],
        configurations: [
            .debug(
                name: "Debug",
                settings: debugSigningSettings
            ),
            .release(
                name: "Release",
                settings: releaseSigningSettings
            ),
        ]
    ),
    targets: [
        .target(
            name: "Tarmac",
            destinations: .macOS,
            product: .app,
            bundleId: "studio.seventwo.tarmac",
            deploymentTargets: .macOS("27.0"),
            infoPlist: .extendingDefault(with: [:]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            entitlements: .file(path: "Tarmac.entitlements"),
            settings: .settings(
                configurations: [
                    .debug(
                        name: "Debug",
                        settings: debugSigningSettings
                    ),
                    .release(
                        name: "Release",
                        settings: releaseSigningSettings
                    ),
                ]
            )
        ),
        .target(
            name: "TarmacTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "studio.seventwo.tarmac.tests",
            deploymentTargets: .macOS("27.0"),
            sources: ["Tests/**"],
            dependencies: [
                .target(name: "Tarmac")
            ]
        ),
    ]
)
