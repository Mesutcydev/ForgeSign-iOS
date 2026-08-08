import Foundation

/// Prepares a disposable IPA with an injected dylib. The existing signer then
/// signs that prepared IPA through its unchanged code path.
enum DylibInjectionService {
    private struct BridgeError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    static func prepare(ipa: URL,
                        dylib: URL,
                        output: URL,
                        temporaryDirectory: URL,
                        injectIntoExtensions: Bool) -> Result<Void, Error> {
        #if !FORGE_BRIDGE
        return .failure(BridgeError(message: "Dylib injection is unavailable in this UI-preview build."))
        #else
        var messageBuffer = [CChar](repeating: 0, count: 1024)
        let status = ipa.path.withCString { ipaPath in
            dylib.path.withCString { dylibPath in
                output.path.withCString { outputPath in
                    temporaryDirectory.path.withCString { tempPath in
                        forgesign_inject_dylib_ipa(ipaPath,
                                                   dylibPath,
                                                   outputPath,
                                                   tempPath,
                                                   injectIntoExtensions ? 1 : 0,
                                                   &messageBuffer,
                                                   Int32(messageBuffer.count))
                    }
                }
            }
        }
        let message = String(decoding: messageBuffer
            .prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if status == 0 {
            return .success(())
        }
        return .failure(BridgeError(message: message.isEmpty ? "Dylib injection failed." : message))
        #endif
    }
}
