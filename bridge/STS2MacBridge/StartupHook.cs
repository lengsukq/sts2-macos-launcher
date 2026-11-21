using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Threading;
using STS2MacBridge.Patches;

// Global namespace is required by .NET's DOTNET_STARTUP_HOOKS contract.
// Keep this type strictly BCL-only so CoreCLR can JIT Initialize() before sts2.dll
// or 0Harmony.dll are loaded into AssemblyLoadContext.Default.
public sealed class StartupHook
{
    private const string EnvSteamDylib = "STS2_BRIDGE_STEAM_DYLIB";
    private const string Sts2AssemblyName = "sts2";
    private const string SteamworksAssemblyName = "Steamworks.NET";
    private const string SteamDylibFileName = "libsteam_api.dylib";

    private static int _initialized;
    private static int _patchesApplied;
    private static IntPtr _cachedSteamHandle;
    private static readonly ConditionalWeakTable<AssemblyLoadContext, object> _hookedUnmanagedContexts = new();

    /// <summary>
    /// Native entry point invoked by libhostfxr_bridge.dylib when Godot embeds CoreCLR
    /// via hostfxr_get_runtime_delegate (which bypasses CorHost2::ExecuteAssembly).
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "InitializeUnmanaged")]
    public static int InitializeUnmanaged()
    {
        Initialize();
        Console.Out.Flush();
        Console.Error.Flush();
        return 0;
    }

    public static void Initialize()
    {
        if (Interlocked.Exchange(ref _initialized, 1) != 0)
        {
            return;
        }

        try
        {
            Console.WriteLine("[STS2MacBridge] StartupHook.Initialize() invoked.");

            AssemblyLoadContext.Default.Resolving += ResolveManagedAssembly;
            AssemblyLoadContext.Default.ResolvingUnmanagedDll += ResolveUnmanagedDll;

            AssemblyLoadContext? selfContext = AssemblyLoadContext.GetLoadContext(typeof(StartupHook).Assembly);
            if (selfContext is not null && !ReferenceEquals(selfContext, AssemblyLoadContext.Default))
            {
                selfContext.Resolving += ResolveManagedAssembly;
                selfContext.ResolvingUnmanagedDll += ResolveUnmanagedDll;
            }

            AppDomain.CurrentDomain.AssemblyLoad += OnAppDomainAssemblyLoad;

            InspectAlreadyLoadedAssemblies();
            Console.Out.Flush();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[STS2MacBridge] StartupHook.Initialize() failed: {ex}");
            Console.Error.Flush();
        }
    }

    private static void InspectAlreadyLoadedAssemblies()
    {
        foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            HandleLoadedAssembly(assembly);
        }
    }

    private static void OnAppDomainAssemblyLoad(object? sender, AssemblyLoadEventArgs args)
    {
        HandleLoadedAssembly(args.LoadedAssembly);
    }

    private static void HandleLoadedAssembly(Assembly assembly)
    {
        string? simpleName = assembly.GetName().Name;
        if (string.IsNullOrEmpty(simpleName))
        {
            return;
        }

        if (string.Equals(simpleName, SteamworksAssemblyName, StringComparison.OrdinalIgnoreCase))
        {
            TryAttachSteamContextResolver(assembly);
            return;
        }

        if (string.Equals(simpleName, Sts2AssemblyName, StringComparison.OrdinalIgnoreCase))
        {
            TryApplyPatchesDeferred(assembly);
        }
    }

    private static void TryAttachSteamContextResolver(Assembly steamworksAssembly)
    {
        try
        {
            // Never call NativeLibrary.SetDllImportResolver(steamworksAssembly, ...) here:
            // MegaCrit.Sts2.Core.Platform.Steam.SteamInitializer.Initialize() calls
            // SetDllImportResolver on Steamworks.NET itself, and .NET throws
            // InvalidOperationException if an assembly-level resolver is already registered.
            // Subscribing to the owning AssemblyLoadContext.ResolvingUnmanagedDll provides
            // a conflict-free fallback without colliding with the game's own resolver.
            AssemblyLoadContext? context = AssemblyLoadContext.GetLoadContext(steamworksAssembly);
            if (context is not null && !ReferenceEquals(context, AssemblyLoadContext.Default))
            {
                if (_hookedUnmanagedContexts.TryAdd(context, new object()))
                {
                    context.ResolvingUnmanagedDll += ResolveUnmanagedDll;
                    Console.WriteLine($"[STS2MacBridge] Attached ResolvingUnmanagedDll fallback to {context.Name ?? "Steamworks ALC"}.");
                }
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[STS2MacBridge] Failed to attach Steamworks unmanaged resolver: {ex.Message}");
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void TryApplyPatchesDeferred(Assembly sts2Assembly)
    {
        if (Interlocked.Exchange(ref _patchesApplied, 1) != 0)
        {
            return;
        }

        try
        {
            PlatformPatches.ApplyAll(sts2Assembly);
        }
        catch (Exception ex)
        {
            Interlocked.Exchange(ref _patchesApplied, 0);
            Console.Error.WriteLine($"[STS2MacBridge] Failed to apply Harmony patches: {ex}");
        }
    }

    private static Assembly? ResolveManagedAssembly(AssemblyLoadContext context, AssemblyName assemblyName)
    {
        string? simpleName = assemblyName.Name;
        if (string.IsNullOrEmpty(simpleName))
        {
            return null;
        }

        // Always share already-loaded assemblies (especially GodotSharp, sts2, 0Harmony)
        // from Godot's load context instead of loading a duplicate uninitialized copy into
        // hostfxr's isolated startup-hook ALC.
        AssemblyLoadContext? selfContext = AssemblyLoadContext.GetLoadContext(typeof(StartupHook).Assembly);
        Assembly? sameContextFallback = null;
        foreach (Assembly loaded in AppDomain.CurrentDomain.GetAssemblies())
        {
            if (!string.Equals(loaded.GetName().Name, simpleName, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            AssemblyLoadContext? loadedAlc = AssemblyLoadContext.GetLoadContext(loaded);
            if (!ReferenceEquals(loadedAlc, selfContext))
            {
                return loaded;
            }
            sameContextFallback ??= loaded;
        }
        if (sameContextFallback is not null)
        {
            return sameContextFallback;
        }

        string fileName = simpleName + ".dll";
        string? hookDir = Path.GetDirectoryName(typeof(StartupHook).Assembly.Location);
        if (!string.IsNullOrEmpty(hookDir))
        {
            string hookCandidate = Path.Combine(hookDir, fileName);
            if (File.Exists(hookCandidate))
            {
                return AssemblyLoadContext.Default.LoadFromAssemblyPath(hookCandidate);
            }
        }

        string baseCandidate = Path.Combine(AppContext.BaseDirectory, fileName);
        if (File.Exists(baseCandidate))
        {
            return AssemblyLoadContext.Default.LoadFromAssemblyPath(baseCandidate);
        }

        return null;
    }

    private static IntPtr ResolveUnmanagedDll(Assembly requestingAssembly, string unmanagedDllName)
    {
        return ResolveSteamDllImport(unmanagedDllName, requestingAssembly, null);
    }

    private static IntPtr ResolveSteamDllImport(
        string libraryName,
        Assembly assembly,
        DllImportSearchPath? searchPath)
    {
        if (!IsSteamApiLibraryName(libraryName))
        {
            return IntPtr.Zero;
        }

        IntPtr cached = Volatile.Read(ref _cachedSteamHandle);
        if (cached != IntPtr.Zero)
        {
            return cached;
        }

        string? targetPath = ResolveSteamDylibPath();
        if (string.IsNullOrEmpty(targetPath))
        {
            Console.Error.WriteLine(
                $"[STS2MacBridge] Could not locate {SteamDylibFileName} for native import '{libraryName}'.");
            return IntPtr.Zero;
        }

        if (NativeLibrary.TryLoad(targetPath, out IntPtr handle))
        {
            Volatile.Write(ref _cachedSteamHandle, handle);
            Console.WriteLine($"[STS2MacBridge] Redirected '{libraryName}' -> '{targetPath}'.");
            return handle;
        }

        Console.Error.WriteLine($"[STS2MacBridge] NativeLibrary.TryLoad failed for '{targetPath}'.");
        return IntPtr.Zero;
    }

    private static bool IsSteamApiLibraryName(string libraryName)
    {
        string normalized = Path.GetFileName(libraryName);
        return normalized.Equals("steam_api64", StringComparison.OrdinalIgnoreCase)
            || normalized.Equals("steam_api64.dll", StringComparison.OrdinalIgnoreCase)
            || normalized.Equals("steam_api", StringComparison.OrdinalIgnoreCase)
            || normalized.Equals("libsteam_api", StringComparison.OrdinalIgnoreCase)
            || normalized.Equals("libsteam_api.dylib", StringComparison.OrdinalIgnoreCase);
    }

    private static string? ResolveSteamDylibPath()
    {
        string? configured = Environment.GetEnvironmentVariable(EnvSteamDylib);
        if (!string.IsNullOrWhiteSpace(configured) && File.Exists(configured))
        {
            return configured;
        }

        string? hookDir = Path.GetDirectoryName(typeof(StartupHook).Assembly.Location);
        string[] candidates =
        [
            Path.Combine(AppContext.BaseDirectory, SteamDylibFileName),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "Frameworks", SteamDylibFileName)),
            hookDir is null ? string.Empty : Path.Combine(hookDir, SteamDylibFileName),
            hookDir is null ? string.Empty : Path.GetFullPath(Path.Combine(hookDir, "..", "..", "Frameworks", SteamDylibFileName)),
        ];

        foreach (string candidate in candidates)
        {
            if (!string.IsNullOrEmpty(candidate) && File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}
