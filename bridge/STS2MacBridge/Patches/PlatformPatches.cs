using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using HarmonyLib;
using STS2MacBridge.Overlay;

namespace STS2MacBridge.Patches
{
    internal static class PlatformPatches
    {
        private const string HarmonyId = "io.github.lengsukq.sts2macbridge";
        private const string EnvModsDir = "STS2_BRIDGE_MODS_DIR";

        private const string TypeSentryService = "MegaCrit.Sts2.Core.Debug.SentryService";
        private const string TypePrefsSave = "MegaCrit.Sts2.Core.Saves.PrefsSave";
        private const string TypeOsDebugInfo = "MegaCrit.Sts2.Core.Debug.OsDebugInfo";
        private const string TypeModManager = "MegaCrit.Sts2.Core.Modding.ModManager";
        private const string TypeMod = "MegaCrit.Sts2.Core.Modding.Mod";
        private const string TypeModSource = "MegaCrit.Sts2.Core.Modding.ModSource";
        private const string TypeModManagerState = "MegaCrit.Sts2.Core.Modding.ModManagerState";

        private const BindingFlags AnyMember =
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;

        private static int _applied;
        private static Assembly? _sts2Assembly;

        public static void ApplyAll(Assembly sts2Assembly)
        {
            if (Interlocked.Exchange(ref _applied, 1) != 0)
            {
                return;
            }

            _sts2Assembly = sts2Assembly;
            var harmony = new Harmony(HarmonyId);

            Console.WriteLine($"[STS2MacBridge] Applying Harmony patches to {sts2Assembly.GetName().Name}...");

            PatchSentryInitialize(harmony, sts2Assembly);
            PatchPrefsUploadData(harmony, sts2Assembly);
            PatchOsDebugInfo(harmony, sts2Assembly);
            PatchExtraModsDirectory(harmony, sts2Assembly);
            OverlayBootstrap.RegisterLifecycleHook(harmony, sts2Assembly);

            Console.WriteLine("[STS2MacBridge] Harmony patch installation complete.");
            Console.Out.Flush();
        }

        private static void PatchSentryInitialize(Harmony harmony, Assembly sts2Assembly)
        {
            try
            {
                MethodInfo? target = FindMethod(sts2Assembly, TypeSentryService, "Initialize");
                if (target is null)
                {
                    Console.WriteLine("[STS2MacBridge] SentryService.Initialize not found; skipping patch.");
                    return;
                }

                MethodInfo prefix = RequirePatchMethod(nameof(SkipVoidMethodPrefix));
                harmony.Patch(target, prefix: new HarmonyMethod(prefix));
                Console.WriteLine("[STS2MacBridge] Patched SentryService.Initialize (skipped).");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Failed to patch SentryService.Initialize: {ex.Message}");
            }
        }

        private static void PatchPrefsUploadData(Harmony harmony, Assembly sts2Assembly)
        {
            try
            {
                Type? prefsType = FindType(sts2Assembly, TypePrefsSave);
                MethodInfo? getter = prefsType?.GetProperty("UploadData", AnyMember)?.GetGetMethod(true);
                if (getter is null)
                {
                    Console.WriteLine("[STS2MacBridge] PrefsSave.UploadData getter not found; skipping patch.");
                    return;
                }

                MethodInfo prefix = RequirePatchMethod(nameof(ReturnFalseBoolPrefix));
                harmony.Patch(getter, prefix: new HarmonyMethod(prefix));
                Console.WriteLine("[STS2MacBridge] Patched PrefsSave.UploadData getter (-> false).");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Failed to patch PrefsSave.UploadData: {ex.Message}");
            }
        }

