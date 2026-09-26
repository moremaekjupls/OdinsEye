// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OdinsEye",
    // macOS 15: nothing is built or tested below it.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OdinsEye", targets: ["OdinsEye"])
    ],
    targets: [
        .executableTarget(
            name: "OdinsEye",
            path: "Sources/OdinsEye",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Только чистые сторы — разбор файла, дедупликация, порядок. Панель
        // сюда не входит и не должна: вырез, наведение и раскладка рельса
        // проверяются глазами, а тест на них врал бы чаще, чем ловил (#65).
        .testTarget(
            name: "OdinsEyeTests",
            dependencies: ["OdinsEye"],
            path: "Tests/OdinsEyeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
