import Foundation
import STS2LauncherCore
import Testing

struct STS2LauncherCoreTests {
    private func makeTempDirectory(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sts2-launcher-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func compileMinimalMachO(at outputURL: URL, isDylib: Bool, arch: String = "arm64") throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).c")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let code = isDylib
            ? "int sts2_test_symbol(void) { return 42; }\n"
            : "int main(void) { return 0; }\n"
        try Data(code.utf8).write(to: sourceURL)

        var args = ["-arch", arch]
        if isDylib {
            args.append("-shared")
        }
        args.append(contentsOf: [sourceURL.path, "-o", outputURL.path])

        let result = try SystemCommandRunner.run(executablePath: "/usr/bin/clang", arguments: args)
        #expect(result.exitCode == 0, "clang failed: \(result.stderr)")
    }

    /// Builds a minimal syntactically valid PE32+ image for testing `PEAssemblyArchPatcher`.
    private func makeSyntheticPE32Plus(machine: UInt16, ilOnly: Bool) -> Data {
        var data = Data(count: 1024)
        // DOS header "MZ" and e_lfanew = 0x80
        data[0] = 0x4D
        data[1] = 0x5A
        writeUInt32LE(&data, value: 0x80, at: 0x3C)

        let peOffset = 0x80
        // "PE\0\0"
        data[peOffset] = 0x50
        data[peOffset + 1] = 0x45
        writeUInt16LE(&data, value: machine, at: peOffset + 4)
        writeUInt16LE(&data, value: 1, at: peOffset + 6)   // NumberOfSections = 1
        writeUInt16LE(&data, value: 240, at: peOffset + 20) // SizeOfOptionalHeader = 240

        let optOffset = peOffset + 24
        writeUInt16LE(&data, value: 0x020B, at: optOffset)        // PE32+ magic
        writeUInt32LE(&data, value: 16, at: optOffset + 108)      // NumberOfRvaAndSizes = 16
        // DataDirectory[14] (CLR header) -> RVA 0x2000, size 0x48
        let clrDirOffset = optOffset + 112 + (14 * 8)
        writeUInt32LE(&data, value: 0x2000, at: clrDirOffset)
        writeUInt32LE(&data, value: 0x48, at: clrDirOffset + 4)

        // Section #0: .text at VirtualAddress 0x2000, PointerToRawData 0x200, Size 0x200
        let secOffset = optOffset + 240
        writeUInt32LE(&data, value: 0x200, at: secOffset + 8)     // VirtualSize
        writeUInt32LE(&data, value: 0x2000, at: secOffset + 12)   // VirtualAddress
        writeUInt32LE(&data, value: 0x200, at: secOffset + 16)    // SizeOfRawData
        writeUInt32LE(&data, value: 0x200, at: secOffset + 20)    // PointerToRawData

        // IMAGE_COR20_HEADER at file offset 0x200
        let clrOffset = 0x200
        writeUInt32LE(&data, value: 0x48, at: clrOffset) // cb
        writeUInt32LE(&data, value: ilOnly ? 0x0000_0001 : 0x0000_0000, at: clrOffset + 16)
        return data
    }

    private func writeUInt16LE(_ data: inout Data, value: UInt16, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func writeUInt32LE(_ data: inout Data, value: UInt32, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func buildSyntheticBridgeRuntime(
        at root: URL,
        writeManifest: Bool,
        arch: String = "arm64",
        fmodMode: String = "full"
    ) throws -> URL {
        let fm = FileManager.default
        let armExecTemplate = root.appendingPathComponent(".template-exec-\(arch)")
        let armDylibTemplate = root.appendingPathComponent(".template-dylib-\(arch).dylib")
        try compileMinimalMachO(at: armExecTemplate, isDylib: false, arch: arch)
        try compileMinimalMachO(at: armDylibTemplate, isDylib: true, arch: arch)
        defer {
            try? fm.removeItem(at: armExecTemplate)
            try? fm.removeItem(at: armDylibTemplate)
        }

        // 1. Godot 4.5.1 Mono template .app
        let templateApp = root.appendingPathComponent("godot-template/macos_template.app", isDirectory: true)
        let releaseExec = templateApp.appendingPathComponent("Contents/MacOS/godot_macos_release.universal")
        let debugExec = templateApp.appendingPathComponent("Contents/MacOS/godot_macos_debug.universal")
        try fm.createDirectory(at: releaseExec.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: templateApp.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: armExecTemplate, to: releaseExec)
        try fm.copyItem(at: armExecTemplate, to: debugExec)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: releaseExec.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: debugExec.path)

        // 2. .NET 9 osx-arm64 runtime dir
        let dotnetDir = root.appendingPathComponent("dotnet-osx-arm64", isDirectory: true)
        try fm.createDirectory(at: dotnetDir, withIntermediateDirectories: true)
        for dylib in ["libhostfxr.dylib", "libhostpolicy.dylib", "libcoreclr.dylib", "libclrjit.dylib", "libSystem.Native.dylib"] {
            try fm.copyItem(at: armDylibTemplate, to: dotnetDir.appendingPathComponent(dylib))
        }
        try writeText("MAC_BCL_SYSTEM_RUNTIME", to: dotnetDir.appendingPathComponent("System.Runtime.dll"))
        try writeText("BRIDGE_GODOTSHARP_4_5_1", to: dotnetDir.appendingPathComponent("GodotSharp.dll"))
        try writeText("OSX_SYSTEM_IO_HASHING", to: dotnetDir.appendingPathComponent("System.IO.Hashing.dll"))

        // 3. Spine 4.2 framework
        let spineFramework = root.appendingPathComponent("gdextensions/spine/libspine_godot.macos.template_release.framework", isDirectory: true)
        try fm.createDirectory(at: spineFramework.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: armDylibTemplate, to: spineFramework.appendingPathComponent("libspine_godot.macos.template_release"))
        try writeText(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>libspine_godot.macos.template_release</string>
            <key>CFBundleIdentifier</key><string>com.esotericsoftware.spine.godot</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            </dict></plist>
            """,
            to: spineFramework.appendingPathComponent("Resources/Info.plist")
        )

        // 4. FMOD 2.03.06 (full or stub)
        var fmodFrameworkPath: String?
        var fmodDylibPaths: [String] = []
        if fmodMode == "full" {
            let fmodFw = root.appendingPathComponent("gdextensions/fmod/addons/fmod/libs/macos/libGodotFmod.macos.template_release.framework", isDirectory: true)
            try fm.createDirectory(at: fmodFw.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try fm.copyItem(at: armDylibTemplate, to: fmodFw.appendingPathComponent("libGodotFmod.macos.template_release"))
            try writeText(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                <key>CFBundleExecutable</key><string>libGodotFmod.macos.template_release</string>
                <key>CFBundleIdentifier</key><string>org.utopiarise.godotfmod</string>
                <key>CFBundlePackageType</key><string>FMWK</string>
                </dict></plist>
                """,
                to: fmodFw.appendingPathComponent("Resources/Info.plist")
            )
            let libfmod = fmodFw.deletingLastPathComponent().appendingPathComponent("libfmod.dylib")
            let libfmodstudio = fmodFw.deletingLastPathComponent().appendingPathComponent("libfmodstudio.dylib")
            try fm.copyItem(at: armDylibTemplate, to: libfmod)
            try fm.copyItem(at: armDylibTemplate, to: libfmodstudio)
            fmodFrameworkPath = fmodFw.path
            fmodDylibPaths = [libfmod.path, libfmodstudio.path]
        } else {
            let fmodStub = root.appendingPathComponent("stubs/libGodotFmod.stub.dylib")
            try fm.createDirectory(at: fmodStub.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: armDylibTemplate, to: fmodStub)
            fmodFrameworkPath = fmodStub.path
        }

        // 5. Native runtime bridges (hostfxr_bridge + Sentry no-op) & optional user Steamworks dylib
        let stubsDir = root.appendingPathComponent("stubs", isDirectory: true)
        try fm.createDirectory(at: stubsDir, withIntermediateDirectories: true)
        let sentryStub = stubsDir.appendingPathComponent("libsentry.macos.release.dylib")
        let sentryDep = stubsDir.appendingPathComponent("libSentry.dylib")
        let hostfxrBridge = stubsDir.appendingPathComponent("libhostfxr_bridge.dylib")
        try fm.copyItem(at: armDylibTemplate, to: sentryStub)
        try fm.copyItem(at: armDylibTemplate, to: sentryDep)
        try fm.copyItem(at: armDylibTemplate, to: hostfxrBridge)

        let steamDir = root.appendingPathComponent("steam", isDirectory: true)
        try fm.createDirectory(at: steamDir, withIntermediateDirectories: true)
        let steamApi = steamDir.appendingPathComponent("libsteam_api.dylib")
        try fm.copyItem(at: armDylibTemplate, to: steamApi)

        // 6. STS2MacBridge.dll
        let bridgeDll = root.appendingPathComponent("bridge/STS2MacBridge.dll")
        try writeText("STS2_MAC_BRIDGE_IL_PAYLOAD", to: bridgeDll)

        if writeManifest {
            let manifest: [String: Any] = [
                "godotVersion": "4.5.1-stable",
                "dotnetVersion": "9.0.10",
                "spineVersion": "4.2",
                "fmodVersion": "2.03.06",
                "fmodMode": fmodMode,
                "godotTemplateAppPath": templateApp.path,
                "dotnetRuntimeDirPath": dotnetDir.path,
                "godotSharpDllPath": dotnetDir.appendingPathComponent("GodotSharp.dll").path,
                "spineFrameworkPath": spineFramework.path,
                "fmodFrameworkPath": fmodFrameworkPath ?? "",
                "fmodDylibPaths": fmodDylibPaths,
                "sentryStubDylibPath": sentryStub.path,
                "sentryDepDylibPath": sentryDep.path,
                "steamApiDylibPath": steamApi.path,
                "hostfxrBridgeDylibPath": hostfxrBridge.path,
                "bridgeDllPath": bridgeDll.path
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent(GameConstants.bridgeManifestFileName))
        }

        return root
    }

    @Test("Windows Payload 检验保留纯托管依赖并过滤 Windows 原生/BCL，且前置识别全零损坏 zip")
    func testWindowsPayloadInspectionFilterAndCorruptedZipGuard() throws {
        let root = try makeTempDirectory(name: "win-inspect")
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("SlayTheSpire2-Windows", isDirectory: true)
        try writeText("FAKE_PCK_CONTENT_123456", to: nested.appendingPathComponent("SlayTheSpire2.pck"))
        try writeText(#"{"version":"v0.113.1"}"#, to: nested.appendingPathComponent("release_info.json"))

        let dataDir = nested.appendingPathComponent("data_sts2_windows_x86_64", isDirectory: true)
        try writeText("WIN_STS2_IL", to: dataDir.appendingPathComponent("sts2.dll"))
        try writeText("HARMONY", to: dataDir.appendingPathComponent("0Harmony.dll"))
        try writeText("MONOMOD", to: dataDir.appendingPathComponent("MonoMod.Backports.dll"))
        try writeText("SMART", to: dataDir.appendingPathComponent("SmartFormat.dll"))
        try writeText("JB", to: dataDir.appendingPathComponent("JetBrains.Annotations.dll"))
        try writeText("WIN_STEAM", to: dataDir.appendingPathComponent("Steamworks.NET.dll"))
        try writeText("SENTRY", to: dataDir.appendingPathComponent("Sentry.dll"))
        try writeText("SENTRY_GODOT", to: dataDir.appendingPathComponent("Sentry.Godot.dll"))
        try writeText("DX", to: dataDir.appendingPathComponent("Vortice.DXGI.dll"))
        try writeText("SHARPGEN", to: dataDir.appendingPathComponent("SharpGen.Runtime.dll"))
        try writeText("HASHING", to: dataDir.appendingPathComponent("System.IO.Hashing.dll"))
        // Must be filtered out:
        try writeText("BCL", to: dataDir.appendingPathComponent("System.Runtime.dll"))
        try writeText("MS", to: dataDir.appendingPathComponent("Microsoft.CSharp.dll"))
        try writeText("GODOT", to: dataDir.appendingPathComponent("GodotSharp.dll"))
        try writeText("NATIVE", to: dataDir.appendingPathComponent("coreclr.dll"))
        try writeText("NATIVE_HOST", to: dataDir.appendingPathComponent("hostfxr.dll"))
        try writeText("WIN_STEAM_NATIVE", to: dataDir.appendingPathComponent("steam_api64.dll"))

        let inspector = WindowsPayloadInspector()
        let info = try inspector.inspectDirectory(at: root)

        #expect(info.pckFileName == "SlayTheSpire2.pck")
        #expect(info.releaseVersion == "v0.113.1")
        #expect(info.sts2DllSha256.count == 64)
        #expect(info.supplementaryManagedDlls == [
            "0Harmony.dll",
            "JetBrains.Annotations.dll",
            "MonoMod.Backports.dll",
            "Sentry.Godot.dll",
            "Sentry.dll",
            "SharpGen.Runtime.dll",
            "SmartFormat.dll",
            "Steamworks.NET.dll",
            "System.IO.Hashing.dll",
            "Vortice.DXGI.dll"
        ])

        // Corrupted zero-filled zip must be rejected immediately before extraction
        let zeroZip = root.appendingPathComponent("corrupted-zeros.zip")
        try Data(count: 256 * 1024).write(to: zeroZip)
        let paths = LauncherPaths(
            baseDirectory: root.appendingPathComponent("launcher", isDirectory: true),
            gameUserDataDirectory: root.appendingPathComponent("game", isDirectory: true)
        )
        #expect(throws: LauncherError.self) {
            _ = try inspector.importSource(at: zeroZip, into: paths)
        }
    }

    @Test("PE32+ AMD64 ILONLY 程序集自动修补为 ARM64，且不误伤非 ILONLY 二进制")
    func testPEAssemblyArchPatcher() {
        var ilOnlyAmd64 = makeSyntheticPE32Plus(machine: PEAssemblyArchPatcher.machineAMD64, ilOnly: true)
        let patched = PEAssemblyArchPatcher.patchAMD64ILOnlyToARM64(in: &ilOnlyAmd64)
        #expect(patched)
        #expect(readUInt16LE(ilOnlyAmd64, at: 0x80 + 4) == PEAssemblyArchPatcher.machineARM64)

        // Already ARM64 -> no-op
        #expect(!PEAssemblyArchPatcher.patchAMD64ILOnlyToARM64(in: &ilOnlyAmd64))

        // Native / non-ILONLY AMD64 -> must NOT be patched
        var nativeAmd64 = makeSyntheticPE32Plus(machine: PEAssemblyArchPatcher.machineAMD64, ilOnly: false)
        #expect(!PEAssemblyArchPatcher.patchAMD64ILOnlyToARM64(in: &nativeAmd64))
        #expect(readUInt16LE(nativeAmd64, at: 0x80 + 4) == PEAssemblyArchPatcher.machineAMD64)
    }

    @Test("BridgeRuntimeInspector 支持 manifest 检测、无 manifest 目录扫描与非 arm64 拦截")
    func testBridgeRuntimeInspectorManifestFallbackAndArchCheck() throws {
        let root = try makeTempDirectory(name: "bridge-inspect")
        defer { try? FileManager.default.removeItem(at: root) }

        let inspector = BridgeRuntimeInspector()
        let emptyPaths = LauncherPaths(
            baseDirectory: root.appendingPathComponent("empty-base", isDirectory: true),
            gameUserDataDirectory: root.appendingPathComponent("game", isDirectory: true)
        )

        // Missing bridge-runtime -> not ready, 6 components reported
        let emptyInfo = inspector.inspect(paths: emptyPaths)
        #expect(!emptyInfo.isLaunchReady)
        #expect(emptyInfo.components.count == 6)

        // Manifest-backed arm64 runtime -> all 6 ready
        let fullRoot = try buildSyntheticBridgeRuntime(
            at: root.appendingPathComponent("bridge-manifest", isDirectory: true),
            writeManifest: true,
            arch: "arm64",
            fmodMode: "full"
        )
        let manifestInfo = inspector.inspect(paths: emptyPaths, customRootPath: fullRoot.path)
        #expect(manifestInfo.isLaunchReady)
        #expect(manifestInfo.fmodMode == "full")
        #expect(manifestInfo.components.count == 6)
        #expect(manifestInfo.components.allSatisfy { $0.isReady })

        // Convention scan fallback (no bridge-runtime-manifest.json) -> still ready
        let scanRoot = try buildSyntheticBridgeRuntime(
            at: root.appendingPathComponent("bridge-scan", isDirectory: true),
            writeManifest: false,
            arch: "arm64",
            fmodMode: "full"
        )
        let scanInfo = inspector.inspect(paths: emptyPaths, customRootPath: scanRoot.path)
        #expect(scanInfo.isLaunchReady)
        #expect(scanInfo.components.allSatisfy { $0.isReady })

        // x86_64-only runtime -> must fail arm64 verification
        let x64Root = try buildSyntheticBridgeRuntime(
            at: root.appendingPathComponent("bridge-x64", isDirectory: true),
            writeManifest: true,
            arch: "x86_64",
            fmodMode: "stub"
        )
        let x64Info = inspector.inspect(paths: emptyPaths, customRootPath: x64Root.path)
        #expect(!x64Info.isLaunchReady)
        #expect(x64Info.components.contains { !$0.isReady && $0.detail.contains("arm64") })
    }

    @Test("纯自建 BridgeRuntime 合成完整产出可签名 .app、清理 deps.json、修补 PE 并注入启动环境")
    func testBridgeRuntimeStagingEndToEnd() throws {
        let root = try makeTempDirectory(name: "bridge-staging")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = LauncherPaths(
            baseDirectory: root.appendingPathComponent("launcher-data", isDirectory: true),
            gameUserDataDirectory: root.appendingPathComponent("game-user-data", isDirectory: true)
        )
        try paths.ensureDirectoriesExist()

        _ = try buildSyntheticBridgeRuntime(
            at: paths.bridgeRuntimeDirectory,
            writeManifest: true,
            arch: "arm64",
            fmodMode: "full"
        )

        // Synthetic Windows payload with real PE32+ AMD64 ILONLY headers and Windows deps.json
        let winDir = root.appendingPathComponent("win-game", isDirectory: true)
        try writeText("WINDOWS_PCK_V0_113_1", to: winDir.appendingPathComponent("SlayTheSpire2.pck"))
        try writeText(#"{"version":"v0.113.1"}"#, to: winDir.appendingPathComponent("release_info.json"))
        let winData = winDir.appendingPathComponent("data_sts2_windows_x86_64", isDirectory: true)
        try FileManager.default.createDirectory(at: winData, withIntermediateDirectories: true)

        let amd64Sts2 = makeSyntheticPE32Plus(machine: PEAssemblyArchPatcher.machineAMD64, ilOnly: true)
        let amd64Steamworks = makeSyntheticPE32Plus(machine: PEAssemblyArchPatcher.machineAMD64, ilOnly: true)
        try amd64Sts2.write(to: winData.appendingPathComponent("sts2.dll"))
        try amd64Steamworks.write(to: winData.appendingPathComponent("Steamworks.NET.dll"))
        try writeText("HARMONY_IL", to: winData.appendingPathComponent("0Harmony.dll"))
        try writeText("SENTRY_IL", to: winData.appendingPathComponent("Sentry.dll"))
        try writeText("VORTICE_IL", to: winData.appendingPathComponent("Vortice.DXGI.dll"))
        try writeText("WIN_BCL_DO_NOT_COPY", to: winData.appendingPathComponent("System.Runtime.dll"))
        try writeText("WIN_CORECLR_DO_NOT_COPY", to: winData.appendingPathComponent("coreclr.dll"))
        try writeText("WIN_STEAM_NATIVE_DO_NOT_COPY", to: winData.appendingPathComponent("steam_api64.dll"))
        try writeText(
            """
            {
              "runtimeTarget": { "name": ".NETCoreApp,Version=v9.0/win-x64", "signature": "" },
              "compilationOptions": {},
              "targets": {
                ".NETCoreApp,Version=v9.0": {},
                ".NETCoreApp,Version=v9.0/win-x64": {
                  "sts2/0.1.0": {
                    "dependencies": {
                      "0Harmony": "2.4.2.0",
                      "Steamworks.NET": "1.0.0.0",
                      "runtimepack.Microsoft.NETCore.App.Runtime.win-x64": "9.0.7"
                    },
                    "runtime": { "sts2.dll": {} }
                  },
                  "runtimepack.Microsoft.NETCore.App.Runtime.win-x64/9.0.7": {
                    "runtime": { "System.Runtime.dll": {} },
                    "native": { "coreclr.dll": {}, "hostfxr.dll": {} }
                  },
                  "0Harmony/2.4.2.0": { "runtime": { "0Harmony.dll": {} } },
                  "Steamworks.NET/1.0.0.0": { "runtime": { "Steamworks.NET.dll": {} } }
                }
              },
              "libraries": {
                "sts2/0.1.0": { "type": "project", "serviceable": false, "sha512": "" },
                "runtimepack.Microsoft.NETCore.App.Runtime.win-x64/9.0.7": { "type": "runtimepack", "serviceable": false, "sha512": "" },
                "0Harmony/2.4.2.0": { "type": "reference", "serviceable": false, "sha512": "" },
                "Steamworks.NET/1.0.0.0": { "type": "reference", "serviceable": false, "sha512": "" }
              },
              "runtimes": { "win-x64": ["win", "any", "base"] }
            }
            """,
            to: winData.appendingPathComponent("sts2.deps.json")
        )

        // Manual user mod must remain untouched; legacy sts2_launcher_mod_order.json in mods/ must be cleaned up
        let manualModFile = paths.gameUserModsDirectory.appendingPathComponent("ManualUserMod/readme.txt")
        try writeText("keep me", to: manualModFile)
        let legacyOrderFile = paths.gameUserModsDirectory.appendingPathComponent("sts2_launcher_mod_order.json")
        try writeText(#"["old_mod"]"#, to: legacyOrderFile)

        // Managed mod in library
        let managedModDir = paths.modsLibraryDirectory.appendingPathComponent("QuickRestart", isDirectory: true)
        try writeText(#"{"id":"quick_restart","name":"Quick Restart","version":"1.0.0"}"#, to: managedModDir.appendingPathComponent("mod_manifest.json"))
        try writeText("MOD_DLL", to: managedModDir.appendingPathComponent("QuickRestart.dll"))

        let winInfo = try WindowsPayloadInspector().inspectDirectory(at: winDir)
        let bridgeInfo = BridgeRuntimeInspector().inspect(paths: paths)
        #expect(bridgeInfo.isLaunchReady)

        let mods = try ModRepository(paths: paths).loadMods()
        let config = LaunchConfiguration(
            renderingDriver: .metal,
            enableMods: true,
            modDeployTarget: .both,
            writeSteamAppIDFile: true
        )
        #expect(config.resolvedLaunchArguments().contains("--rendering-driver"))
        #expect(config.resolvedLaunchArguments().contains("metal"))

        let report = try RuntimeStager().stage(
            windowsPayload: winInfo,
            bridgeRuntime: bridgeInfo,
            enabledMods: mods,
            configuration: config,
            paths: paths,
            skipCodeSign: false
        )

        #expect(report.steamApiLinked)
        #expect(report.bridgeDllInjected)
        #expect(report.fmodMode == "full")
        #expect(report.didAdHocSign)
        #expect(report.deployedModIDs == ["quick_restart"])

        let fm = FileManager.default
        let stagedApp = URL(fileURLWithPath: report.stagedAppPath)
        let stagedData = stagedApp.appendingPathComponent("Contents/Resources/data_sts2_macos_arm64", isDirectory: true)
        let stagedFrameworks = stagedApp.appendingPathComponent("Contents/Frameworks", isDirectory: true)

        // Executable renamed & debug binary cleaned
        #expect(fm.isExecutableFile(atPath: stagedApp.appendingPathComponent("Contents/MacOS/SlayTheSpire2").path))
        #expect(!fm.fileExists(atPath: stagedApp.appendingPathComponent("Contents/MacOS/godot_macos_debug.universal").path))

        // Info.plist verification
        let plistData = try Data(contentsOf: stagedApp.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleExecutable"] as? String == "SlayTheSpire2")
        #expect(plist["CFBundleIdentifier"] as? String == "io.github.lengsukq.sts2-mac-bridge")
        #expect(plist["NSHighResolutionCapable"] as? Bool == true)

        // PCK cloned
        let stagedPck = try String(contentsOf: stagedApp.appendingPathComponent("Contents/Resources/SlayTheSpire2.pck"), encoding: .utf8)
        #expect(stagedPck == "WINDOWS_PCK_V0_113_1")

        // Pure managed copied, macOS BCL/CoreCLR/GodotSharp protected, Windows native excluded
        #expect(try String(contentsOf: stagedData.appendingPathComponent("System.Runtime.dll"), encoding: .utf8) == "MAC_BCL_SYSTEM_RUNTIME")
        #expect(try String(contentsOf: stagedData.appendingPathComponent("GodotSharp.dll"), encoding: .utf8) == "BRIDGE_GODOTSHARP_4_5_1")
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("libcoreclr.dylib").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("0Harmony.dll").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("Sentry.dll").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("Vortice.DXGI.dll").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("STS2MacBridge.dll").path))
        #expect(!fm.fileExists(atPath: stagedData.appendingPathComponent("coreclr.dll").path))
        #expect(!fm.fileExists(atPath: stagedData.appendingPathComponent("steam_api64.dll").path))

        // PE32+ AMD64 ILONLY -> ARM64 patched inside staged app, while original Windows DLL stays untouched
        let stagedSts2Bytes = try Data(contentsOf: stagedData.appendingPathComponent("sts2.dll"))
        let stagedSteamworksBytes = try Data(contentsOf: stagedData.appendingPathComponent("Steamworks.NET.dll"))
        let originalSts2Bytes = try Data(contentsOf: winData.appendingPathComponent("sts2.dll"))
        #expect(readUInt16LE(stagedSts2Bytes, at: 0x80 + 4) == PEAssemblyArchPatcher.machineARM64)
        #expect(readUInt16LE(stagedSteamworksBytes, at: 0x80 + 4) == PEAssemblyArchPatcher.machineARM64)
        #expect(readUInt16LE(originalSts2Bytes, at: 0x80 + 4) == PEAssemblyArchPatcher.machineAMD64)

        // deps.json & runtimeconfig.json cleaned for osx-arm64
        let depsText = try String(contentsOf: stagedData.appendingPathComponent("sts2.deps.json"), encoding: .utf8)
        #expect(depsText.contains(".NETCoreApp,Version=v9.0/osx-arm64"))
        #expect(!depsText.contains("win-x64"))
        #expect(!depsText.contains("coreclr.dll"))
        #expect(depsText.contains("libcoreclr.dylib"))
        #expect(depsText.contains("STS2MacBridge.dll"))

        let runtimeConfigText = try String(contentsOf: stagedData.appendingPathComponent("sts2.runtimeconfig.json"), encoding: .utf8)
        #expect(runtimeConfigText.contains("Microsoft.NETCore.App"))
        #expect(runtimeConfigText.contains("9.0.10"))

        // GDExtensions & Native Stubs deployed into Contents/Frameworks + hostfxr bridge shim + release_info.json
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libspine_godot.macos.template_release.framework").path))
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libGodotFmod.macos.template_release.framework").path))
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libfmod.dylib").path))
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libfmodstudio.dylib").path))
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libsentry.macos.release.dylib").path))
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libSentry.dylib").path))
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libsteam_api.dylib").path))
        #expect(fm.fileExists(atPath: stagedFrameworks.appendingPathComponent("libsteam_api64.dylib").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("libsteam_api.dylib").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("libsteam_api64.dylib").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("libhostfxr.dylib").path))
        #expect(fm.fileExists(atPath: stagedData.appendingPathComponent("libhostfxr_real.dylib").path))
        #expect(fm.fileExists(atPath: stagedApp.appendingPathComponent("Contents/Resources/release_info.json").path))
        #expect(fm.fileExists(atPath: stagedApp.appendingPathComponent("Contents/MacOS/release_info.json").path))
        let overrideCfg = try String(
            contentsOf: stagedApp.appendingPathComponent("Contents/Resources/override.cfg"),
            encoding: .utf8
        )
        #expect(overrideCfg.contains("settings/gdscript/always_track_call_stacks=false"))
        #expect(overrideCfg.contains("shader_compiler/shader_cache/enabled=true"))
        #expect(overrideCfg.contains("rendering_device/pipeline_cache/enable=true"))
        #expect(fm.fileExists(atPath: stagedApp.appendingPathComponent("Contents/MacOS/override.cfg").path))
        #expect(LaunchConfiguration().enableVerboseLogging == false)
        #expect(fm.fileExists(atPath: manualModFile.path))
        #expect(!fm.fileExists(atPath: legacyOrderFile.path))
        #expect(!fm.fileExists(atPath: stagedApp.appendingPathComponent("Contents/MacOS/mods/sts2_launcher_mod_order.json").path))

        // codesign --verify --deep --strict passes on real ad-hoc signed staged bundle
        let verifySign = try SystemCommandRunner.run(
            executablePath: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", stagedApp.path]
        )
        #expect(verifySign.exitCode == 0, "codesign verify failed: \(verifySign.stderr)")

        // GameProcessRunner bridge environment injection
        let env = GameProcessRunner.buildLaunchEnvironment(
            baseEnvironment: [:],
            stagedReport: report,
            configuration: config,
            paths: paths
        )
        #expect(env["DOTNET_STARTUP_HOOKS"] == stagedData.appendingPathComponent("STS2MacBridge.dll").path)
        #expect(env["STS2_BRIDGE_STEAM_DYLIB"] == stagedFrameworks.appendingPathComponent("libsteam_api.dylib").path)
        #expect(env["STS2_BRIDGE_MODS_DIR"] == paths.gameUserModsDirectory.path)
    }

    @Test("Mod 依赖校验能够检测缺失依赖、加载顺序倒置与循环依赖")
    func testModDependencyValidation() throws {
        let root = try makeTempDirectory(name: "mods")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = LauncherPaths(
            baseDirectory: root.appendingPathComponent("launcher", isDirectory: true),
            gameUserDataDirectory: root.appendingPathComponent("game", isDirectory: true)
        )
        let repo = ModRepository(paths: paths)

        let modA = ModItem(
            id: "mod_a",
            folderName: "mod_a",
            folderPath: "/tmp/mod_a",
            manifest: ModManifest(id: "mod_a", name: "Mod A", version: "1.0", dependencies: ["baselib", "mod_b"]),
            dllFiles: ["ModA.dll"],
            pckFiles: [],
            isEnabled: true,
            loadOrder: 0
        )
        let modB = ModItem(
            id: "mod_b",
            folderName: "mod_b",
            folderPath: "/tmp/mod_b",
            manifest: ModManifest(id: "mod_b", name: "Mod B", version: "1.0", dependencies: ["mod_a"]),
            dllFiles: ["ModB.dll"],
            pckFiles: [],
            isEnabled: true,
            loadOrder: 1
        )

        let issues = repo.validate(mods: [modA, modB])
        #expect(issues.contains { $0.modID == "mod_a" && $0.message.contains("baselib") && $0.severity == .error })
        #expect(issues.contains { $0.message.contains("排在当前 Mod 之后") && $0.severity == .warning })
        #expect(issues.contains { $0.message.contains("循环依赖") && $0.severity == .error })
    }

    @Test("存档互转强制先创建目标快照，且恢复快照能够完整还原旧数据")
    func testSaveTransferCreatesSafetySnapshotAndRestoresCleanly() throws {
        let root = try makeTempDirectory(name: "saves")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = LauncherPaths(
            baseDirectory: root.appendingPathComponent("launcher", isDirectory: true),
            gameUserDataDirectory: root.appendingPathComponent("game", isDirectory: true)
        )
        let accountDir = paths.gameUserDataDirectory.appendingPathComponent("steam/76561198000000001", isDirectory: true)
        try writeText("VANILLA_PROGRESS_V1", to: accountDir.appendingPathComponent("profile1/saves/progress.save"))
        try writeText("1", to: accountDir.appendingPathComponent("profile.save"))
        try writeText("OLD_MODDED_PROGRESS", to: accountDir.appendingPathComponent("modded/profile1/saves/progress.save"))
        try writeText("1", to: accountDir.appendingPathComponent("modded/profile.save"))

        let manager = SaveManager(paths: paths)
        let slots = manager.discoverAccountSlots()
        #expect(slots.count == 1)
        let slot = try #require(slots.first)
        #expect(slot.vanilla.exists)
        #expect(slot.modded.exists)

        let backupSnapshot = try manager.transfer(slot: slot, from: .vanilla, to: .modded)
        let afterTransfer = try String(
            contentsOf: accountDir.appendingPathComponent("modded/profile1/saves/progress.save"),
            encoding: .utf8
        )
        #expect(afterTransfer == "VANILLA_PROGRESS_V1")

        let vanillaStillThere = try String(
            contentsOf: accountDir.appendingPathComponent("profile1/saves/progress.save"),
            encoding: .utf8
        )
        #expect(vanillaStillThere == "VANILLA_PROGRESS_V1")

        _ = try manager.restoreSnapshot(backupSnapshot, to: slot)
        let restoredModded = try String(
            contentsOf: accountDir.appendingPathComponent("modded/profile1/saves/progress.save"),
            encoding: .utf8
        )
        #expect(restoredModded == "OLD_MODDED_PROGRESS")
        #expect(manager.listSnapshots().count == 2)
    }

    @Test("崩溃诊断能识别 SIGKILL、StartupHook、deps.json、Vortice/DXGI、Spine、FMOD 与 Steam 错误")
    func testCrashDiagnosticsRules() {
        let diag = CrashDiagnostics()
        let entries = [
            LogEntry(source: .stderr, level: .error, message: "Failed to load startup hook from DOTNET_STARTUP_HOOKS"),
            LogEntry(source: .stderr, level: .error, message: "hostpolicy error: failed to parse sts2.deps.json"),
            LogEntry(source: .stderr, level: .error, message: "DllNotFoundException: Unable to load dxgi.dll in Vortice.DXGI"),
            LogEntry(source: .stderr, level: .error, message: "Can't open dynamic library: libspine_godot.macos.template_release.framework"),
            LogEntry(source: .stderr, level: .error, message: "GDExtension error loading libGodotFmod.macos.template_release.framework"),
            LogEntry(source: .stderr, level: .error, message: "FileLoadException: The assembly architecture is not compatible"),
            LogEntry(source: .stdout, level: .warning, message: "SteamAPI_Init() failed; missing steam_appid.txt")
        ]
        let findings = diag.analyze(exitCode: 137, entries: entries)
        #expect(findings.contains { $0.id == "sigkill-codesign" })
        #expect(findings.contains { $0.id == "startup-hook-error" })
        #expect(findings.contains { $0.id == "deps-json-error" })
        #expect(findings.contains { $0.id == "vortice-dxgi-error" })
        #expect(findings.contains { $0.id == "spine-extension-error" })
        #expect(findings.contains { $0.id == "fmod-extension-error" })
        #expect(findings.contains { $0.id == "dotnet-mismatch" })
        #expect(findings.contains { $0.id == "steam-init" })
    }

    @Test("崩溃诊断不会对启动器自身日志或 Godot verbose 正常日志产生误报")
    func testCrashDiagnosticsAvoidsBenignFalsePositives() {
        let diag = CrashDiagnostics()
        let benignEntries = [
            LogEntry(source: .launcher, level: .info, message: "已注入 DOTNET_STARTUP_HOOKS=/tmp/STS2MacBridge.dll"),
            LogEntry(source: .launcher, level: .info, message: "桥接环境：STEAM_API=linked HUD=1 FMOD=full"),
            LogEntry(source: .stdout, level: .info, message: "Found hostfxr: /tmp/data_sts2_macos_arm64/libhostfxr.dylib"),
            LogEntry(source: .stdout, level: .info, message: "Orphan StringName: SpineSprite (static: 0, total: 2)"),
            LogEntry(source: .stdout, level: .info, message: "Loading resource: res://addons/fmod/FmodManager.gdc")
        ]
        let findings = diag.analyze(exitCode: 0, entries: benignEntries)
        #expect(findings.count == 1)
        #expect(findings.first?.id == "clean-exit")
    }

    @Test("游戏内悬浮窗开关默认启用，并正确传递 STS2_BRIDGE_HUD 环境变量")
    func testInGameOverlayEnvironmentSwitch() {
        let paths = LauncherPaths(
            baseDirectory: URL(fileURLWithPath: "/tmp/sts2-hud-test"),
            gameUserDataDirectory: URL(fileURLWithPath: "/tmp/sts2-hud-game")
        )
        let dummyReport = StagingReport(
            stagedAppPath: "/tmp/sts2-hud-test/staged/SlayTheSpire2.app",
            stagedExecutablePath: "/tmp/sts2-hud-test/staged/SlayTheSpire2.app/Contents/MacOS/SlayTheSpire2",
            windowsPayloadID: "win-1",
            windowsSts2Sha256: "abc",
            targetPckPath: "/tmp/pck",
            copiedManagedDlls: ["sts2.dll"],
            preservedMacNativeCount: 1,
            deployedModIDs: [],
            wroteSteamAppID: true,
            didAdHocSign: true,
            steamApiLinked: true,
            bridgeDllInjected: true,
            fmodMode: "full",
            warnings: []
        )

        let defaultConfig = LaunchConfiguration()
        #expect(defaultConfig.enableInGameOverlay == true)
        let envOn = GameProcessRunner.buildLaunchEnvironment(
            baseEnvironment: [:],
            stagedReport: dummyReport,
            configuration: defaultConfig,
            paths: paths
        )
        #expect(envOn["STS2_BRIDGE_HUD"] == "1")

        var disabledConfig = LaunchConfiguration()
        disabledConfig.enableInGameOverlay = false
        let envOff = GameProcessRunner.buildLaunchEnvironment(
            baseEnvironment: [:],
            stagedReport: dummyReport,
            configuration: disabledConfig,
            paths: paths
        )
        #expect(envOff["STS2_BRIDGE_HUD"] == "0")
    }

    @Test("空白用户目录下自动回退使用 .app 内置相对路径 BridgeRuntime，且纯 Swift Mach-O 解析不依赖 lipo")
    func testBundledBridgeRuntimeFallbackWithRelativeManifest() throws {
        let root = try makeTempDirectory(name: "bundled-fallback")
        defer { try? FileManager.default.removeItem(at: root) }

        let emptyUserBase = root.appendingPathComponent("empty-user-support", isDirectory: true)
        let bundledRuntime = root.appendingPathComponent("STS2MacLauncher.app/Contents/Resources/bridge-runtime", isDirectory: true)
        let paths = LauncherPaths(
            baseDirectory: emptyUserBase,
            gameUserDataDirectory: root.appendingPathComponent("game-user-data", isDirectory: true),
            bundledBridgeRuntimeDirectory: bundledRuntime
        )
        try paths.ensureDirectoriesExist()

        let templateApp = bundledRuntime.appendingPathComponent("godot-template/macos_template.app", isDirectory: true)
        try compileMinimalMachO(at: templateApp.appendingPathComponent("Contents/MacOS/godot_macos_release.arm64"), isDylib: false, arch: "arm64")
        let dotnetDir = bundledRuntime.appendingPathComponent("dotnet-osx-arm64", isDirectory: true)
        try compileMinimalMachO(at: dotnetDir.appendingPathComponent("libhostfxr.dylib"), isDylib: true, arch: "arm64")
        try compileMinimalMachO(at: dotnetDir.appendingPathComponent("libcoreclr.dylib"), isDylib: true, arch: "arm64")
        try compileMinimalMachO(at: dotnetDir.appendingPathComponent("libclrjit.dylib"), isDylib: true, arch: "arm64")
        try writeText("GODOT_SHARP", to: dotnetDir.appendingPathComponent("GodotSharp.dll"))

        let spineFw = bundledRuntime.appendingPathComponent("gdextensions/spine/libspine_godot.macos.template_release.framework", isDirectory: true)
        try compileMinimalMachO(at: spineFw.appendingPathComponent("libspine_godot.macos.template_release"), isDylib: true, arch: "arm64")

        let fmodFw = bundledRuntime.appendingPathComponent("gdextensions/fmod/libGodotFmod.macos.template_release.framework", isDirectory: true)
        try compileMinimalMachO(at: fmodFw.appendingPathComponent("libGodotFmod.macos.template_release"), isDylib: true, arch: "arm64")
        try compileMinimalMachO(at: bundledRuntime.appendingPathComponent("gdextensions/fmod/libfmod.dylib"), isDylib: true, arch: "arm64")
        try compileMinimalMachO(at: bundledRuntime.appendingPathComponent("gdextensions/fmod/libfmodstudio.dylib"), isDylib: true, arch: "arm64")

        try compileMinimalMachO(at: bundledRuntime.appendingPathComponent("stubs/libsentry.macos.release.dylib"), isDylib: true, arch: "arm64")
        try compileMinimalMachO(at: bundledRuntime.appendingPathComponent("stubs/libSentry.dylib"), isDylib: true, arch: "arm64")
        try compileMinimalMachO(at: bundledRuntime.appendingPathComponent("stubs/libhostfxr_bridge.dylib"), isDylib: true, arch: "arm64")
        try writeText("BRIDGE_DLL", to: bundledRuntime.appendingPathComponent("bridge/STS2MacBridge.dll"))

        // Portable manifest using ONLY relative paths (works when app is moved anywhere)
        let manifest = """
        {
          "godotVersion": "4.5.1-stable",
          "dotnetVersion": "9.0.23",
          "spineVersion": "4.2",
          "fmodVersion": "2.03.06",
          "fmodMode": "full",
          "godotTemplateAppPath": "godot-template/macos_template.app",
          "dotnetRuntimeDirPath": "dotnet-osx-arm64",
          "godotSharpDllPath": "dotnet-osx-arm64/GodotSharp.dll",
          "spineFrameworkPath": "gdextensions/spine/libspine_godot.macos.template_release.framework",
          "fmodFrameworkPath": "gdextensions/fmod/libGodotFmod.macos.template_release.framework",
          "fmodDylibPaths": [
            "gdextensions/fmod/libfmod.dylib",
            "gdextensions/fmod/libfmodstudio.dylib"
          ],
          "sentryStubDylibPath": "stubs/libsentry.macos.release.dylib",
          "sentryDepDylibPath": "stubs/libSentry.dylib",
          "hostfxrBridgeDylibPath": "stubs/libhostfxr_bridge.dylib",
          "bridgeDllPath": "bridge/STS2MacBridge.dll"
        }
        """
        try writeText(manifest, to: bundledRuntime.appendingPathComponent("bridge-runtime-manifest.json"))

        let info = BridgeRuntimeInspector().inspect(paths: paths)
        #expect(info.rootPath == bundledRuntime.path)
        #expect(info.isLaunchReady)
        #expect(info.components.count == 6)
        #expect(info.components.filter(\.isReady).count == 6)
    }
}
