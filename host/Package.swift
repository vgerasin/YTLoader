// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YTLoader",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "YTLoader", targets: ["YTLoader"]),
    ],
    targets: [
        // Вся логика без интерфейса: очередь, настройки, аргументы yt-dlp, разбор вывода.
        .target(name: "YTLoaderCore"),
        // Окно, меню, Dock, уведомления — тонкая оболочка над ядром.
        .executableTarget(name: "YTLoader", dependencies: ["YTLoaderCore"]),
        .testTarget(name: "YTLoaderCoreTests", dependencies: ["YTLoaderCore"]),
    ]
)
