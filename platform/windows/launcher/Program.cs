using System.Diagnostics;
using System.Runtime.InteropServices;
using Velopack;
using Velopack.Sources;

namespace PSIHand.Launcher;

internal static class Program
{
    private const string ProductionAppId = "AARPG-Gesture";
    private const string TestAppId = "AARPG-Gesture-UpdateTest";
    private const string GameExecutable = "AARPG-Gesture.exe";
    private const string ProductionRepository = "https://github.com/cjhDuke/AARPG-Gesture";

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            VelopackApp.Build().SetAutoApplyOnStartup(false).Run();

#if STAGE1_SMOKE
            if (args.Length == 2 && args[0] == "--stage1-restarted")
                return RunStage1Restarted(args[1]);
#endif

            var stage1Smoke = false;
#if STAGE1_SMOKE
            stage1Smoke = IsStage1SmokeRequest(args);
#endif
            var appId = stage1Smoke ? TestAppId : ProductionAppId;
            var instanceAppId = Stage2TestBuild ? TestAppId : appId;
            using var instanceLock = new Mutex(true, $"Local\\PSIHand.Launcher.{instanceAppId}", out var ownsLock);
            if (!ownsLock)
                return 0;

#if STAGE1_SMOKE
            if (stage1Smoke)
                return RunStage1Smoke(args);
#endif

            return RunInstalledOrDirect(args);
        }
        catch (Exception ex)
        {
#if STAGE1_SMOKE
            if (IsStage1SmokeRequest(args))
            {
                WriteSmokeErrorIfPossible(args, ex.Message);
                Trace.WriteLine($"PSI HAND update smoke test failed during startup: {ex}");
                return 1;
            }
            if (args.Length == 2 && args[0] == "--stage1-restarted")
            {
                WriteSmokeErrorIfPossible(new[] { "--stage1-update", "", args[1] }, ex.Message);
                Trace.WriteLine($"PSI HAND restart evidence failed during startup: {ex}");
                return 1;
            }
#endif
            ShowDiagnostic("PSI HAND could not start", ex.Message);
            return 1;
        }
    }

    private static int RunInstalledOrDirect(string[] args)
    {
        UpdateManager? installedManager = null;
        try { installedManager = new UpdateManager(); }
        catch { /* A direct, unpackaged launcher retains the normal game path. */ }

        if (installedManager is null || !installedManager.IsInstalled)
            return RunGame(args);

        var installedId = installedManager.AppId;
        var expectedId = ExpectedAppId;
        if (!string.Equals(installedId, expectedId, StringComparison.Ordinal))
            return RunGame(args);

        IUpdateSource source;
        string[] gameArgs;
        if (Stage2TestBuild)
        {
            var testFeed = ExtractStage2Feed(args, out gameArgs);
            if (testFeed is null)
                return RunGame(args);
            source = new SimpleWebSource(testFeed);
        }
        else
        {
            gameArgs = args;
            source = CreateProductionUpdateSource();
        }

        var sessionDirectory = Path.Combine(Path.GetTempPath(), "AARPG-Gesture", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(sessionDirectory);
        return UpdateSession.Run(new UpdateManager(source), gameArgs, args, sessionDirectory, GamePath);
    }

    private static string GamePath => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, GameExecutable));

    private static string ExpectedAppId
    {
        get
        {
#if STAGE2_TEST
            return TestAppId;
#else
            return ProductionAppId;
#endif
        }
    }

    private static bool Stage2TestBuild
    {
        get
        {
#if STAGE2_TEST
            return true;
#else
            return false;
#endif
        }
    }

    private static string? ExtractStage2Feed(string[] args, out string[] gameArgs)
    {
#if STAGE2_TEST
        var feedIndex = Array.FindIndex(args, argument => argument == "--stage2-feed");
        if (feedIndex < 0)
        {
            gameArgs = args;
            return null;
        }

        if (feedIndex + 1 >= args.Length || args.Count(argument => argument == "--stage2-feed") != 1
            || !UpdateSession.IsAllowedTestFeed(args[feedIndex + 1]))
        {
            gameArgs = args;
            return null;
        }

        var remaining = new List<string>(args);
        remaining.RemoveRange(feedIndex, 2);
        gameArgs = remaining.ToArray();
        return args[feedIndex + 1];
#else
        gameArgs = args;
        return null;
#endif
    }

    private static int RunGame(string[] args)
    {
        if (!File.Exists(GamePath))
        {
            ShowDiagnostic("PSI HAND could not start", $"The game executable was not found beside the launcher:\n{GamePath}");
            return 2;
        }

        try
        {
            using var game = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = GamePath,
                    WorkingDirectory = AppContext.BaseDirectory,
                    UseShellExecute = false
                }
            };
            foreach (var argument in args)
                game.StartInfo.ArgumentList.Add(argument);
            if (!game.Start())
            {
                ShowDiagnostic("PSI HAND could not start", "Windows did not start the game process.");
                return 3;
            }
            game.WaitForExit();
            return game.ExitCode;
        }
        catch (Exception ex)
        {
            ShowDiagnostic("PSI HAND could not start", $"Unable to launch the game at:\n{GamePath}\n\n{ex.Message}");
            return 3;
        }
    }

