using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Velopack;

namespace PSIHand.Launcher;

internal sealed class UpdateSession
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
    private readonly UpdateManager _manager;
    private readonly string _directory;
    private readonly string _gamePath;
    private readonly string[] _restartArgs;
    private readonly string[] _fallbackArgs;
    private readonly string _currentVersion;
    private readonly HashSet<string> _requestIds = new(StringComparer.Ordinal);
    private UpdateInfo? _update;
    private string _state = "checking";
    private string _targetVersion = "";
    private string _notes = "";
    private int _progress;
    private int _callbackProgress;
    private string _errorCode = "";
    private Task<UpdateInfo?>? _checkTask;
    private DateTime _checkStartedAt;
    private bool _checkConsumed;
    private Task? _downloadTask;
    private CancellationTokenSource? _downloadCancellation;
    private string? _pendingApplyId;

    private UpdateSession(UpdateManager manager, string[] restartArgs, string[] fallbackArgs, string directory, string gamePath)
    {
        _manager = manager;
        _directory = directory;
        _gamePath = gamePath;
        _restartArgs = restartArgs;
        _fallbackArgs = fallbackArgs;
        _currentVersion = manager.CurrentVersion?.ToString() ?? "";
    }

    internal static int Run(UpdateManager manager, string[] gameArgs, string[] restartArgs, string directory, string gamePath)
    {
        var session = new UpdateSession(manager, restartArgs, gameArgs, directory, gamePath);
        return session.RunAsync(gameArgs).GetAwaiter().GetResult();
    }

    private async Task<int> RunAsync(string[] gameArgs)
    {
        var statusPath = Path.Combine(_directory, "status.json");
        var requestPath = Path.Combine(_directory, "request.json");
        Process? game = null;
        try
        {
            PublishStatus(statusPath);
            _checkStartedAt = DateTime.UtcNow;
            _checkTask = _manager.CheckForUpdatesAsync();
            game = StartGame(gameArgs, _directory);
            if (game is null) return 3;

            while (!game.HasExited)
            {
                UpdateCheckState(statusPath);
                UpdateDownloadState(statusPath);
                if (File.Exists(requestPath)) ProcessRequest(requestPath, statusPath);
                await Task.Delay(75);
            }

            var exitCode = game.ExitCode;
            if (exitCode == 0 && File.Exists(requestPath))
                ProcessRequest(requestPath, statusPath);

            if (exitCode == 0 && _pendingApplyId is not null && _state == "ready" && _update is not null)
            {
                try
                {
                    // The SDK can exit this process during a successful handoff.
                    TryDeleteSession(_directory);
                    _manager.ApplyUpdatesAndRestart(_update, _restartArgs);
                    return 0;
                }
                catch (Exception ex)
                {
                    Trace.WriteLine($"Velopack update apply failed: {ex}");
                    return RelaunchPreviousGame();
                }
            }

            return exitCode;
        }
        finally
        {
            _downloadCancellation?.Cancel();
            if (_downloadTask is not null)
            {
                try { await _downloadTask.WaitAsync(TimeSpan.FromSeconds(5)); }
                catch (TimeoutException) { Trace.WriteLine("Timed out waiting for the cancelled download to stop."); }
                catch (OperationCanceledException) { }
                catch (Exception ex) { Trace.WriteLine($"Update download ended during launcher shutdown: {ex}"); }
            }
            _downloadCancellation?.Dispose();
            game?.Dispose();
            TryDeleteSession(_directory);
        }
    }

    private void UpdateCheckState(string statusPath)
    {
        if (_checkConsumed || _checkTask is null) return;
        if (DateTime.UtcNow - _checkStartedAt >= TimeSpan.FromSeconds(8) && !_checkTask.IsCompleted)
        {
            _checkConsumed = true;
            _state = "error";
            _errorCode = "check_timeout";
            ClearTarget();
            PublishStatus(statusPath);
            return;
        }
        if (_checkTask.IsCompleted)
        {
            _checkConsumed = true;
            try
            {
                _update = _checkTask.GetAwaiter().GetResult();
                if (_update is null)
                {
                    _state = "current";
                    _errorCode = "";
                    ClearTarget();
                }
                else
                {
                    _state = "available";
                    _errorCode = "";
                    _targetVersion = _update.TargetFullRelease.Version.ToString();
                    _notes = _update.TargetFullRelease.NotesMarkdown ?? "";
                    _progress = 0;
                }
            }
            catch
            {
                _state = "error";
                _errorCode = "check_failed";
                ClearTarget();
            }
            PublishStatus(statusPath);
        }
    }

    private void UpdateDownloadState(string statusPath)
    {
        if (_downloadTask is null) return;
        var latestProgress = Math.Clamp(Volatile.Read(ref _callbackProgress), 0, 100);
        if (_progress != latestProgress)
        {
            _progress = latestProgress;
            PublishStatus(statusPath);
        }
        if (!_downloadTask.IsCompleted) return;

        try
        {
            _downloadTask.GetAwaiter().GetResult();
            _state = "ready";
            _progress = 100;
        }
        catch (OperationCanceledException)
        {
            _state = "available";
            _progress = 0;
        }
        catch
        {
            _state = "error";
            _errorCode = "download_failed";
            // Keep the same target and UpdateInfo so the player can retry it.
        }
        finally
        {
            _downloadTask = null;
            _downloadCancellation?.Dispose();
            _downloadCancellation = null;
            PublishStatus(statusPath);
        }
    }

    private void ProcessRequest(string requestPath, string statusPath)
    {
        Request? request;
        try
        {
            var json = File.ReadAllText(requestPath);
            using var document = JsonDocument.Parse(json);
            RequireExactProperties(document.RootElement, "schema", "id", "action", "target_version");
            request = JsonSerializer.Deserialize<Request>(json, JsonOptions);
            if (request is null || request.Schema != 1 || string.IsNullOrWhiteSpace(request.Id)
                || request.Id.Length > 128 || request.Id.Any(char.IsControl)) return;
        }
        catch { return; }

        if (!_requestIds.Add(request.Id)) return;
        if (_state == "checking")
        {
            _requestIds.Remove(request.Id);
            return;
        }
        if (!string.Equals(request.TargetVersion, _targetVersion, StringComparison.Ordinal)) return;

        switch (request.Action)
        {
            case "download" when (_state == "available" || (_state == "error" && _errorCode == "download_failed")) && _update is not null:
                StartDownload(statusPath);
                break;
            case "cancel" when _downloadTask is not null:
                _downloadCancellation?.Cancel();
                break;
            case "apply" when _state == "ready" && _update is not null:
                _pendingApplyId = request.Id;
                break;
        }
    }

    private void StartDownload(string statusPath)
    {
        if (_downloadTask is not null || _update is null) return;
        _downloadCancellation = new CancellationTokenSource();
        var cancellationToken = _downloadCancellation.Token;
        _callbackProgress = 0;
        _progress = 0;
        _state = "downloading";
        _errorCode = "";
        PublishStatus(statusPath);
        Action<int> progress = value => Volatile.Write(ref _callbackProgress, Math.Clamp(value, 0, 100));
        var update = _update;
        try
        {
            _downloadTask = _manager.DownloadUpdatesAsync(update, progress, cancellationToken);
        }
        catch
        {
            _state = "error";
            _errorCode = "download_failed";
            _downloadCancellation.Dispose();
            _downloadCancellation = null;
            PublishStatus(statusPath);
        }
    }

    private Process? StartGame(string[] args, string sessionDirectory)
    {
        if (!File.Exists(_gamePath))
            throw new FileNotFoundException("The game executable was not found beside the launcher.", _gamePath);
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = _gamePath,
                WorkingDirectory = AppContext.BaseDirectory,
                UseShellExecute = false
            }
        };
        foreach (var argument in args) process.StartInfo.ArgumentList.Add(argument);
        process.StartInfo.Environment["AARPG_UPDATE_SESSION"] = sessionDirectory;
        if (!process.Start())
        {
            process.Dispose();
            return null;
        }
        return process;
    }

    private int RelaunchPreviousGame()
    {
        try
        {
            using var previous = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = _gamePath,
                    WorkingDirectory = AppContext.BaseDirectory,
                    UseShellExecute = false
                }
            };
            foreach (var argument in _fallbackArgs) previous.StartInfo.ArgumentList.Add(argument);
            if (!previous.Start()) throw new InvalidOperationException("The game did not start.");
            Program.ShowDiagnostic("PSI HAND update failed", "The update could not be installed. The previous version has been reopened.");
            previous.WaitForExit();
            return previous.ExitCode;
        }
        catch (Exception ex)
        {
            Trace.WriteLine($"Unable to restart the previous game after update failure: {ex}");
            Program.ShowDiagnostic("PSI HAND update failed", "The previous version could not be reopened. Start the game again from its shortcut.");
            return 3;
        }
    }

    private void ClearTarget()
    {
        _update = null;
        _targetVersion = "";
        _notes = "";
        _progress = 0;
    }

    private void PublishStatus(string path)
    {
        var json = JsonSerializer.Serialize(new Status
        {
            Schema = 1,
            State = _state,
            CurrentVersion = _currentVersion,
            TargetVersion = _targetVersion,
            Notes = _notes,
            Progress = _progress,
            ErrorCode = _errorCode
        }, JsonOptions);
        AtomicWrite(path, json);
    }

    private static void AtomicWrite(string path, string contents)
    {
        var temporaryPath = path + ".tmp";
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                File.WriteAllText(temporaryPath, contents, new System.Text.UTF8Encoding(false));
                File.Move(temporaryPath, path, true);
                return;
            }
            catch (IOException) when (attempt < 4)
            {
                Thread.Sleep(20 * (attempt + 1));
            }
            catch (UnauthorizedAccessException) when (attempt < 4)
            {
                Thread.Sleep(20 * (attempt + 1));
            }
            catch (Exception ex)
            {
                Trace.WriteLine($"Unable to publish update status: {ex.Message}");
                return;
            }
        }
    }

    private static void TryDeleteSession(string directory)
    {
        try { Directory.Delete(directory, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void RequireExactProperties(JsonElement value, params string[] expected)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new JsonException("Expected an object.");
        var properties = value.EnumerateObject().Select(property => property.Name).ToArray();
        if (properties.Length != expected.Length || expected.Any(name => !properties.Contains(name, StringComparer.Ordinal)))
            throw new JsonException("Request fields do not match schema 1.");
    }

    internal static bool IsAllowedTestFeed(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttp || uri.Host != "127.0.0.1" || uri.Port < 1
            || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0) return false;
        var authorityStart = value.IndexOf("//", StringComparison.Ordinal) + 2;
        if (authorityStart < 2) return false;
        var authorityEnd = value.IndexOfAny(new[] { '/', '?', '#' }, authorityStart);
        if (authorityEnd < 0) authorityEnd = value.Length;
        const string prefix = "127.0.0.1:";
        var authority = value[authorityStart..authorityEnd];
        if (!authority.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var portText = authority.AsSpan(prefix.Length);
        return !portText.IsEmpty && portText.IndexOfAnyExceptInRange('0', '9') < 0
            && int.TryParse(portText, out var port) && port == uri.Port;
    }

    private sealed class Status
    {
        public int Schema { get; init; }
        public string State { get; init; } = "";
        public string CurrentVersion { get; init; } = "";
        public string TargetVersion { get; init; } = "";
        public string Notes { get; init; } = "";
        public int Progress { get; init; }
        public string ErrorCode { get; init; } = "";
    }

    private sealed class Request
    {
        public int Schema { get; init; }
        public string Id { get; init; } = "";
        public string Action { get; init; } = "";
        public string TargetVersion { get; init; } = "";
    }
}
