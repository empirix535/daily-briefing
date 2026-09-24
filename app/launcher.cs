// Daily Briefing launcher (built into DailyBriefing.exe by Install.ps1 with the C# compiler included in Windows).
//   1. Starts classic Outlook minimized if it is not running.
//   2. Starts app\server.ps1 hidden (tray icon only) if the server is not already running.
//   3. Opens the dashboard window (Chrome, else Edge), or brings it to the front if it is already open.
//      Skipped with --background (used by "Start with Windows").
//   4. Tags the window with the app's taskbar ID, so it shares one taskbar button with the pinned launcher,
//      and pinning the open window pins this launcher (with its icon) instead of Chrome.
//   --register-shortcut "<path.lnk>" tags a shortcut with the same ID (used by Install.ps1).
// Written for C# 5 so it compiles with the .NET Framework 4.x compiler.
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program
{
    const string AppId = "DailyBriefing.Dashboard";
    const string WindowTitle = "Daily Briefing";

    [STAThread]
    static int Main(string[] args)
    {
        bool background = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i].Equals("--background", StringComparison.OrdinalIgnoreCase)) background = true;
            if (args[i].Equals("--register-shortcut", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                return Taskbar.TagShortcut(args[i + 1], AppId) ? 0 : 1;
        }

        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string server = Path.Combine(Path.Combine(baseDir, "app"), "server.ps1");
        string url = "http://localhost:" + ReadPort(baseDir) + "/";

        try
        {
            if (Process.GetProcessesByName("OUTLOOK").Length == 0) StartOutlookMinimized();

            if (!ServerUp(url))
            {
                if (!File.Exists(server)) { Warn("Could not find app\\server.ps1 next to DailyBriefing.exe."); return 1; }
                ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + server + "\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WorkingDirectory = baseDir;
                Process.Start(psi);
                for (int i = 0; i < 60 && !ServerUp(url); i++) Thread.Sleep(500);
                if (!ServerUp(url)) { Warn("The Daily Briefing server did not start.\nCheck data\\server.log for details."); return 1; }
            }

            if (!background)
            {
                string exe = Assembly.GetExecutingAssembly().Location;
                IntPtr existing = Taskbar.FindWindow(WindowTitle);
                if (existing != IntPtr.Zero)
                {
                    Taskbar.TagWindow(existing, AppId, exe);
                    Taskbar.BringToFront(existing);
                }
                else
                {
                    OpenWindow(url);
                    // Wait for the page to load (its title becomes "Daily Briefing"), then tag the window
                    for (int i = 0; i < 60; i++)
                    {
                        Thread.Sleep(300);
                        IntPtr w = Taskbar.FindWindow(WindowTitle);
                        if (w != IntPtr.Zero) { Taskbar.TagWindow(w, AppId, exe); break; }
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Warn(ex.Message);
            return 1;
        }
    }

    // Port from settings.json ("Port": 8000), default 8000
    static int ReadPort(string baseDir)
    {
        try
        {
            string path = Path.Combine(baseDir, "settings.json");
            if (File.Exists(path))
            {
                Match m = Regex.Match(File.ReadAllText(path), "\"Port\"\\s*:\\s*(\\d+)");
                if (m.Success) return int.Parse(m.Groups[1].Value);
            }
        }
        catch { }
        return 8000;
    }

    static bool ServerUp(string url)
    {
        try
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url + "api/ping");
            req.Timeout = 1000;
            req.Proxy = null;
            using (HttpWebResponse res = (HttpWebResponse)req.GetResponse())
                return res.StatusCode == HttpStatusCode.OK;
        }
        catch { return false; }
    }

    static void StartOutlookMinimized()
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("outlook.exe");
            psi.UseShellExecute = true;
            psi.WindowStyle = ProcessWindowStyle.Minimized;
            Process.Start(psi);
        }
        catch { return; }

        // Minimize the main window once it exists (reply windows are separate and open normally)
        Type t = Type.GetTypeFromProgID("Outlook.Application");
        if (t == null) return;
        for (int i = 0; i < 30; i++)
        {
            try
            {
                object app = Activator.CreateInstance(t);
                object explorer = t.InvokeMember("ActiveExplorer", BindingFlags.InvokeMethod, null, app, null);
                if (explorer != null)
                {
                    explorer.GetType().InvokeMember("WindowState", BindingFlags.SetProperty, null, explorer, new object[] { 1 });
                    return;
                }
            }
            catch { }
            Thread.Sleep(500);
        }
    }

    static void OpenWindow(string url)
    {
        ProcessStartInfo psi = new ProcessStartInfo(FindBrowser(), "--app=" + url + " --window-size=960,1350");
        psi.UseShellExecute = true;
        Process.Start(psi);
    }

    static string FindBrowser()
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
        return "chrome.exe";
    }

    static void Warn(string text)
    {
        MessageBox.Show(text, "Daily Briefing", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}

// Windows taskbar identity: AppUserModelID on windows and shortcuts
static class Taskbar
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PROPERTYKEY { public Guid fmtid; public uint pid; public PROPERTYKEY(Guid g, uint p) { fmtid = g; pid = p; } }

    [StructLayout(LayoutKind.Explicit)]
    struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public long pad; }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint cProps);
        [PreserveSig] int GetAt(uint iProp, out PROPERTYKEY pkey);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class CShellLink { }

    static readonly Guid AUMID = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static PROPERTYKEY KeyAppId           = new PROPERTYKEY(AUMID, 5);
    static PROPERTYKEY KeyRelaunchCommand = new PROPERTYKEY(AUMID, 2);
    static PROPERTYKEY KeyRelaunchIcon    = new PROPERTYKEY(AUMID, 3);
    static PROPERTYKEY KeyRelaunchName    = new PROPERTYKEY(AUMID, 4);

    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, out IPropertyStore store);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    delegate bool EnumProc(IntPtr h, IntPtr lParam);

    static void Set(IPropertyStore store, PROPERTYKEY key, string value)
    {
        PROPVARIANT pv = new PROPVARIANT();
        pv.vt = 31;   // VT_LPWSTR
        pv.p = Marshal.StringToCoTaskMemUni(value);
        try { store.SetValue(ref key, ref pv); }
        finally { Marshal.FreeCoTaskMem(pv.p); }
    }

    // The visible Chrome/Edge window whose title is exactly the dashboard's title
    public static IntPtr FindWindow(string title)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.ToString() != title) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            try
            {
                string name = Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant();
                if (name == "chrome" || name == "msedge") { found = h; return false; }
            }
            catch { }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void TagWindow(IntPtr hwnd, string appId, string exePath)
    {
        try
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null) return;
            Set(store, KeyRelaunchCommand, "\"" + exePath + "\"");
            Set(store, KeyRelaunchName, "Daily Briefing");
            Set(store, KeyRelaunchIcon, exePath + ",0");
            Set(store, KeyAppId, appId);   // set last: the taskbar regroups when this changes
            Marshal.ReleaseComObject(store);
        }
        catch { }
    }

    public static bool TagShortcut(string lnkPath, string appId)
    {
        try
        {
            object link = new CShellLink();
            IPersistFile file = (IPersistFile)link;
            file.Load(lnkPath, 2);   // STGM_READWRITE
            IPropertyStore store = (IPropertyStore)link;
            Set(store, KeyAppId, appId);
            store.Commit();
            file.Save(lnkPath, true);
            Marshal.ReleaseComObject(link);
            return true;
        }
        catch { return false; }
    }

    public static void BringToFront(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9);   // SW_RESTORE
        SetForegroundWindow(hwnd);
    }
}
