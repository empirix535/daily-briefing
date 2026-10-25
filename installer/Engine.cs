// Otis setup: install and uninstall engine (no UI). Written for C# 5 so the .NET Framework 4.x compiler builds it.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace OtisSetup
{
    // Everything the wizard collects
    class Opts
    {
        public string InstallDir;
        public string DataMode = "fresh";      // fresh | keep | import | restore
        public string DataSource = "";         // folder for import / restore
        public string UserName = "", Description = "", Email = "", Domain = "";
        public string StreamsPath = "";        // blank = data\streams.json
        public string BackupPath = "";         // blank = no backup
        public string ClaudePath = "";
        public bool StartWithWindows = true;
        public bool DesktopShortcut = true;
        public bool Upgrade;                   // an existing install was found
    }

    static class Engine
    {
        public const string ProductName = "Otis";
        public const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Otis";

        // ------------------------------------------------------------------ resources
        public static Stream Res(string name)
        {
            Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
            if (s == null) throw new InvalidOperationException("This setup file is damaged (missing " + name + ").");
            return s;
        }

        public static string ResText(string name)
        {
            using (StreamReader r = new StreamReader(Res(name), Encoding.UTF8)) return r.ReadToEnd();
        }

        public static string Version
        {
            get { try { return ResText("version.txt").Trim(); } catch { return "1.0.0"; } }
        }

        // ------------------------------------------------------------------ discovery
        public static string DefaultInstallDir()
        {
            return Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"), ProductName);
        }

        public static string ExistingInstallDir()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(UninstallKey))
                {
                    string d = k == null ? null : k.GetValue("InstallLocation") as string;
                    if (!string.IsNullOrEmpty(d) && Directory.Exists(d)) return d;
                }
            }
            catch { }
            return null;
        }

        public static string OneDriveRoot()
        {
            string[] vars = { "OneDriveCommercial", "OneDrive" };
            foreach (string v in vars)
            {
                string p = Environment.GetEnvironmentVariable(v);
                if (!string.IsNullOrEmpty(p) && Directory.Exists(p)) return p;
            }
            return null;
        }

        public static bool IsInside(string path, string root)
        {
            if (string.IsNullOrEmpty(root) || string.IsNullOrEmpty(path)) return false;
            string a = Path.GetFullPath(path).TrimEnd('\\', '/') + "\\";
            string b = Path.GetFullPath(root).TrimEnd('\\', '/') + "\\";
            return a.StartsWith(b, StringComparison.OrdinalIgnoreCase);
        }

        public static string FindBrowser()
        {
            string[] exes = { "chrome.exe", "msedge.exe" };
            RegistryKey[] hives = { Registry.CurrentUser, Registry.LocalMachine };
            foreach (string exe in exes)
                foreach (RegistryKey hive in hives)
                {
                    try
                    {
                        using (RegistryKey k = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" + exe))
                        {
                            string p = k == null ? null : k.GetValue("") as string;
                            if (!string.IsNullOrEmpty(p) && File.Exists(p.Trim('"'))) return p.Trim('"');
                        }
                    }
                    catch { }
                }
            return null;
        }

        public static string FindClaude()
        {
            string[] names = { "claude.exe", "claude.cmd" };
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string dir in path.Split(Path.PathSeparator))
            {
                if (string.IsNullOrEmpty(dir)) continue;
                foreach (string n in names)
                {
                    try { string f = Path.Combine(dir.Trim('"'), n); if (File.Exists(f)) return f; } catch { }
                }
            }
            string native = Path.Combine(ClaudeBinDir(), "claude.exe");
            return File.Exists(native) ? native : null;
        }

        public static string ClaudeBinDir()
        {
            return Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local"), "bin");
        }

        // ------------------------------------------------------------------ small file helpers
        public static void Retry(Action a)
        {
            Exception last = null;
            for (int i = 0; i < 6; i++)
            {
                try { a(); return; }
                catch (Exception ex) { last = ex; System.Threading.Thread.Sleep(500); }
            }
            throw last;
        }

        public static void CopyDir(string src, string dst, bool skipLogs)
        {
            Directory.CreateDirectory(dst);
            foreach (string f in Directory.GetFiles(src))
            {
                if (skipLogs && f.EndsWith(".log", StringComparison.OrdinalIgnoreCase)) continue;
                string target = Path.Combine(dst, Path.GetFileName(f));
                Retry(delegate { File.Copy(f, target, true); });
            }
            foreach (string d in Directory.GetDirectories(src))
                CopyDir(d, Path.Combine(dst, Path.GetFileName(d)), skipLogs);
        }

        public static void DeleteDir(string dir)
        {
            if (!Directory.Exists(dir)) return;
            Retry(delegate { Directory.Delete(dir, true); });
        }

        // ------------------------------------------------------------------ processes
        // Closes any running Otis server, wherever it was started from
        public static void StopOtis()
        {
            string cmd = "Get-CimInstance Win32_Process -Filter \\\"Name='powershell.exe'\\\" | Where-Object { $_.CommandLine -match 'server\\.ps1' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }";
            RunHidden("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -Command \"" + cmd + "\"", 30000);
            System.Threading.Thread.Sleep(800);
        }

        public static int RunHidden(string exe, string args, int timeoutMs)
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            using (Process p = Process.Start(psi))
            {
                if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } return -1; }
                return p.ExitCode;
            }
        }

        // ------------------------------------------------------------------ shortcuts
        public static void MakeShortcut(string lnkPath, string target, string args, string workDir, string icon, string description)
        {
            Type t = Type.GetTypeFromProgID("WScript.Shell");
            object sh = Activator.CreateInstance(t);
            object lnk = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnkPath });
            Type lt = lnk.GetType();
            lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
            lt.InvokeMember("Arguments", BindingFlags.SetProperty, null, lnk, new object[] { args ?? "" });
            lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { workDir });
            lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { icon });
            lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { description });
            lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
        }

        public static string Shortcut(Environment.SpecialFolder folder, string name)
        {
            return Path.Combine(Environment.GetFolderPath(folder), name + ".lnk");
        }

        // ------------------------------------------------------------------ settings.json
        public static Dictionary<string, object> ReadSettings(string path)
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            return js.Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
        }

        public static void WriteSettings(string path, Dictionary<string, object> s)
        {
            StringBuilder sb = new StringBuilder();
            Pretty(sb, s, 0);
            File.WriteAllText(path, sb.ToString() + "\r\n", new UTF8Encoding(false));
        }

        static void Pretty(StringBuilder sb, object v, int depth)
        {
            string pad = new string(' ', (depth + 1) * 4), padEnd = new string(' ', depth * 4);
            IDictionary d = v as IDictionary;
            if (d != null)
            {
                if (d.Count == 0) { sb.Append("{}"); return; }
                sb.Append("{\r\n");
                int i = 0;
                foreach (DictionaryEntry e in d)
                {
                    sb.Append(pad).Append(Quote(Convert.ToString(e.Key))).Append(": ");
                    Pretty(sb, e.Value, depth + 1);
                    sb.Append(++i < d.Count ? ",\r\n" : "\r\n");
                }
                sb.Append(padEnd).Append("}");
                return;
            }
            if (v is string) { sb.Append(Quote((string)v)); return; }
            IEnumerable en = v as IEnumerable;
            if (en != null)
            {
                List<object> items = new List<object>();
                foreach (object o in en) items.Add(o);
                if (items.Count == 0) { sb.Append("[]"); return; }
                sb.Append("[\r\n");
                for (int i = 0; i < items.Count; i++)
                {
                    sb.Append(pad);
                    Pretty(sb, items[i], depth + 1);
                    sb.Append(i < items.Count - 1 ? ",\r\n" : "\r\n");
                }
                sb.Append(padEnd).Append("]");
                return;
            }
            if (v == null) { sb.Append("null"); return; }
            if (v is bool) { sb.Append((bool)v ? "true" : "false"); return; }
            sb.Append(Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture));
        }

        static string Quote(string s)
        {
            StringBuilder sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 32 || c > 126) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append("\"").ToString();
        }

        public static string StringOf(Dictionary<string, object> s, string key)
        {
            object v;
            return s != null && s.TryGetValue(key, out v) && v != null ? Convert.ToString(v) : "";
        }

        public static string FirstDomain(Dictionary<string, object> s)
        {
            object v;
            if (s != null && s.TryGetValue("InternalDomains", out v))
            {
                IEnumerable en = v as IEnumerable;
                if (en != null && !(v is string)) foreach (object o in en) return Convert.ToString(o);
            }
            return "";
        }

        // Old versions kept the streams file at <OneDrive>\root\_admin\streams.json with no setting for it
        public static string LegacyStreamsPath()
        {
            string od = OneDriveRoot();
            if (od == null) return null;
            string p = Path.Combine(Path.Combine(Path.Combine(od, "root"), "_admin"), "streams.json");
            return File.Exists(p) ? p : null;
        }

        // ------------------------------------------------------------------ install
        public delegate void Progress(int percent, string message);

        public static void Install(Opts o, Progress report)
        {
            string dir = o.InstallDir;
            string app = Path.Combine(dir, "app");
            string data = Path.Combine(dir, "data");
            string settingsPath = Path.Combine(dir, "settings.json");
            string exe = Path.Combine(dir, "Otis.exe");

            report(3, "Closing Otis if it is running");
            StopOtis();

            report(10, "Copying program files");
            Directory.CreateDirectory(dir);
            DeleteDir(app);
            using (ZipArchive zip = new ZipArchive(Res("payload.zip"), ZipArchiveMode.Read))
            {
                string root = Path.GetFullPath(dir).TrimEnd('\\') + "\\";
                foreach (ZipArchiveEntry e in zip.Entries)
                {
                    if (string.IsNullOrEmpty(e.Name)) continue;
                    string target = Path.GetFullPath(Path.Combine(dir, e.FullName.Replace('/', '\\')));
                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    ZipArchiveEntry entry = e;
                    Retry(delegate { entry.ExtractToFile(target, true); });
                }
            }
            Retry(delegate
            {
                using (Stream r = Res("Otis.exe"))
                using (FileStream w = new FileStream(exe, FileMode.Create, FileAccess.Write)) r.CopyTo(w);
            });
            string self = Assembly.GetExecutingAssembly().Location;
            string unins = Path.Combine(dir, "Uninstall.exe");
            if (!string.Equals(Path.GetFullPath(self), Path.GetFullPath(unins), StringComparison.OrdinalIgnoreCase))
                Retry(delegate { File.Copy(self, unins, true); });

            report(35, "Setting up your data");
            Directory.CreateDirectory(data);
            if (o.DataMode == "import" && Directory.Exists(o.DataSource))
            {
                string srcData = Path.Combine(o.DataSource, "data");
                if (Directory.Exists(srcData)) CopyDir(srcData, data, true);
                string srcSettings = Path.Combine(o.DataSource, "settings.json");
                if (File.Exists(srcSettings)) Retry(delegate { File.Copy(srcSettings, settingsPath, true); });
            }
            else if (o.DataMode == "restore" && Directory.Exists(o.DataSource))
            {
                string latest = Path.Combine(o.DataSource, "latest");
                string src = Directory.Exists(latest) ? latest : o.DataSource;
                CopyDir(src, dir, true);
            }

            report(55, "Saving your settings");
            Dictionary<string, object> s;
            if (File.Exists(settingsPath)) s = ReadSettings(settingsPath);
            else s = ReadSettingsText(ResText("settings.example.json"));
            if (o.UserName.Length > 0) { s["UserName"] = o.UserName; s["SignName"] = o.UserName; }
            if (o.Description.Length > 0) s["UserDescription"] = o.Description;
            if (o.Email.Length > 0) s["UserEmail"] = o.Email;
            if (o.Domain.Length > 0) s["InternalDomains"] = new ArrayList(new object[] { o.Domain.TrimStart('@') });
            string defaultStreams = Path.Combine(data, "streams.json");
            if (o.StreamsPath.Length > 0 && !string.Equals(o.StreamsPath, defaultStreams, StringComparison.OrdinalIgnoreCase))
            {
                s["StreamsPath"] = o.StreamsPath;
                string sd = Path.GetDirectoryName(o.StreamsPath);
                if (!string.IsNullOrEmpty(sd)) try { Directory.CreateDirectory(sd); } catch { }
            }
            else s.Remove("StreamsPath");
            if (o.BackupPath.Length > 0) { s["BackupPath"] = o.BackupPath; try { Directory.CreateDirectory(o.BackupPath); } catch { } }
            else s.Remove("BackupPath");
            if (o.ClaudePath.Length > 0) s["ClaudePath"] = o.ClaudePath;
            WriteSettings(settingsPath, s);

            report(65, "Creating shortcuts");
            string icon = Path.Combine(Path.Combine(app, "icons"), "agenda.ico") + ",0";
            foreach (string legacy in new string[] { "Daily Briefing" })
                foreach (Environment.SpecialFolder f in new Environment.SpecialFolder[] { Environment.SpecialFolder.Programs, Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.Startup })
                    try { string l = Shortcut(f, legacy); if (File.Exists(l)) File.Delete(l); } catch { }
            List<string> made = new List<string>();
            string start = Shortcut(Environment.SpecialFolder.Programs, ProductName);
            MakeShortcut(start, exe, "", dir, icon, "Otis"); made.Add(start);
            string desk = Shortcut(Environment.SpecialFolder.DesktopDirectory, ProductName);
            if (o.DesktopShortcut) { MakeShortcut(desk, exe, "", dir, icon, "Otis"); made.Add(desk); }
            else try { if (File.Exists(desk)) File.Delete(desk); } catch { }
            string startup = Shortcut(Environment.SpecialFolder.Startup, ProductName);
            if (o.StartWithWindows) { MakeShortcut(startup, exe, "--background", dir, icon, "Otis (starts in the background)"); made.Add(startup); }
            else try { if (File.Exists(startup)) File.Delete(startup); } catch { }
            foreach (string l in made)
                try { RunHidden(exe, "--register-shortcut \"" + l + "\"", 15000); } catch { }

            report(80, "Registering with Windows");
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                k.SetValue("DisplayName", ProductName);
                k.SetValue("DisplayVersion", Version);
                k.SetValue("Publisher", ProductName);
                k.SetValue("DisplayIcon", exe + ",0");
                k.SetValue("InstallLocation", dir);
                k.SetValue("UninstallString", "\"" + unins + "\" --uninstall");
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
            string bin = ClaudeBinDir();
            if (File.Exists(Path.Combine(bin, "claude.exe")))
            {
                string up = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User) ?? "";
                if (up.IndexOf(bin, StringComparison.OrdinalIgnoreCase) < 0)
                    Environment.SetEnvironmentVariable("PATH", up.TrimEnd(';') + ";" + bin, EnvironmentVariableTarget.User);
            }
            report(100, "Done");
        }

        static Dictionary<string, object> ReadSettingsText(string text)
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            return js.Deserialize<Dictionary<string, object>>(text);
        }

        // ------------------------------------------------------------------ uninstall
        public static void Uninstall(string dir, bool deleteData, Progress report)
        {
            report(10, "Closing Otis");
            StopOtis();
            report(30, "Removing shortcuts");
            foreach (Environment.SpecialFolder f in new Environment.SpecialFolder[] { Environment.SpecialFolder.Programs, Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.Startup })
                foreach (string nm in new string[] { ProductName, "Daily Briefing" })
                    try { string l = Shortcut(f, nm); if (File.Exists(l)) File.Delete(l); } catch { }
            report(50, "Removing program files");
            try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
            string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), ProductName);
            try { DeleteDir(local); } catch { }
            DeleteDir(Path.Combine(dir, "app"));
            try { File.Delete(Path.Combine(dir, "Otis.exe")); } catch { }
            if (deleteData)
            {
                report(75, "Deleting your data");
                DeleteDir(Path.Combine(dir, "data"));
                try { File.Delete(Path.Combine(dir, "settings.json")); } catch { }
            }
            report(100, "Done");
        }

        // Deletes this running copy after it exits, and the install folder if nothing is left in it
        public static void ScheduleSelfDelete(string selfExe, string dir)
        {
            string c = "ping 127.0.0.1 -n 4 >nul & del /f /q \"" + selfExe + "\" & del /f /q \"" + Path.Combine(dir, "Uninstall.exe") + "\" & rmdir \"" + dir + "\"";
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/c " + c);
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            Process.Start(psi);
        }
    }
}
