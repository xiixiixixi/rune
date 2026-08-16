import Foundation

/// 未捕获异常记录：崩溃前把异常名/原因/调用栈写进 stderr，
/// 供终端启动时留档（NSApplication _crashOnException 重抛会走到这里）。
enum ExceptionLogger {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.prefix(25).joined(separator: "\n")
            FileHandle.standardError.write(
                Data("""
                ❌❌❌ 未捕获异常
                名称: \(exception.name.rawValue)
                原因: \(exception.reason ?? "-")
                栈:
                \(symbols)
                ❌❌❌
                """.utf8)
            )
        }
    }
}
