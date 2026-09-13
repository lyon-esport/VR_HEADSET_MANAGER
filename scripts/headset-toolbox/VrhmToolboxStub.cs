using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

class VrhmToolboxLauncher
{
    static int Main(string[] args)
    {
        // Everything this exe owns - the program files AND the server cache -
        // lives in a VRHM-Toolbox\ subfolder next to it, so a technician who
        // downloads one binary ends up with one binary and one folder, and
        // nothing else is ever dropped beside it. The cache path matches what
        // Start-VrhmToolbox.ps1 resolves on its own when run directly from
        // PowerShell (next to the script), so the exe and the .ps1 share one
        // cache instead of keeping two.
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string subDir = Path.Combine(exeDir, "VRHM-Toolbox");
        string entryPs1 = Path.Combine(subDir, "Start-VrhmToolbox.ps1");
        string cachePath = Path.Combine(subDir, "vrhm_server_cache.json");

        // adb.exe is deliberately NOT in this list. It is downloaded from the
        // VRHM server on first use, so this binary stays small and adb never
        // drifts from the version the server itself runs.
        string[] embeddedFiles = new string[] {
            "Start-VrhmToolbox.ps1",
            "VrhmServerDiscovery.ps1",
            "VrhmHeadsetOnboard.ps1",
            "VrhmKioskAgent.ps1"
        };

        // Unconditional: the folder must exist even when nothing needs
        // extracting, because the server cache is written into it.
        Directory.CreateDirectory(subDir);

        // The program files belong to THIS build of the exe, and the build is
        // identified by the assembly's ModuleVersionId - a fresh GUID every
        // compile. A stamp file records which build the extracted copies came
        // from.
        //
        // Extract-if-missing alone is not enough, and the failure is silent and
        // expensive: replacing the exe left the OLD scripts in place, so the new
        // binary went on running last week's behaviour with no warning anywhere.
        // Overwriting on a build change fixes that while still leaving the files
        // editable for as long as the exe stays the same - so "edit the extracted
        // script and re-run" keeps working, and "drop in a new exe" now actually
        // updates what runs.
        string buildId = Assembly.GetExecutingAssembly().ManifestModule.ModuleVersionId.ToString();
        string stampPath = Path.Combine(subDir, ".vrhm-build-id");
        bool buildChanged = true;
        try
        {
            if (File.Exists(stampPath))
            {
                buildChanged = (File.ReadAllText(stampPath).Trim() != buildId);
            }
        }
        catch
        {
            buildChanged = true;
        }

        foreach (string name in embeddedFiles)
        {
            string destination = Path.Combine(subDir, name);
            if (File.Exists(destination) && !buildChanged) { continue; }
            if (!ExtractEmbeddedResource(name, destination))
            {
                Console.WriteLine(name + " could not be found or extracted.");
                Console.WriteLine("Expected at: " + destination);
                Console.WriteLine("Press Enter to exit...");
                Console.ReadLine();
                return 1;
            }
        }

        if (buildChanged)
        {
            // adb.exe, its DLLs and vrhm_server_cache.json live in the same folder
            // and are deliberately NOT touched here - they are downloaded state,
            // not program files.
            try { File.WriteAllText(stampPath, buildId); }
            catch { }
        }

        StringBuilder psArgs = new StringBuilder();
        psArgs.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(entryPs1).Append("\"");
        psArgs.Append(" -ServerCachePath \"").Append(cachePath).Append("\"");
        foreach (string arg in args)
        {
            // Only quote what actually needs quoting: powershell.exe -File binds a
            // quoted "-kiosk" as a VALUE rather than as the switch it is, so
            // blanket-quoting every argument would silently break every switch.
            psArgs.Append(' ');
            if (arg.IndexOf(' ') >= 0 || arg.IndexOf('\t') >= 0)
            {
                psArgs.Append('"').Append(arg.Replace("\"", "\\\"")).Append('"');
            }
            else
            {
                psArgs.Append(arg);
            }
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
        // exists it is left untouched, so an operator's own edits survive a
        // later run of this same exe.
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
