using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

class KioskChromeLauncher
{
    static int Main(string[] args)
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string chromePs1 = Path.Combine(exeDir, "Start-KioskChrome.ps1");

        if (!File.Exists(chromePs1))
        {
            if (!ExtractEmbeddedScript(chromePs1))
            {
                Console.WriteLine("Start-KioskChrome.ps1 could not be found or extracted next to this executable.");
                Console.WriteLine("Expected at: " + chromePs1);
                Console.WriteLine("Press Enter to exit...");
                Console.ReadLine();
                return 1;
            }
        }

        StringBuilder psArgs = new StringBuilder();
        psArgs.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(chromePs1).Append("\"");
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

    static bool ExtractEmbeddedScript(string destinationPath)
    {
        // The build script embeds the current Start-KioskChrome.ps1 as a manifest
        // resource named "KioskChromeScript". Extracted once, on first run only -
        // if a local copy already exists it is left untouched so an operator's
        // own edits are never overwritten by a later run of this same exe.
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream resourceStream = asm.GetManifestResourceStream("KioskChromeScript"))
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
