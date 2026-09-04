using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

class KioskAgentLauncher
{
    static int Main(string[] args)
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string agentPs1 = Path.Combine(exeDir, "Start-KioskAgent.ps1");

        if (!File.Exists(agentPs1))
        {
            if (!ExtractEmbeddedScript(agentPs1))
            {
                Console.WriteLine("Start-KioskAgent.ps1 could not be found or extracted next to this executable.");
                Console.WriteLine("Expected at: " + agentPs1);
                Console.WriteLine("Press Enter to exit...");
                Console.ReadLine();
                return 1;
            }
        }

        StringBuilder psArgs = new StringBuilder();
        psArgs.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(agentPs1).Append("\"");
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
        // The build script embeds the current Start-KioskAgent.ps1 as a manifest
        // resource named "KioskAgentScript". Extracted once, on first run only -
        // if a local copy already exists it is left untouched so an operator's
        // own edits are never overwritten by a later run of this same exe.
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream resourceStream = asm.GetManifestResourceStream("KioskAgentScript"))
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