        private static void PatchOsDebugInfo(Harmony harmony, Assembly sts2Assembly)
        {
            try
            {
                MethodInfo? logSystemInfo = FindMethod(sts2Assembly, TypeOsDebugInfo, "LogSystemInfo");
                if (logSystemInfo is not null)
                {
                    string prefixName = logSystemInfo.ReturnType == typeof(Task)
                        ? nameof(LogSystemInfoTaskPrefix)
                        : nameof(LogSystemInfoVoidPrefix);
                    harmony.Patch(logSystemInfo, prefix: new HarmonyMethod(RequirePatchMethod(prefixName)));
                    Console.WriteLine($"[STS2MacBridge] Patched OsDebugInfo.LogSystemInfo ({logSystemInfo.ReturnType.Name}).");
                }
                else
                {
                    Console.WriteLine("[STS2MacBridge] OsDebugInfo.LogSystemInfo not found; skipping patch.");
                }

                MethodInfo? getSystemInfoString = FindMethod(sts2Assembly, TypeOsDebugInfo, "GetSystemInfoString");
                if (getSystemInfoString is not null && getSystemInfoString.ReturnType == typeof(string))
                {
                    harmony.Patch(
                        getSystemInfoString,
                        prefix: new HarmonyMethod(RequirePatchMethod(nameof(GetSystemInfoStringPrefix))));
                    Console.WriteLine("[STS2MacBridge] Patched OsDebugInfo.GetSystemInfoString (macOS safe summary).");
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Failed to patch OsDebugInfo: {ex.Message}");
            }
        }

        private static void PatchExtraModsDirectory(Harmony harmony, Assembly sts2Assembly)
        {
            string? modsDir = Environment.GetEnvironmentVariable(EnvModsDir);
            if (string.IsNullOrWhiteSpace(modsDir))
            {
                return;
            }

            try
            {
                MethodInfo? initMethod = FindMethod(sts2Assembly, TypeModManager, "Initialize");
                if (initMethod is null)
                {
                    Console.WriteLine("[STS2MacBridge] ModManager.Initialize not found; skipping extra mods patch.");
                    return;
                }

                if (initMethod.ReturnType == typeof(Task))
                {
                    harmony.Patch(
                        initMethod,
                        postfix: new HarmonyMethod(RequirePatchMethod(nameof(ModManagerInitializeTaskPostfix))));
                }
                else
                {
                    harmony.Patch(
                        initMethod,
                        postfix: new HarmonyMethod(RequirePatchMethod(nameof(ModManagerInitializeSyncPostfix))));
                }

                Console.WriteLine($"[STS2MacBridge] Patched ModManager.Initialize for {EnvModsDir}='{modsDir}'.");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Failed to patch ModManager.Initialize: {ex.Message}");
            }
        }

        private static bool SkipVoidMethodPrefix()
        {
            return false;
        }

        private static bool ReturnFalseBoolPrefix(ref bool __result)
        {
            __result = false;
            return false;
        }

        private static bool LogSystemInfoTaskPrefix(ref Task __result)
        {
            Console.WriteLine($"[STS2MacBridge] {BuildMacSystemInfoSummary()}");
            __result = Task.CompletedTask;
            return false;
        }

        private static bool LogSystemInfoVoidPrefix()
        {
            Console.WriteLine($"[STS2MacBridge] {BuildMacSystemInfoSummary()}");
            return false;
        }

        private static bool GetSystemInfoStringPrefix(ref string __result)
        {
            __result = BuildMacSystemInfoSummary();
            return false;
        }

        private static void ModManagerInitializeTaskPostfix(object? __0, object? __1, ref Task __result)
        {
            __result = AppendExtraModsAfterInitializeAsync(__result, __0, __1);
        }

        private static void ModManagerInitializeSyncPostfix(object? __0, object? __1)
        {
            ScanAndLoadExtraMods(__0, __1);
        }

        private static async Task AppendExtraModsAfterInitializeAsync(
            Task originalTask,
            object? fileIo,
            object? settings)
        {
            // Preserve caller synchronization context so Godot main-thread mod APIs execute safely.
            await originalTask;
            ScanAndLoadExtraMods(fileIo, settings);
        }

        private static void ScanAndLoadExtraMods(object? fileIo, object? settings)
        {
            string? extraModsDir = Environment.GetEnvironmentVariable(EnvModsDir);
            if (string.IsNullOrWhiteSpace(extraModsDir) || !Directory.Exists(extraModsDir))
            {
                return;
            }

            Assembly? sts2Assembly = _sts2Assembly;
            if (sts2Assembly is null)
            {
                return;
            }

            try
            {
                Type? modManagerType = FindType(sts2Assembly, TypeModManager);
                Type? modType = FindType(sts2Assembly, TypeMod);
                Type? modSourceType = FindType(sts2Assembly, TypeModSource);
                if (modManagerType is null || modType is null || modSourceType is null)
                {
                    Console.Error.WriteLine("[STS2MacBridge] ModManager reflection types missing; cannot scan extra mods.");
                    return;
                }

                PropertyInfo? stateProp = modManagerType.GetProperty("State", AnyMember);
                object? currentState = stateProp?.GetValue(null);
                if (string.Equals(currentState?.ToString(), "Skipped", StringComparison.Ordinal))
                {
                    Console.WriteLine("[STS2MacBridge] ModManager state is Skipped (e.g. --nomods); skipping extra mods dir.");
                    return;
                }

                FieldInfo? modsField = modManagerType.GetField("_mods", AnyMember);
                MethodInfo? readDirMethod = modManagerType.GetMethod("ReadModsInDirRecursive", AnyMember);
                MethodInfo? tryLoadModMethod = modManagerType.GetMethod("TryLoadMod", AnyMember);
                if (modsField?.GetValue(null) is not IList modsList || readDirMethod is null || tryLoadModMethod is null)
                {
                    Console.Error.WriteLine("[STS2MacBridge] ModManager internals missing; cannot scan extra mods.");
                    return;
                }

                HashSet<string> existingKeys = CollectModKeys(modsList);
                int countBeforeScan = modsList.Count;

                object modsDirectoryEnum = Enum.Parse(modSourceType, "ModsDirectory");
                Type listOfModType = typeof(List<>).MakeGenericType(modType);
                object? discoveredList = Activator.CreateInstance(listOfModType);

                readDirMethod.Invoke(null, [extraModsDir, modsDirectoryEnum, discoveredList]);

                List<object> uniqueNewMods = DeduplicateNewMods(modsList, countBeforeScan, existingKeys);
                if (uniqueNewMods.Count == 0)
                {
                    Console.WriteLine($"[STS2MacBridge] Extra mods dir '{extraModsDir}' scanned (0 new mods).");
                    return;
                }

                InvokeOptionalModPreparation(modManagerType, settings);

                int loadedCount = 0;
                foreach (object mod in uniqueNewMods)
                {
                    if (!ShouldLoadDiscoveredMod(mod))
                    {
                        continue;
                    }

                    tryLoadModMethod.Invoke(null, [mod]);
                    loadedCount++;
                }

                FinalizeModManagerState(sts2Assembly, modManagerType, stateProp, fileIo);
                Console.WriteLine(
                    $"[STS2MacBridge] Scanned {EnvModsDir}='{extraModsDir}': loaded {loadedCount} new mod(s) (total {modsList.Count}).");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Failed scanning {EnvModsDir}='{extraModsDir}': {ex}");
            }
        }

        private static HashSet<string> CollectModKeys(IList modsList)
        {
            var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (object? mod in modsList)
            {
                if (mod is null)
                {
                    continue;
                }

                foreach (string key in GetModKeys(mod))
                {
                    keys.Add(key);
                }
            }

            return keys;
        }

        private static List<object> DeduplicateNewMods(
            IList modsList,
            int countBeforeScan,
            HashSet<string> existingKeys)
        {
            var uniqueNewMods = new List<object>();
            for (int index = modsList.Count - 1; index >= countBeforeScan; index--)
            {
                object? mod = modsList[index];
                if (mod is null)
                {
                    modsList.RemoveAt(index);
                    continue;
                }

                bool isDuplicate = false;
                List<string> modKeys = GetModKeys(mod);
                foreach (string key in modKeys)
                {
                    if (existingKeys.Contains(key))
                    {
                        isDuplicate = true;
                        break;
                    }
                }

                if (isDuplicate)
                {
                    modsList.RemoveAt(index);
                    continue;
                }

                foreach (string key in modKeys)
                {
                    existingKeys.Add(key);
                }

                uniqueNewMods.Add(mod);
            }

            uniqueNewMods.Reverse();
            return uniqueNewMods;
        }

        private static List<string> GetModKeys(object mod)
        {
            var keys = new List<string>(2);
            Type modType = mod.GetType();

            string? path = modType.GetField("path", AnyMember)?.GetValue(mod) as string;
            if (!string.IsNullOrWhiteSpace(path))
            {
                try
                {
                    keys.Add("path:" + Path.GetFullPath(path));
                }
                catch
                {
                    keys.Add("path:" + path);
                }
            }

            object? manifest = modType.GetField("manifest", AnyMember)?.GetValue(mod);
            string? modId = manifest?.GetType().GetField("id", AnyMember)?.GetValue(manifest) as string;
            if (!string.IsNullOrWhiteSpace(modId))
            {
                keys.Add("id:" + modId);
            }

            return keys;
        }

        private static void InvokeOptionalModPreparation(Type modManagerType, object? settings)
        {
            if (settings is not null)
            {
                modManagerType.GetMethod("RemoveDisabledMods", AnyMember)?.Invoke(null, null);
            }

            MethodInfo? sortMethod = modManagerType.GetMethod("SortModList", AnyMember);
            if (sortMethod is null)
            {
                return;
            }

            object? manualOrdering = settings?.GetType().GetProperty("ModList", AnyMember)?.GetValue(settings);
            ParameterInfo[] parameters = sortMethod.GetParameters();
            if (parameters.Length == 1)
            {
                object? arg = manualOrdering ?? Activator.CreateInstance(parameters[0].ParameterType);
                sortMethod.Invoke(null, [arg]);
            }
        }

        private static bool ShouldLoadDiscoveredMod(object mod)
        {
            object? state = mod.GetType().GetField("state", AnyMember)?.GetValue(mod);
            string? stateName = state?.ToString();
            return !string.Equals(stateName, "Loaded", StringComparison.Ordinal)
                && !string.Equals(stateName, "Disabled", StringComparison.Ordinal)
                && !string.Equals(stateName, "DisabledDuplicate", StringComparison.Ordinal);
        }

        private static void FinalizeModManagerState(
            Assembly sts2Assembly,
            Type modManagerType,
            PropertyInfo? stateProp,
            object? fileIo)
        {
            Type? stateEnumType = FindType(sts2Assembly, TypeModManagerState);
            if (stateProp is not null && stateEnumType is not null)
            {
                stateProp.SetValue(null, Enum.Parse(stateEnumType, "Initialized"));
            }

            if (fileIo is null)
            {
                return;
            }

            bool isModded = modManagerType.GetMethod("IsRunningModded", AnyMember)?.Invoke(null, null) is true;
            bool alreadyCopied = modManagerType.GetProperty("UnmoddedSavesWereCopied", AnyMember)?.GetValue(null) is true;
            if (isModded && !alreadyCopied)
            {
                modManagerType.GetMethod("CopyUnmoddedSaveFilesIfNeeded", AnyMember)?.Invoke(null, [fileIo]);
            }
        }

        private static string BuildMacSystemInfoSummary()
        {
            return $"STS2MacBridge Host: {RuntimeInformation.OSDescription} | "
                + $"Arch={RuntimeInformation.ProcessArchitecture} | "
                + $"Framework={RuntimeInformation.FrameworkDescription}";
        }

        private static Type? FindType(Assembly sts2Assembly, string fullName)
        {
            return sts2Assembly.GetType(fullName, throwOnError: false) ?? AccessTools.TypeByName(fullName);
        }

        private static MethodInfo? FindMethod(Assembly sts2Assembly, string typeName, string methodName)
        {
            Type? type = FindType(sts2Assembly, typeName);
            return type?.GetMethod(methodName, AnyMember);
        }

        private static MethodInfo RequirePatchMethod(string methodName)
        {
            return typeof(PlatformPatches).GetMethod(methodName, BindingFlags.NonPublic | BindingFlags.Static)
                ?? throw new MissingMethodException(typeof(PlatformPatches).FullName, methodName);
        }
    }
}
