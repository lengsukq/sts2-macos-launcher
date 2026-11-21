using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
using System.Text.Json;
using System.Threading;
using Godot;
using HarmonyLib;

namespace STS2MacBridge.Overlay
{
    /// <summary>
    /// Pure BCL + Harmony registrar with zero GodotSharp field/signature references so calling
    /// RegisterLifecycleHook during StartupHook never touches GodotSharp before Godot initializes it.
    /// </summary>
    internal static class OverlayBootstrap
    {
        private const string EnvHudEnabled = "STS2_BRIDGE_HUD";
        private static int _hookRegistered;
        private static Assembly? _sts2Assembly;

        public static bool IsHudEnabled()
        {
            string? raw = System.Environment.GetEnvironmentVariable(EnvHudEnabled);
            if (string.IsNullOrWhiteSpace(raw))
            {
                return true;
            }
            return !string.Equals(raw.Trim(), "0", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(raw.Trim(), "false", StringComparison.OrdinalIgnoreCase);
        }

        public static void RegisterLifecycleHook(Harmony harmony, Assembly sts2Assembly)
        {
            if (!IsHudEnabled())
            {
                Console.WriteLine("[STS2MacBridge] STS2_BRIDGE_HUD=0; skipping in-game overlay hook.");
                return;
            }

            if (Interlocked.Exchange(ref _hookRegistered, 1) != 0)
            {
                return;
            }

            _sts2Assembly = sts2Assembly;

            try
            {
                const BindingFlags any = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;
                Type? nGameType = sts2Assembly.GetType("MegaCrit.Sts2.Core.Nodes.NGame", throwOnError: false);
                MethodInfo? target = nGameType?.GetMethod("_Ready", any, Type.DefaultBinder, Type.EmptyTypes, null)
                    ?? nGameType?.GetMethod("_EnterTree", any, Type.DefaultBinder, Type.EmptyTypes, null)
                    ?? nGameType?.GetMethod("InitializePlatform", any);

                if (target is null)
                {
                    Console.WriteLine("[STS2MacBridge] NGame lifecycle entry not found for overlay hook.");
                    return;
                }

                MethodInfo postfix = typeof(OverlayBootstrap).GetMethod(
                    nameof(OnGameReadyPostfix),
                    BindingFlags.NonPublic | BindingFlags.Static)
                    ?? throw new MissingMethodException(nameof(OverlayBootstrap), nameof(OnGameReadyPostfix));

                harmony.Patch(target, postfix: new HarmonyMethod(postfix));
                Console.WriteLine($"[STS2MacBridge] Hooked NGame.{target.Name} for in-game performance HUD.");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Failed to register overlay lifecycle hook: {ex.Message}");
            }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void OnGameReadyPostfix()
        {
            try
            {
                Assembly selfAsm = typeof(OverlayBootstrap).Assembly;
                AssemblyLoadContext? selfAlc = AssemblyLoadContext.GetLoadContext(selfAsm);
                AssemblyLoadContext? godotAlc = _sts2Assembly is not null
                    ? AssemblyLoadContext.GetLoadContext(_sts2Assembly)
                    : null;

                Console.WriteLine($"[STS2MacBridge] Overlay dispatch: selfALC={selfAlc?.Name ?? "null"}, godotALC={godotAlc?.Name ?? "null"}");
                Console.Out.Flush();

                if (godotAlc is not null && !ReferenceEquals(godotAlc, selfAlc) && !string.IsNullOrEmpty(selfAsm.Location))
                {
                    // Load STS2MacBridge inside Godot's PluginLoadContext so all GodotSharp calls
                    // bind to Godot's initialized NativeFuncs instead of an uninitialized Default ALC copy.
                    Assembly inGodotAsm = godotAlc.LoadFromAssemblyPath(selfAsm.Location);
                    Type? overlayType = inGodotAsm.GetType("STS2MacBridge.Overlay.InGameOverlayManager", throwOnError: false);
                    MethodInfo? installMethod = overlayType?.GetMethod(
                        "ScheduleInstallOnMainThread",
                        BindingFlags.Public | BindingFlags.Static);
                    if (installMethod is not null)
                    {
                        installMethod.Invoke(null, null);
                        return;
                    }
                }

                InGameOverlayManager.ScheduleInstallOnMainThread();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Overlay dispatch failed: {ex}");
                Console.Error.Flush();
            }
        }
    }

    /// <summary>
    /// In-game performance monitor and quick-action HUD built purely via GodotSharp composition
    /// (no custom Godot Node subclassing required, so it works without Godot source generators).
    /// </summary>
    internal static class InGameOverlayManager
    {
        private const string OverlayLayerName = "STS2MacOverlayLayer";
        private const string ConfigFileName = "sts2_mac_hud.json";
        private const int FrameHistoryCapacity = 180;
        private const double UiRefreshIntervalSeconds = 0.25;
        private const double CpuSampleIntervalSeconds = 0.50;
        private const double MinDroppedFrameThresholdMs = 25.0;
        private const double SevereHitchThresholdMs = 100.0;
        private const double BackgroundPauseCutoffMs = 10_000.0;
        private const double ConfirmQuitWindowSeconds = 3.0;
        private const double HitchHighlightDurationSeconds = 5.0;
        private const float DefaultPosX = 16f;
        private const float DefaultPosY = 58f;

        private static readonly Color ColorBg = new(0.08f, 0.09f, 0.12f, 0.82f);
        private static readonly Color ColorBorder = new(1f, 1f, 1f, 0.16f);
        private static readonly Color ColorBtnBg = new(1f, 1f, 1f, 0.09f);
        private static readonly Color ColorBtnHover = new(1f, 1f, 1f, 0.17f);
        private static readonly Color ColorDangerBg = new(0.75f, 0.18f, 0.20f, 0.45f);
        private static readonly Color ColorDangerHover = new(0.85f, 0.22f, 0.24f, 0.72f);
        private static readonly Color ColorGood = new(0.29f, 0.87f, 0.50f, 1f);
        private static readonly Color ColorWarn = new(0.98f, 0.75f, 0.14f, 1f);
        private static readonly Color ColorBad = new(0.97f, 0.44f, 0.44f, 1f);
        private static readonly Color ColorTextPrimary = new(0.95f, 0.96f, 0.98f, 1f);
        private static readonly Color ColorTextMuted = new(0.70f, 0.74f, 0.82f, 1f);

        private static int _installScheduled;
        private static OverlaySession? _activeSession;

        public static void ScheduleInstallOnMainThread()
        {
            if (!OverlayBootstrap.IsHudEnabled())
            {
                return;
            }

            if (Interlocked.Exchange(ref _installScheduled, 1) != 0)
            {
                return;
            }

            try
            {
                Callable.From(TryInstallOnMainThread).CallDeferred();
            }
            catch (Exception ex)
            {
                Interlocked.Exchange(ref _installScheduled, 0);
                Console.Error.WriteLine($"[STS2MacBridge] Failed to defer HUD installation: {ex.Message}");
            }
        }

        private static void TryInstallOnMainThread()
        {
            try
            {
                if (_activeSession is not null)
                {
                    return;
                }

                if (Engine.GetMainLoop() is not SceneTree tree || tree.Root is null)
                {
                    Interlocked.Exchange(ref _installScheduled, 0);
                    return;
                }

                if (tree.Root.GetNodeOrNull(OverlayLayerName) is not null)
                {
                    return;
                }

                var session = new OverlaySession(tree);
                session.Attach();
                _activeSession = session;
                Console.WriteLine("[STS2MacBridge] In-game performance HUD installed (F9: toggle visibility, Shift+F9: expand/collapse).");
                Console.Out.Flush();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[STS2MacBridge] Failed to install in-game HUD: {ex}");
                Console.Error.Flush();
            }
        }

        private sealed class HudPreferences
        {
            public float X { get; set; } = DefaultPosX;
            public float Y { get; set; } = DefaultPosY;
            public bool Expanded { get; set; }
        }

        private sealed class OverlaySession
        {
            private readonly SceneTree _tree;
            private readonly Process _currentProcess = Process.GetCurrentProcess();
            private readonly double[] _frameTimesMs = new double[FrameHistoryCapacity];
            private readonly double[] _sortScratchMs = new double[FrameHistoryCapacity];
            private readonly double _droppedFrameThresholdMs;
            private readonly int _logicalCoreCount = Math.Max(1, System.Environment.ProcessorCount);
            private readonly string _rendererName;

            private CanvasLayer _layer = null!;
            private PanelContainer _panel = null!;
            private Label _statusDotLabel = null!;
            private Label _compactLabel = null!;
            private Button _expandButton = null!;
            private VBoxContainer _detailsBox = null!;
            private Label _fpsDetailLabel = null!;
            private Label _frameTimeDetailLabel = null!;
            private Label _dropDetailLabel = null!;
            private Label _cpuDetailLabel = null!;
            private Label _memDetailLabel = null!;
            private Label _renderDetailLabel = null!;
            private Button _fullscreenButton = null!;
            private Button _quitButton = null!;
            private Button _forceQuitButton = null!;

            private int _frameHistoryCount;
            private int _frameHistoryCursor;
            private long _droppedFrames;
            private long _severeHitches;
            private double _maxHitchMs;
            private double _lastHitchMs;
            private long _lastHitchTimestamp;

            private long _lastFrameTimestamp;
            private long _lastUiRefreshTimestamp;
            private long _lastCpuSampleTimestamp;
            private TimeSpan _lastTotalProcessorTime;

            private double _cpuNormalizedPercent;
            private double _cpuCoreUnits;
            private double _rssMegabytes;
            private double _managedHeapMegabytes;

            private bool _isExpanded;
            private bool _isVisible = true;
            private bool _isDragging;
            private Vector2 _dragOffset;
            private bool _wasF9Pressed;

            private long _quitConfirmDeadlineTicks;
            private long _forceQuitConfirmDeadlineTicks;

            public OverlaySession(SceneTree tree)
            {
                _tree = tree;
                float refreshHz = DisplayServer.ScreenGetRefreshRate();
                if (refreshHz < 30f || refreshHz > 240f)
                {
                    refreshHz = 60f;
                }
                _droppedFrameThresholdMs = Math.Max((1000.0 / refreshHz) * 1.5, MinDroppedFrameThresholdMs);
                _rendererName = DetectRendererSummary();
            }

            public void Attach()
            {
                HudPreferences prefs = LoadPreferences();
                _isExpanded = prefs.Expanded;

                _layer = new CanvasLayer
                {
                    Name = OverlayLayerName,
                    Layer = 128,
                    ProcessMode = Node.ProcessModeEnum.Always
                };

                var theme = BuildHudTheme();

                _panel = new PanelContainer
                {
                    Name = "HudCard",
                    Theme = theme,
                    MouseFilter = Control.MouseFilterEnum.Stop,
                    Position = new Vector2(prefs.X, prefs.Y)
                };
                _panel.AddThemeStyleboxOverride("panel", CreatePanelStyleBox());
                _panel.GuiInput += OnPanelGuiInput;

                var rootVBox = new VBoxContainer();
                rootVBox.AddThemeConstantOverride("separation", 6);
                rootVBox.MouseFilter = Control.MouseFilterEnum.Pass;

                var headerRow = BuildHeaderRow();
                rootVBox.AddChild(headerRow);

                _detailsBox = BuildDetailsSection();
                _detailsBox.Visible = _isExpanded;
                rootVBox.AddChild(_detailsBox);

                _panel.AddChild(rootVBox);
                _layer.AddChild(_panel);
                _tree.Root.AddChild(_layer);

                long now = Stopwatch.GetTimestamp();
                _lastFrameTimestamp = now;
                _lastUiRefreshTimestamp = now;
                _lastCpuSampleTimestamp = now;
                _lastTotalProcessorTime = SafeGetTotalProcessorTime();

                ClampPanelToViewport();
                RefreshCpuAndMemory(now, force: true);
                RefreshLabels(now);

                _tree.ProcessFrame += OnProcessFrame;
            }

            private HBoxContainer BuildHeaderRow()
            {
                var row = new HBoxContainer();
                row.AddThemeConstantOverride("separation", 8);
                row.MouseFilter = Control.MouseFilterEnum.Pass;

                _statusDotLabel = new Label
                {
                    Text = "●",
                    MouseFilter = Control.MouseFilterEnum.Ignore
                };
                _statusDotLabel.AddThemeFontSizeOverride("font_size", 11);
                _statusDotLabel.AddThemeColorOverride("font_color", ColorGood);
                row.AddChild(_statusDotLabel);

                _compactLabel = new Label
                {
                    Text = "60 FPS · 16.6ms · CPU 0% · 漏帧 0",
                    MouseFilter = Control.MouseFilterEnum.Ignore
                };
                _compactLabel.AddThemeFontSizeOverride("font_size", 12);
                _compactLabel.AddThemeColorOverride("font_color", ColorTextPrimary);
                row.AddChild(_compactLabel);

                _expandButton = CreateCompactButton(_isExpanded ? "收起 ▴" : "展开 ▾", isDanger: false);
                _expandButton.Pressed += OnToggleExpandPressed;
                row.AddChild(_expandButton);

                return row;
            }

            private VBoxContainer BuildDetailsSection()
            {
                var box = new VBoxContainer();
                box.AddThemeConstantOverride("separation", 5);
                box.MouseFilter = Control.MouseFilterEnum.Pass;

                var dividerTop = new HSeparator { MouseFilter = Control.MouseFilterEnum.Ignore };
                box.AddChild(dividerTop);

                _fpsDetailLabel = CreateMetricLabel("帧率：-- FPS · 1% Low -- FPS");
                _frameTimeDetailLabel = CreateMetricLabel("帧时间：-- ms · 最大卡顿 0.0 ms");
                _dropDetailLabel = CreateMetricLabel("漏帧(>25ms)：0 · 重卡(>=100ms)：0");
                _cpuDetailLabel = CreateMetricLabel("CPU：-- % (-- 核)");
                _memDetailLabel = CreateMetricLabel("内存：RSS -- MB · .NET 堆 -- MB");
                _renderDetailLabel = CreateMetricLabel($"渲染：{_rendererName}");

                box.AddChild(_fpsDetailLabel);
                box.AddChild(_frameTimeDetailLabel);
                box.AddChild(_dropDetailLabel);
                box.AddChild(_cpuDetailLabel);
                box.AddChild(_memDetailLabel);
                box.AddChild(_renderDetailLabel);

                var dividerMid = new HSeparator { MouseFilter = Control.MouseFilterEnum.Ignore };
                box.AddChild(dividerMid);

                var actionsRow1 = new HBoxContainer();
                actionsRow1.AddThemeConstantOverride("separation", 6);

                var resetButton = CreateCompactButton("重置统计", isDanger: false);
                resetButton.Pressed += OnResetStatsPressed;
                actionsRow1.AddChild(resetButton);

                _fullscreenButton = CreateCompactButton(GetFullscreenButtonText(), isDanger: false);
                _fullscreenButton.Pressed += OnToggleFullscreenPressed;
                actionsRow1.AddChild(_fullscreenButton);

                var hideButton = CreateCompactButton("隐藏(F9)", isDanger: false);
                hideButton.Pressed += OnHidePressed;
                actionsRow1.AddChild(hideButton);

                box.AddChild(actionsRow1);

                var actionsRow2 = new HBoxContainer();
                actionsRow2.AddThemeConstantOverride("separation", 6);

                _quitButton = CreateCompactButton("快速结束游戏", isDanger: true);
                _quitButton.SizeFlagsHorizontal = Control.SizeFlags.ExpandFill;
                _quitButton.Pressed += OnQuickQuitPressed;
                actionsRow2.AddChild(_quitButton);

                _forceQuitButton = CreateCompactButton("强退", isDanger: true);
                _forceQuitButton.Pressed += OnForceQuitPressed;
                actionsRow2.AddChild(_forceQuitButton);

                box.AddChild(actionsRow2);

                var tipLabel = new Label
                {
                    Text = "拖动顶部移动位置 · F9 显隐 · Shift+F9 展开",
                    MouseFilter = Control.MouseFilterEnum.Ignore
                };
                tipLabel.AddThemeFontSizeOverride("font_size", 10);
                tipLabel.AddThemeColorOverride("font_color", ColorTextMuted);
                box.AddChild(tipLabel);

                return box;
            }

            private void OnProcessFrame()
            {
                if (!GodotObject.IsInstanceValid(_layer) || !GodotObject.IsInstanceValid(_panel))
                {
                    return;
                }

                long now = Stopwatch.GetTimestamp();
                RecordFrameSample(now);
                PollHotkeys();
                ExpireQuitConfirmationsIfNeeded(now);

                double elapsedCpuSec = (now - _lastCpuSampleTimestamp) / (double)Stopwatch.Frequency;
                if (elapsedCpuSec >= CpuSampleIntervalSeconds)
                {
                    RefreshCpuAndMemory(now, force: false);
                }

                if (!_isVisible)
                {
                    return;
                }

                double elapsedUiSec = (now - _lastUiRefreshTimestamp) / (double)Stopwatch.Frequency;
                if (elapsedUiSec >= UiRefreshIntervalSeconds)
                {
                    _lastUiRefreshTimestamp = now;
                    RefreshLabels(now);
                }
            }

            private void RecordFrameSample(long nowTicks)
            {
                double frameMs = (nowTicks - _lastFrameTimestamp) * 1000.0 / Stopwatch.Frequency;
                _lastFrameTimestamp = nowTicks;

                if (frameMs <= 0.0 || frameMs >= BackgroundPauseCutoffMs)
                {
                    return;
                }

                _frameTimesMs[_frameHistoryCursor] = frameMs;
                _frameHistoryCursor = (_frameHistoryCursor + 1) % FrameHistoryCapacity;
                if (_frameHistoryCount < FrameHistoryCapacity)
                {
                    _frameHistoryCount++;
                }

                if (frameMs > _droppedFrameThresholdMs)
                {
                    _droppedFrames++;
                }

                if (frameMs >= SevereHitchThresholdMs)
                {
                    _severeHitches++;
                    _lastHitchMs = frameMs;
                    _lastHitchTimestamp = nowTicks;
                }

                if (frameMs > _maxHitchMs)
                {
                    _maxHitchMs = frameMs;
                }
            }

            private void PollHotkeys()
            {
                bool f9Down = Input.IsKeyPressed(Key.F9);
                if (f9Down && !_wasF9Pressed)
                {
                    bool shiftDown = Input.IsKeyPressed(Key.Shift);
                    if (shiftDown)
                    {
                        if (!_isVisible)
                        {
                            SetHudVisible(true);
                        }
                        OnToggleExpandPressed();
                    }
                    else
                    {
                        SetHudVisible(!_isVisible);
                    }
                }
                _wasF9Pressed = f9Down;
            }

            private void RefreshCpuAndMemory(long nowTicks, bool force)
            {
                double wallMs = (nowTicks - _lastCpuSampleTimestamp) * 1000.0 / Stopwatch.Frequency;
                TimeSpan currentCpu = SafeGetTotalProcessorTime();

                if (!force && wallMs > 1.0)
                {
                    double deltaCpuMs = (currentCpu - _lastTotalProcessorTime).TotalMilliseconds;
                    if (deltaCpuMs >= 0.0)
                    {
                        _cpuCoreUnits = deltaCpuMs / wallMs;
                        _cpuNormalizedPercent = Math.Clamp((_cpuCoreUnits / _logicalCoreCount) * 100.0, 0.0, 100.0);
                    }
                }

                _lastCpuSampleTimestamp = nowTicks;
                _lastTotalProcessorTime = currentCpu;

                try
                {
                    _currentProcess.Refresh();
                    _rssMegabytes = _currentProcess.WorkingSet64 / (1024.0 * 1024.0);
                }
                catch
                {
                    // Fallback to Godot static memory if OS process refresh is temporarily unavailable.
                    _rssMegabytes = Performance.GetMonitor(Performance.Monitor.MemoryStatic) / (1024.0 * 1024.0);
                }

                _managedHeapMegabytes = GC.GetTotalMemory(forceFullCollection: false) / (1024.0 * 1024.0);
            }

            private void RefreshLabels(long nowTicks)
            {
                double fps = Engine.GetFramesPerSecond();
                ComputeFrameStats(out double avgFrameMs, out double onePercentLowFps);

                bool recentHitch = _lastHitchTimestamp > 0
                    && ((nowTicks - _lastHitchTimestamp) / (double)Stopwatch.Frequency) <= HitchHighlightDurationSeconds;

                Color healthColor = ResolveHealthColor(fps, recentHitch);
                _statusDotLabel.AddThemeColorOverride("font_color", healthColor);

                string fpsStr = fps > 0 ? Math.Round(fps).ToString("0", CultureInfo.InvariantCulture) : "--";
                string avgMsStr = avgFrameMs > 0 ? avgFrameMs.ToString("0.0", CultureInfo.InvariantCulture) : "--";
                string cpuStr = _cpuNormalizedPercent.ToString("0", CultureInfo.InvariantCulture);

                if (recentHitch)
                {
                    string hitchStr = _lastHitchMs.ToString("0", CultureInfo.InvariantCulture);
                    _compactLabel.Text = $"{fpsStr} FPS · {avgMsStr}ms · CPU {cpuStr}% · 漏帧 {_droppedFrames} (卡顿 {hitchStr}ms)";
                }
                else
                {
                    _compactLabel.Text = $"{fpsStr} FPS · {avgMsStr}ms · CPU {cpuStr}% · 漏帧 {_droppedFrames}";
                }

                if (!_isExpanded)
                {
                    return;
                }

                string lowStr = onePercentLowFps > 0 ? onePercentLowFps.ToString("0.0", CultureInfo.InvariantCulture) : "--";
                string maxHitchStr = _maxHitchMs.ToString("0.0", CultureInfo.InvariantCulture);
                string thresholdStr = _droppedFrameThresholdMs.ToString("0", CultureInfo.InvariantCulture);
                string cpuPctDetail = _cpuNormalizedPercent.ToString("0.0", CultureInfo.InvariantCulture);
                string cpuCoresDetail = _cpuCoreUnits.ToString("0.00", CultureInfo.InvariantCulture);
                string rssStr = _rssMegabytes.ToString("0", CultureInfo.InvariantCulture);
                string heapStr = _managedHeapMegabytes.ToString("0", CultureInfo.InvariantCulture);
                Vector2I winSize = DisplayServer.WindowGetSize();

                _fpsDetailLabel.Text = $"帧率：{fpsStr} FPS · 1% Low {lowStr} FPS";
                _frameTimeDetailLabel.Text = $"帧时间：{avgMsStr} ms · 最大卡顿 {maxHitchStr} ms";
                _dropDetailLabel.Text = $"漏帧(>{thresholdStr}ms)：{_droppedFrames} · 重卡(>=100ms)：{_severeHitches}";
                _dropDetailLabel.AddThemeColorOverride(
                    "font_color",
                    recentHitch ? ColorBad : (_droppedFrames > 0 ? ColorWarn : ColorTextPrimary));
                _cpuDetailLabel.Text = $"CPU：{cpuPctDetail}% ({cpuCoresDetail} / {_logicalCoreCount} 核)";
                _memDetailLabel.Text = $"内存：进程 {rssStr} MB · .NET 堆 {heapStr} MB";
                _renderDetailLabel.Text = $"渲染：{_rendererName} · {winSize.X}x{winSize.Y}";
                _fullscreenButton.Text = GetFullscreenButtonText();
            }

            private void ComputeFrameStats(out double avgFrameMs, out double onePercentLowFps)
            {
                int count = _frameHistoryCount;
                if (count <= 0)
                {
                    avgFrameMs = 0;
                    onePercentLowFps = 0;
                    return;
                }

                double sum = 0;
                for (int i = 0; i < count; i++)
                {
                    double value = _frameTimesMs[i];
                    _sortScratchMs[i] = value;
                    sum += value;
                }

                avgFrameMs = sum / count;
                Array.Sort(_sortScratchMs, 0, count);

                int slowCount = Math.Max(1, (int)Math.Ceiling(count * 0.01));
                double slowSum = 0;
                for (int i = count - slowCount; i < count; i++)
                {
                    slowSum += _sortScratchMs[i];
                }
                double slowAvgMs = slowSum / slowCount;
                onePercentLowFps = slowAvgMs > 0.001 ? 1000.0 / slowAvgMs : 0;
            }

            private Color ResolveHealthColor(double fps, bool recentHitch)
            {
                if (recentHitch || (fps > 0 && fps < 35))
                {
                    return ColorBad;
                }
                if (fps > 0 && fps < 55)
                {
                    return ColorWarn;
                }
                return ColorGood;
            }

            private void OnPanelGuiInput(InputEvent @event)
            {
                if (@event is InputEventMouseButton mouseButton && mouseButton.ButtonIndex == MouseButton.Left)
                {
                    if (mouseButton.Pressed)
                    {
                        _isDragging = true;
                        _dragOffset = mouseButton.Position;
                    }
                    else if (_isDragging)
                    {
                        _isDragging = false;
                        ClampPanelToViewport();
                        SavePreferences();
                    }
                }
                else if (@event is InputEventMouseMotion && _isDragging)
                {
                    Vector2 viewportMouse = _panel.GetViewport().GetMousePosition();
                    _panel.Position = viewportMouse - _dragOffset;
                    ClampPanelToViewport();
                }
            }

            private void ClampPanelToViewport()
            {
                Viewport? viewport = _panel.GetViewport();
                if (viewport is null)
                {
                    return;
                }
                Vector2 vpSize = viewport.GetVisibleRect().Size;
                Vector2 panelSize = _panel.Size;
                if (vpSize.X <= 0 || vpSize.Y <= 0)
                {
                    return;
                }

                float maxX = Math.Max(8f, vpSize.X - Math.Max(panelSize.X, 220f) - 8f);
                float maxY = Math.Max(8f, vpSize.Y - Math.Max(panelSize.Y, 32f) - 8f);
                _panel.Position = new Vector2(
                    Math.Clamp(_panel.Position.X, 8f, maxX),
                    Math.Clamp(_panel.Position.Y, 8f, maxY));
            }

            private void SetHudVisible(bool visible)
            {
                _isVisible = visible;
                _layer.Visible = visible;
                if (visible)
                {
                    RefreshLabels(Stopwatch.GetTimestamp());
                }
            }

            private void OnToggleExpandPressed()
            {
                _isExpanded = !_isExpanded;
                _detailsBox.Visible = _isExpanded;
                _expandButton.Text = _isExpanded ? "收起 ▴" : "展开 ▾";
                _panel.ResetSize();
                ClampPanelToViewport();
                SavePreferences();
                RefreshLabels(Stopwatch.GetTimestamp());
            }

            private void OnResetStatsPressed()
            {
                _frameHistoryCount = 0;
                _frameHistoryCursor = 0;
                _droppedFrames = 0;
                _severeHitches = 0;
                _maxHitchMs = 0;
                _lastHitchMs = 0;
                _lastHitchTimestamp = 0;
                RefreshLabels(Stopwatch.GetTimestamp());
            }

            private void OnToggleFullscreenPressed()
            {
                DisplayServer.WindowMode current = DisplayServer.WindowGetMode();
                bool isFull = current == DisplayServer.WindowMode.Fullscreen
                    || current == DisplayServer.WindowMode.ExclusiveFullscreen;
                DisplayServer.WindowSetMode(
                    isFull ? DisplayServer.WindowMode.Windowed : DisplayServer.WindowMode.Fullscreen);
                _fullscreenButton.Text = GetFullscreenButtonText();
                ClampPanelToViewport();
            }

            private void OnHidePressed()
            {
                SetHudVisible(false);
            }

            private void OnQuickQuitPressed()
            {
                long now = Stopwatch.GetTimestamp();
                if (_quitConfirmDeadlineTicks > now)
                {
                    Console.WriteLine("[STS2MacBridge] Quick quit triggered from in-game HUD.");
                    Console.Out.Flush();
                    _tree.Quit(0);
                    return;
                }

                _quitConfirmDeadlineTicks = now + (long)(ConfirmQuitWindowSeconds * Stopwatch.Frequency);
                _quitButton.Text = "确认退出？(3s)";
            }

            private void OnForceQuitPressed()
            {
                long now = Stopwatch.GetTimestamp();
                if (_forceQuitConfirmDeadlineTicks > now)
                {
                    Console.WriteLine("[STS2MacBridge] Force quit triggered from in-game HUD.");
                    Console.Out.Flush();
                    System.Environment.Exit(0);
                    return;
                }

                _forceQuitConfirmDeadlineTicks = now + (long)(ConfirmQuitWindowSeconds * Stopwatch.Frequency);
                _forceQuitButton.Text = "确认强退";
            }

            private void ExpireQuitConfirmationsIfNeeded(long nowTicks)
            {
                if (_quitConfirmDeadlineTicks > 0 && nowTicks >= _quitConfirmDeadlineTicks)
                {
                    _quitConfirmDeadlineTicks = 0;
                    _quitButton.Text = "快速结束游戏";
                }
                if (_forceQuitConfirmDeadlineTicks > 0 && nowTicks >= _forceQuitConfirmDeadlineTicks)
                {
                    _forceQuitConfirmDeadlineTicks = 0;
                    _forceQuitButton.Text = "强退";
                }
            }

            private static string GetFullscreenButtonText()
            {
                DisplayServer.WindowMode mode = DisplayServer.WindowGetMode();
                bool isFull = mode == DisplayServer.WindowMode.Fullscreen
                    || mode == DisplayServer.WindowMode.ExclusiveFullscreen;
                return isFull ? "切窗口" : "切全屏";
            }

            private static string DetectRendererSummary()
            {
                try
                {
                    string driver = ProjectSettings.GetSetting("rendering/rendering_device/driver").AsString();
                    string adapter = RenderingServer.GetVideoAdapterName();
                    if (!string.IsNullOrWhiteSpace(adapter))
                    {
                        return string.IsNullOrWhiteSpace(driver) ? adapter : $"{driver} ({adapter})";
                    }
                    return string.IsNullOrWhiteSpace(driver) ? "Metal/Vulkan" : driver;
                }
                catch
                {
                    return "Metal/Vulkan";
                }
            }

            private TimeSpan SafeGetTotalProcessorTime()
            {
                try
                {
                    _currentProcess.Refresh();
                    return _currentProcess.TotalProcessorTime;
                }
                catch
                {
                    return _lastTotalProcessorTime;
                }
            }

            private static Theme BuildHudTheme()
            {
                var theme = new Theme();
                var font = new SystemFont
                {
                    FontNames = new[] { "PingFang SC", "Hiragino Sans GB", "SF Pro Text", "Helvetica Neue" },
                    Antialiasing = TextServer.FontAntialiasing.Gray,
                    SubpixelPositioning = TextServer.SubpixelPositioning.Auto
                };
                theme.DefaultFont = font;
                theme.DefaultFontSize = 12;
                return theme;
            }

            private static StyleBoxFlat CreatePanelStyleBox()
            {
                var box = new StyleBoxFlat
                {
                    BgColor = ColorBg,
                    BorderColor = ColorBorder,
                    BorderWidthLeft = 1,
                    BorderWidthTop = 1,
                    BorderWidthRight = 1,
                    BorderWidthBottom = 1,
                    CornerRadiusTopLeft = 10,
                    CornerRadiusTopRight = 10,
                    CornerRadiusBottomLeft = 10,
                    CornerRadiusBottomRight = 10,
                    ContentMarginLeft = 10,
                    ContentMarginRight = 10,
                    ContentMarginTop = 6,
                    ContentMarginBottom = 6,
                    ShadowColor = new Color(0f, 0f, 0f, 0.35f),
                    ShadowSize = 6
                };
                return box;
            }

            private static Button CreateCompactButton(string text, bool isDanger)
            {
                var button = new Button
                {
                    Text = text,
                    FocusMode = Control.FocusModeEnum.None,
                    MouseDefaultCursorShape = Control.CursorShape.PointingHand
                };
                button.AddThemeFontSizeOverride("font_size", 11);
                button.AddThemeColorOverride("font_color", ColorTextPrimary);
                button.AddThemeStyleboxOverride("normal", CreateButtonStyleBox(isDanger ? ColorDangerBg : ColorBtnBg));
                button.AddThemeStyleboxOverride("hover", CreateButtonStyleBox(isDanger ? ColorDangerHover : ColorBtnHover));
                button.AddThemeStyleboxOverride("pressed", CreateButtonStyleBox(isDanger ? ColorDangerHover : ColorBtnHover));
                return button;
            }

            private static StyleBoxFlat CreateButtonStyleBox(Color bg)
            {
                return new StyleBoxFlat
                {
                    BgColor = bg,
                    CornerRadiusTopLeft = 6,
                    CornerRadiusTopRight = 6,
                    CornerRadiusBottomLeft = 6,
                    CornerRadiusBottomRight = 6,
                    ContentMarginLeft = 8,
                    ContentMarginRight = 8,
                    ContentMarginTop = 3,
                    ContentMarginBottom = 3
                };
            }

            private static Label CreateMetricLabel(string text)
            {
                var label = new Label
                {
                    Text = text,
                    MouseFilter = Control.MouseFilterEnum.Ignore
                };
                label.AddThemeFontSizeOverride("font_size", 11);
                label.AddThemeColorOverride("font_color", ColorTextPrimary);
                return label;
            }

            private static string ResolvePreferencesPath()
            {
                try
                {
                    string userDir = OS.GetUserDataDir();
                    if (!string.IsNullOrWhiteSpace(userDir))
                    {
                        return Path.Combine(userDir, ConfigFileName);
                    }
                }
                catch
                {
                    // Fall back to Application Support path below.
                }

                string home = System.Environment.GetFolderPath(System.Environment.SpecialFolder.Personal);
                return Path.Combine(home, "Library", "Application Support", "SlayTheSpire2", ConfigFileName);
            }

            private static HudPreferences LoadPreferences()
            {
                try
                {
                    string path = ResolvePreferencesPath();
                    if (!File.Exists(path))
                    {
                        return new HudPreferences();
                    }
                    string json = File.ReadAllText(path);
                    return JsonSerializer.Deserialize<HudPreferences>(json) ?? new HudPreferences();
                }
                catch
                {
                    return new HudPreferences();
                }
            }

            private void SavePreferences()
            {
                try
                {
                    string path = ResolvePreferencesPath();
                    string? dir = Path.GetDirectoryName(path);
                    if (!string.IsNullOrEmpty(dir))
                    {
                        Directory.CreateDirectory(dir);
                    }
                    var prefs = new HudPreferences
                    {
                        X = _panel.Position.X,
                        Y = _panel.Position.Y,
                        Expanded = _isExpanded
                    };
                    File.WriteAllText(path, JsonSerializer.Serialize(prefs));
                }
                catch
                {
                    // Non-critical UI preference persistence; never interrupt gameplay.
                }
            }
        }
    }
}