#if STAGE1_SMOKE
    private static bool IsStage1SmokeRequest(string[] args)
    {
        return args.Length > 0 && args[0] == "--stage1-update";
    }

    private static int RunStage1Smoke(string[] args)
    {
        var evidencePath = GetEvidencePath(args);
        try
        {
            if (args.Length != 3)
                throw new ArgumentException("Usage: PSIHand.exe --stage1-update <http://127.0.0.1:PORT/> <absoluteEvidenceDir>");
            if (evidencePath is null)
                throw new ArgumentException("The evidence directory must be an absolute path.");
            Directory.CreateDirectory(evidencePath);
            if (!UpdateSession.IsAllowedTestFeed(args[1]))
                throw new ArgumentException("The test feed must use plain HTTP, the literal host 127.0.0.1, and an explicit port.");

            var manager = new UpdateManager(new SimpleWebSource(args[1]));
            EnsureInstalledApp(manager, TestAppId);
            var update = manager.CheckForUpdatesAsync().GetAwaiter().GetResult()
                ?? throw new InvalidOperationException("The test feed has no newer update to install.");
            manager.DownloadUpdatesAsync(update).GetAwaiter().GetResult();
            WriteJson(evidencePath, "staged.json", new { version = update.TargetFullRelease.Version.ToString() });
            manager.ApplyUpdatesAndRestart(update, new[] { "--stage1-restarted", evidencePath });
            return 0;
        }
        catch (Exception ex)
        {
            WriteSmokeErrorIfPossible(args, ex.Message);
            Trace.WriteLine($"PSI HAND update smoke test failed: {ex}");
            return 10;
        }
    }

    private static void WriteSmokeErrorIfPossible(string[] args, string message)
    {
        var evidencePath = GetEvidencePath(args);
        if (evidencePath is null) return;
        try
        {
            Directory.CreateDirectory(evidencePath);
            WriteJson(evidencePath, "error.json", new { error = message });
        }
        catch { }
    }

    private static string? GetEvidencePath(string[] args)
    {
        if (args.Length < 3 || !Path.IsPathFullyQualified(args[2])) return null;
        try { return Path.GetFullPath(args[2]); }
        catch { return null; }
    }

    private static void EnsureInstalledApp(UpdateManager manager, string expectedAppId)
    {
        if (!manager.IsInstalled || !string.Equals(manager.AppId, expectedAppId, StringComparison.Ordinal))
            throw new InvalidOperationException($"This test command requires an installed Velopack app with ID '{expectedAppId}'. Detected ID: '{manager.AppId ?? "<none>"}'.");
    }

    private static int RunStage1Restarted(string evidenceDir)
    {
        try
        {
            if (!Path.IsPathFullyQualified(evidenceDir)) throw new ArgumentException("The restart evidence directory is not absolute.");
            var path = Path.GetFullPath(evidenceDir);
            Directory.CreateDirectory(path);
            var manager = new UpdateManager();
            EnsureInstalledApp(manager, TestAppId);
            WriteJson(path, "restart.json", new { version = manager.CurrentVersion?.ToString() });
            return 0;
        }
        catch (Exception ex)
        {
            WriteSmokeErrorIfPossible(new[] { "--stage1-update", "", evidenceDir }, ex.Message);
            Trace.WriteLine($"PSI HAND restart evidence failed: {ex}");
            return 11;
        }
    }

    private static void WriteJson(string directory, string name, object value) =>
        File.WriteAllText(Path.Combine(directory, name), System.Text.Json.JsonSerializer.Serialize(value), new System.Text.UTF8Encoding(false));
#endif

    internal static void ShowDiagnostic(string title, string message)
    {
        try
        {
            if (OperatingSystem.IsWindows()) _ = MessageBoxW(IntPtr.Zero, message, title, 0x10);
            else Console.Error.WriteLine($"{title}: {message}");
        }
        catch { Console.Error.WriteLine($"{title}: {message}"); }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxW", ExactSpelling = true)]
    private static extern int MessageBoxW(IntPtr window, string text, string caption, uint type);

    internal static IUpdateSource CreateProductionUpdateSource() => new GithubSource(ProductionRepository, null, false);
}
