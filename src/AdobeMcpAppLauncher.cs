using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
#if WATCH
using System.Management;
#endif

internal static class AdobeMcpAppLauncher
{
#if LIGHTROOM
    private const string Bridge = "Lightroom";
    private const string Script = "lightroom-hosted.mjs";
    private static readonly string[] Hosts = { "Lightroom" };
#else
    private const string Bridge = "Premiere";
    private const string Script = "premiere-shared.mjs";
    private static readonly string[] Hosts = { "Adobe Premiere Pro", "AfterFX" };
#endif

    private static int Main()
    {
        int session = Process.GetCurrentProcess().SessionId;
        string directory = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
        string errorPath = Path.Combine(directory, Bridge + "-app-error.log");

        try
        {
            using (var mutex = new Mutex(false, @"Local\AdobeMcpApp-" + Bridge))
            {
                try
                {
                    if (!mutex.WaitOne(3000)) return 0;
                }
                catch (AbandonedMutexException)
                {
                    // A previous launcher exited while holding the mutex.
                }

                try
                {
#if WATCH
                    return WatchHosts(session, directory, errorPath);
#else
                    if (!HostIsOpen(session)) return 0;
                    return RunBridge(session, directory, errorPath);
#endif
                }
                finally
                {
                    mutex.ReleaseMutex();
                }
            }
        }
        catch (Exception error)
        {
            File.AppendAllText(errorPath, DateTimeOffset.Now.ToString("o") + " " + error + Environment.NewLine);
            return 1;
        }
    }

#if WATCH
    private static int WatchHosts(int session, string directory, string errorPath)
    {
        using (var changed = new AutoResetEvent(false))
        using (var starts = SubscribeToAdobeStarts(session, changed, errorPath))
        {
            while (true)
            {
                if (HostIsOpen(session))
                {
                    try
                    {
                        int result = RunBridge(session, directory, errorPath);
                        if (result != 0) Thread.Sleep(5000);
                    }
                    catch (Exception error)
                    {
                        File.AppendAllText(errorPath, DateTimeOffset.Now.ToString("o") + " " + error + Environment.NewLine);
                        Thread.Sleep(5000);
                    }
                }
                // Recheck during Adobe startup while AfterFX has yet to create its window.
                changed.WaitOne(3000);
            }
        }
    }

    private static ManagementEventWatcher SubscribeToAdobeStarts(int session, AutoResetEvent changed, string errorPath)
    {
        string[] queries = {
            "SELECT * FROM Win32_ProcessStartTrace WHERE SessionID = " + session +
                " AND (ProcessName = 'Adobe Premiere Pro.exe' OR ProcessName = 'AfterFX.exe')",
            "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process'" +
                " AND TargetInstance.SessionId = " + session +
                " AND (TargetInstance.Name = 'Adobe Premiere Pro.exe' OR TargetInstance.Name = 'AfterFX.exe')"
        };
        foreach (string query in queries)
        {
            var watcher = new ManagementEventWatcher(@"root\CIMV2", query);
            watcher.EventArrived += delegate { changed.Set(); };
            try
            {
                watcher.Start();
                return watcher;
            }
            catch (ManagementException)
            {
                watcher.Dispose();
            }
            catch (UnauthorizedAccessException)
            {
                watcher.Dispose();
            }
        }
        File.AppendAllText(errorPath, "WMI process events unavailable; using periodic checks." + Environment.NewLine);
        return null;
    }
#endif

    private static int RunBridge(int session, string directory, string errorPath)
    {
        string runtime = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(runtime, Script);
        string node = File.ReadAllText(Path.Combine(runtime, "node-path.txt")).Trim();
        var startInfo = new ProcessStartInfo
        {
            FileName = node,
            Arguments = "\"" + script + "\" --with-app",
            WorkingDirectory = runtime,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true
        };

        using (var output = new FileStream(Path.Combine(directory, Bridge + "-app-output.log"), FileMode.Append, FileAccess.Write, FileShare.Read))
        using (var errors = new FileStream(errorPath, FileMode.Append, FileAccess.Write, FileShare.Read))
        using (var process = Process.Start(startInfo))
        {
            Task copyOutput = process.StandardOutput.BaseStream.CopyToAsync(output);
            Task copyErrors = process.StandardError.BaseStream.CopyToAsync(errors);
            while (!process.WaitForExit(1000))
            {
                if (HostIsOpen(session)) continue;
                process.StandardInput.Close();
                if (!process.WaitForExit(2000)) process.Kill();
                process.WaitForExit();
                Task.WaitAll(copyOutput, copyErrors);
                return 0;
            }
            Task.WaitAll(copyOutput, copyErrors);
            return process.ExitCode;
        }
    }

    private static bool HostIsOpen(int session)
    {
        foreach (string name in Hosts)
        {
            var processes = Process.GetProcessesByName(name);
            try
            {
                foreach (Process process in processes)
                {
                    try
                    {
                        if (process.SessionId != session || process.HasExited) continue;
                        // Dynamic Link's aerendercore and manager have different names.
                        // A windowless AfterFX instance is also excluded.
                        if (name == "AfterFX" && process.MainWindowHandle == IntPtr.Zero) continue;
                        return true;
                    }
                    catch (InvalidOperationException)
                    {
                        // The application exited during enumeration.
                    }
                    catch (System.ComponentModel.Win32Exception)
                    {
                        // The process became inaccessible while enumerating its window.
                    }
                }
            }
            finally
            {
                foreach (Process process in processes) process.Dispose();
            }
        }
        return false;
    }
}
