using System;
using System.Diagnostics;
using System.Collections.Concurrent;
using System.Text;
namespace YouTubeCorpus {
    public sealed class ProcessRunner : IDisposable {
        public Process Process;
        private bool started;
        public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
        private readonly StringBuilder output = new StringBuilder();
        private readonly StringBuilder error = new StringBuilder();
        public string Output { get { lock(output) return output.ToString(); } }
        public string Error { get { lock(error) return error.ToString(); } }
        // Windows CommandLineToArgvW/CRT quoting, including trailing backslashes.
        public static string Quote(string value) {
            var b = new StringBuilder("\""); int slash=0;
            foreach(char c in value) {
                if(c=='\\') { slash++; continue; }
                if(c=='"') { b.Append('\\',slash*2+1); b.Append(c); slash=0; continue; }
                b.Append('\\',slash); slash=0; b.Append(c);
            }
            b.Append('\\',slash*2); b.Append('"'); return b.ToString();
        }
        public void Start(string executable, string[] args) {
            var quoted = new string[args.Length];
            for(int i=0;i<args.Length;i++) quoted[i]=Quote(args[i]);
            var info = new ProcessStartInfo(executable,string.Join(" ",quoted));
            info.UseShellExecute=false; info.CreateNoWindow=true;
            info.RedirectStandardOutput=true; info.RedirectStandardError=true;
            info.StandardOutputEncoding=Encoding.UTF8; info.StandardErrorEncoding=Encoding.UTF8;
            Process=new Process(); Process.StartInfo=info;
            Process.OutputDataReceived += (s,e) => { if(e.Data!=null) { lock(output) output.AppendLine(e.Data); Lines.Enqueue(e.Data); } };
            Process.ErrorDataReceived += (s,e) => { if(e.Data!=null) { lock(error) error.AppendLine(e.Data); Lines.Enqueue(e.Data); } };
            Process.Start(); started=true; Process.BeginOutputReadLine(); Process.BeginErrorReadLine();
        }
        public void Cancel() {
            if(started && Process!=null && !Process.HasExited) {
                // taskkill includes yt-dlp children such as ffmpeg and JS runtimes.
                var info=new ProcessStartInfo("taskkill.exe", "/PID "+Process.Id+" /T /F");
                info.CreateNoWindow=true; info.UseShellExecute=false;
                using(var kill=System.Diagnostics.Process.Start(info)) kill.WaitForExit(5000);
                if(!Process.HasExited) Process.Kill();
            }
        }
        public void Dispose() { if(Process!=null) { Cancel(); Process.Dispose(); } }
    }
}
