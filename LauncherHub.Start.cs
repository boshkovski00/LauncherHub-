using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class LauncherHubStart
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string directory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            foreach (string file in new[] { "LauncherHub.ps1", "LauncherHubUpdates.ps1", "LauncherHub.UpdateCore.ps1", "LauncherHub.xaml", "LauncherHub.Card.xaml" })
                if (!File.Exists(Path.Combine(directory, file)))
                    throw new FileNotFoundException("Bitte das gesamte ZIP entpacken. Im Ordner fehlt: " + file);

            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" +
                    Path.Combine(directory, "LauncherHub.ps1") + "\"",
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process process = Process.Start(start)) { }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Launcher Hub", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
