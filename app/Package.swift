// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Praatvol",
    platforms: [.macOS("14.2")],
    products: [.library(name: "PraatvolCore", targets: ["PraatvolCore"]),
               .executable(name: "Praatvol", targets: ["Praatvol"])],
    targets: [.target(name: "PraatvolCore"),
              .executableTarget(name: "Praatvol", dependencies: ["PraatvolCore"]),
              .testTarget(name: "PraatvolCoreTests", dependencies: ["PraatvolCore"])]
)
