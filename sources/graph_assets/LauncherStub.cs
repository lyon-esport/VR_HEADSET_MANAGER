using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

class Launcher
{
    static int Main(string[] args)
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string mainPs1 = Path.Combine(exeDir, "main.ps1");

        if (!File.Exists(mainPs1))
        {
            Console.WriteLine("main.ps1 not found next to this executable: " + mainPs1);
            Console.WriteLine("Press Enter to exit...");
            Console.ReadLine();
            return 1;
        }

        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -File \"" + mainPs1 + "\"");
        psi.UseShellExecute = false;
        psi.WorkingDirectory = exeDir;

        using (Process p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}
