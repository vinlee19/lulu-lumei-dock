import Foundation

/// 同时支持标准 .app 打包布局与 `swift run` 开发布局的资源入口。
enum AppResources {
    static let bundle: Bundle = {
        if let resourcesURL = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resourcesURL.appendingPathComponent("eureka_eureka.bundle", isDirectory: true)
           ) {
            return packaged
        }

        // SwiftPM 直接运行时使用自动生成的构建目录定位逻辑。
        return Bundle.module
    }()
}
