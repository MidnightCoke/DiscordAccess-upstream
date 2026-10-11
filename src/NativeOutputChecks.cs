using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace DiscordAccess
{
    internal static class NativeOutputChecks
    {
        [DllImport("kernel32.dll")]
        private static extern uint GetConsoleProcessList([Out] uint[] processes, uint count);
        private static void Require(bool value, string message)
        { if (!value) throw new InvalidOperationException("Native output: " + message); }

        // A generated, inert console fixture exercises the real CreateProcess
        // path. Its only disk write is a report in the fixture directory.
        private const string ChildSource = @"
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
class NativeOutputFixture {
 [DllImport(""kernel32.dll"")] static extern IntPtr GetStdHandle(int id);
 [DllImport(""kernel32.dll"")] static extern uint GetFileType(IntPtr h);
 [DllImport(""kernel32.dll"")] static extern bool GetConsoleMode(IntPtr h, out uint mode);
 [DllImport(""kernel32.dll"")] static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint written, IntPtr o);
 [DllImport(""kernel32.dll"")] static extern bool ReadFile(IntPtr h, byte[] b, uint n, out uint read, IntPtr o);
 [DllImport(""kernel32.dll"")] static extern IntPtr GetConsoleWindow();
 [DllImport(""kernel32.dll"",SetLastError=true)] static extern bool AttachConsole(uint process);
 [DllImport(""kernel32.dll"")] static extern bool FreeConsole();
 static int Main() {
  try {
   bool attachAttempt=Environment.GetEnvironmentVariable(""DA_OUTPUT_FIXTURE_ATTACH"")==""1"";
   if(attachAttempt && GetConsoleWindow()!=IntPtr.Zero) FreeConsole();
   bool attached=attachAttempt && AttachConsole(0xffffffff);
   int attachError=attached?0:Marshal.GetLastWin32Error();
   IntPtr input=GetStdHandle(-10), output=GetStdHandle(-11), error=GetStdHandle(-12);
   uint mode, writtenOut, writtenErr; byte[] payload=Encoding.ASCII.GetBytes(""CHILD_OUTPUT_MUST_NOT_REACH_LAUNCHER\r\n"");
   bool outOk=WriteFile(output,payload,(uint)payload.Length,out writtenOut,IntPtr.Zero);
   bool errOk=WriteFile(error,payload,(uint)payload.Length,out writtenErr,IntPtr.Zero);
   byte[] data=new byte[16384]; uint read;
   using(var buffer=new MemoryStream()) {
    while(ReadFile(input,data,(uint)data.Length,out read,IntPtr.Zero) && read>0) buffer.Write(data,0,(int)read);
    string report=String.Join(""|"",new string[]{
     GetFileType(input).ToString(),GetFileType(output).ToString(),GetFileType(error).ToString(),
     GetConsoleMode(input,out mode).ToString(),GetConsoleMode(output,out mode).ToString(),GetConsoleMode(error,out mode).ToString(),
     (GetConsoleWindow()==IntPtr.Zero).ToString(),outOk.ToString(),errOk.ToString(),writtenOut.ToString(),writtenErr.ToString(),
     Convert.ToBase64String(buffer.ToArray()),attached.ToString(),attachError.ToString() });
    File.WriteAllText(Environment.GetEnvironmentVariable(""DA_OUTPUT_FIXTURE_REPORT""),report);
   }
   return 0;
  } catch { return 7; }
 }
}";

        internal static int Run(string fixtureRoot)
        {
            string directory = Path.Combine(Path.GetFullPath(fixtureRoot), "work", "native-output-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string source = Path.Combine(directory, "Fixture.cs"), image = Path.Combine(directory, "Fixture.exe");
            string guiImage = Path.Combine(directory, "FixtureGui.exe");
            string report = Path.Combine(directory, "report.txt");
            try
            {
                File.WriteAllText(source, ChildSource, new UTF8Encoding(false));
                string compiler = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"Microsoft.NET\Framework64\v4.0.30319\csc.exe");
                var build = new ProcessStartInfo(compiler, "/nologo /target:exe /out:" + NativeProcess.Quote(image) + " " + NativeProcess.Quote(source))
                { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = directory };
                using (var compilerProcess = Process.Start(build))
                {
                    var output = compilerProcess.StandardOutput.ReadToEndAsync();
                    var error = compilerProcess.StandardError.ReadToEndAsync();
                    Require(compilerProcess.WaitForExit(15000), "Synthetic child compiler timed out.");
                    Require(compilerProcess.ExitCode == 0, "Synthetic child did not compile.");
                    output.GetAwaiter().GetResult(); error.GetAwaiter().GetResult();
                }
                build.Arguments = "/nologo /target:winexe /out:" + NativeProcess.Quote(guiImage) + " " + NativeProcess.Quote(source);
                using (var compilerProcess = Process.Start(build))
                {
                    var output = compilerProcess.StandardOutput.ReadToEndAsync();
                    var error = compilerProcess.StandardError.ReadToEndAsync();
                    Require(compilerProcess.WaitForExit(15000), "Synthetic GUI child compiler timed out.");
                    Require(compilerProcess.ExitCode == 0, "Synthetic GUI child did not compile.");
                    output.GetAwaiter().GetResult(); error.GetAwaiter().GetResult();
                }
                int checks = 0;
                foreach (string config in new[] { (string)null, "", "Synthetic config: Türkçe \"quoted\" data\r\n" + new string('x', 50000) })
                {
                    if (File.Exists(report)) File.Delete(report);
                    using (var job = new NativeSessionJob())
                    using (var child = NativeProcess.Start(job, image, "", directory,
                        new Dictionary<string, string> { { "DA_OUTPUT_FIXTURE_REPORT", report } }, config))
                    {
                        Require(child.WaitForExit(10000), "Child stdin did not reach EOF or output blocked."); checks++;
                        Require(child.ExitCode == 0 && File.Exists(report), "Child standard handles are unusable."); checks++;
                        string[] fields = File.ReadAllText(report).Split('|');
                        Require(fields.Length == 14, "Invalid child fixture report.");
                        Require(fields[0] == (config == null ? "2" : "3"), "Input handle did not use NUL or configuration pipe."); checks++;
                        Require(fields[1] == "2" && fields[2] == "2", "Output handle is not a NUL character device."); checks++;
                        Require(fields[3] == "False" && fields[4] == "False" && fields[5] == "False" && fields[6] == "True",
                            "Child inherited a launcher console handle or owns a console window."); checks++;
                        Require(fields[7] == "True" && fields[8] == "True" && fields[9] == "38" && fields[10] == "38",
                            "Child output was not accepted by NUL."); checks++;
                        string expected = Convert.ToBase64String(Encoding.UTF8.GetBytes(config ?? ""));
                        Require(fields[11] == expected, "Configuration pipe content or null-input EOF changed."); checks++;
                    }
                }
                if (File.Exists(report)) File.Delete(report);
                // A headless/pseudo console can have no window handle while
                // still accepting AttachConsole; query membership instead.
                bool parentHasConsole = GetConsoleProcessList(new uint[1], 1) > 0;
                using (var job = new NativeSessionJob())
                using (var child = NativeProcess.Start(job, guiImage, "", directory,
                    new Dictionary<string, string> { { "DA_OUTPUT_FIXTURE_REPORT", report }, { "DA_OUTPUT_FIXTURE_ATTACH", "1" } }, null))
                {
                    Require(child.WaitForExit(10000) && child.ExitCode == 0 && File.Exists(report), "GUI child's console attachment blocked or failed."); checks++;
                    string[] fields = File.ReadAllText(report).Split('|');
                    Require(fields.Length == 14 && fields[0] == "2" && fields[11] == "", "GUI input stopped being NUL/EOF."); checks++;
                    Require(fields[1] == "2" && fields[2] == "2" && fields[4] == "False" && fields[5] == "False",
                        "GUI AttachConsole replaced NUL outputs with console handles."); checks++;
                    Require(fields[7] == "True" && fields[8] == "True" && fields[9] == "38" && fields[10] == "38",
                        "GUI output was not accepted by NUL after attachment."); checks++;
                    Require(fields[12] == parentHasConsole.ToString(), "GUI attachment did not match parent console availability (parent=" + parentHasConsole + ", child=" + fields[12] + ", childNoWindow=" + fields[6] + ", error=" + fields[13] + ")."); checks++;
                    Console.WriteLine("GUI AttachConsole fixture: " + (parentHasConsole ? "attached to parent; NUL outputs preserved" : "parent has no console; NUL outputs preserved"));
                }
                return checks;
            }
            finally
            {
                // Only direct files generated in this unique fixture are removed.
                foreach (string file in Directory.GetFiles(directory)) File.Delete(file);
                Directory.Delete(directory);
            }
        }
    }
}
