using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

class HeadsetToolboxLauncher
{
    static int Main(string[] args)
    {
        // Everything this exe needs (the extracted script, adb.exe + its two
        // DLLs, and the shared server-cache file the whole toolbox reads and
        // writes) lives under this exe's own directory - never loose at the
        // zip root - so a technician sees exactly 3 .exe files at the top of
        // the toolbox zip and every tool agrees on one vrhm_server_cache.json
        // location.
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string subDir = Path.Combine(exeDir, "headset-toolbox");
        string scriptPs1 = Path.Combine(subDir, "Enable-HeadsetWifiAdb.ps1");
        string cachePath = Path.Combine(exeDir, "vrhm_server_cache.json");

        string[] embeddedFiles = new string[] {
            "Enable-HeadsetWifiAdb.ps1",
            "adb.exe",
            "AdbWinApi.dll",
            "AdbWinUsbApi.dll"
        };

        bool needsExtraction = false;
        foreach (string name in embeddedFiles)
        {
            if (!File.Exists(Path.Combine(subDir, name))) { needsExtraction = true; break; }
        }

        if (needsExtraction)
        {
            Directory.CreateDirectory(subDir);
            foreach (string name in embeddedFiles)
            {
                string destination = Path.Combine(subDir, name);
                if (File.Exists(destination)) { continue; }
                if (!ExtractEmbeddedResource(name, destination))
                {
                    Console.WriteLine(name + " could not be found or extracted.");
                    Console.WriteLine("Expected at: " + destination);
                    Console.WriteLine("Press Enter to exit...");
                    Console.ReadLine();
                    return 1;
                }
            }
        }

        StringBuilder psArgs = new StringBuilder();
        psArgs.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(scriptPs1).Append("\"");
        psArgs.Append(" -ServerCachePath \"").Append(cachePath).Append("\"");
        foreach (string arg in args)
        {
            psArgs.Append(" \"").Append(arg.Replace("\"", "\\\"")).Append("\"");
        }

        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", psArgs.ToString());
        psi.UseShellExecute = false;
        psi.WorkingDirectory = exeDir;

        using (Process p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    static bool ExtractEmbeddedResource(string resourceName, string destinationPath)
    {
        // The build script embeds each file as a manifest resource named after
        // itself. Extracted once, on first run only - if a local copy already
        // exists it is left untouched so an operator's own edits (or adb.exe
        // updates) are never overwritten by a later run of this same exe.
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream resourceStream = asm.GetManifestResourceStream(resourceName))
        {
            if (resourceStream == null)
            {
                return false;
            }

            using (FileStream fileStream = new FileStream(destinationPath, FileMode.Create, FileAccess.Write))
            {
                resourceStream.CopyTo(fileStream);
            }
        }
        return true;
    }
}
