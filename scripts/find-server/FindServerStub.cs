using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

class FindServerLauncher
{
    static int Main(string[] args)
    {
        // Everything this exe needs (the extracted script, and the shared
        // server-cache file the whole toolbox reads/writes) lives under this
        // exe's own directory - never the extracted script's subfolder - so a
        // technician sees exactly 3 .exe files at the top of the toolbox zip
        // and every tool agrees on one vrhm_server_cache.json location.
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string subDir = Path.Combine(exeDir, "find-server");
        string scriptPs1 = Path.Combine(subDir, "Find-VRHM-Server.ps1");
        string cachePath = Path.Combine(exeDir, "vrhm_server_cache.json");

        if (!File.Exists(scriptPs1))
        {
            Directory.CreateDirectory(subDir);
            if (!ExtractEmbeddedScript(scriptPs1))
            {
                Console.WriteLine("Find-VRHM-Server.ps1 could not be found or extracted.");
                Console.WriteLine("Expected at: " + scriptPs1);
                Console.WriteLine("Press Enter to exit...");
                Console.ReadLine();
                return 1;
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

        int exitCode;
        using (Process p = Process.Start(psi))
        {
            p.WaitForExit();
            exitCode = p.ExitCode;
        }

        // Find-VRHM-Server.ps1 is a one-shot scan that returns as soon as it is
        // done (unlike the kiosk agent, which runs forever) - without this, a
        // double-click would flash a console window and close it before the
        // technician can read the results.
        Console.WriteLine();
        Console.WriteLine("Press Enter to close...");
        Console.ReadLine();
        return exitCode;
    }

    static bool ExtractEmbeddedScript(string destinationPath)
    {
        // The build script embeds the current Find-VRHM-Server.ps1 as a
        // manifest resource named "FindServerScript". Extracted once, on
        // first run only - if a local copy already exists it is left
        // untouched so an operator's own edits are never overwritten by a
        // later run of this same exe.
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream resourceStream = asm.GetManifestResourceStream("FindServerScript"))
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
