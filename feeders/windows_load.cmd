@echo off
:: SPDX-License-Identifier: MIT
:: Copyright (c) 2026 Esseforma LLC
::
:: windows_load.cmd -- sample Windows per-thread runqueue and I/O-wait
:: counts at 100 ms cadence and either print the stream to stdout or
:: pipe it into rtchart (https://rtchart.cloud.esseforma.com -- a
:: streaming OHLC chart renderer that consumes one numeric value per
:: line on stdin).
::
:: This .cmd file embeds C# source after the
:: __WINDOWS_LOAD_CSHARP_BELOW__ marker; the batch part discovers
:: csc.exe, extracts the source to a temp dir, compiles it, and runs
:: the resulting binary. No install step is required beyond a
:: .NET Framework or Roslyn csc.exe being reachable.
setlocal EnableExtensions EnableDelayedExpansion

set "CSC="
call :find_csc
if not defined CSC (
    echo No csc.exe was found. Checked Windows .NET Framework folders, PATH, .NET Framework registry install paths, and Visual Studio vswhere. 1>&2
    exit /b 1
)

set "WORKDIR=%TEMP%\windows_load_%RANDOM%%RANDOM%"
mkdir "%WORKDIR%" >nul 2>nul
if errorlevel 1 (
    echo Failed to create temporary directory: %WORKDIR% 1>&2
    exit /b 1
)

set "SRC=%WORKDIR%\windows_load.cs"
set "EXE=%WORKDIR%\windows_load.exe"

call :extract_csharp "%SRC%"
if errorlevel 1 (
    set "STATUS=1"
    goto cleanup
)

"%CSC%" /nologo /optimize+ /platform:anycpu /out:"%EXE%" "%SRC%"
if errorlevel 1 (
    set "STATUS=1"
    goto cleanup
)

"%EXE%" %*
set "STATUS=%ERRORLEVEL%"

:cleanup
rd /s /q "%WORKDIR%" >nul 2>nul
exit /b %STATUS%

:find_csc
set "WINDIR_CANDIDATE=%WINDIR%"
if not defined WINDIR_CANDIDATE set "WINDIR_CANDIDATE=%SystemRoot%"

if defined WINDIR_CANDIDATE (
    call :try_csc "%WINDIR_CANDIDATE%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if defined CSC exit /b 0
    call :try_csc "%WINDIR_CANDIDATE%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    if defined CSC exit /b 0

    if exist "%WINDIR_CANDIDATE%\Microsoft.NET\Framework64\" (
        for /D %%D in ("%WINDIR_CANDIDATE%\Microsoft.NET\Framework64\*") do (
            call :try_csc "%%~fD\csc.exe"
            if defined CSC exit /b 0
        )
    )

    if exist "%WINDIR_CANDIDATE%\Microsoft.NET\Framework\" (
        for /D %%D in ("%WINDIR_CANDIDATE%\Microsoft.NET\Framework\*") do (
            call :try_csc "%%~fD\csc.exe"
            if defined CSC exit /b 0
        )
    )
)

for /F "usebackq delims=" %%P in (`where csc.exe 2^>nul`) do (
    call :try_csc "%%~fP"
    if defined CSC exit /b 0
)

call :scan_registry_for_csc "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP"
if defined CSC exit /b 0
call :scan_registry_for_csc "HKLM\SOFTWARE\WOW6432Node\Microsoft\NET Framework Setup\NDP"
if defined CSC exit /b 0

set "PF86=%ProgramFiles(x86)%"
if defined PF86 (
    set "VSWHERE=%PF86%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist "!VSWHERE!" (
        for /F "usebackq delims=" %%P in (`"!VSWHERE!" -all -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\Roslyn\csc.exe" 2^>nul`) do (
            call :try_csc "%%~fP"
            if defined CSC exit /b 0
        )
    )
)

exit /b 0

:try_csc
if defined CSC exit /b 0
if "%~1"=="" exit /b 0
if not exist "%~1" exit /b 0
for %%F in ("%~1") do (
    if /I "%%~nxF"=="csc.exe" set "CSC=%%~fF"
)
exit /b 0

:scan_registry_for_csc
if defined CSC exit /b 0
set "REGROOT=%~1"
reg query "%REGROOT%" >nul 2>nul
if errorlevel 1 exit /b 0

for /F "tokens=1,2,*" %%A in ('reg query "%REGROOT%" /s /v InstallPath 2^>nul ^| findstr /R /C:"^[ ]*InstallPath[ ]"') do (
    call :try_csc "%%C\csc.exe"
    if defined CSC exit /b 0
)

for /F "tokens=1,2,*" %%A in ('reg query "%REGROOT%" /s /v Path 2^>nul ^| findstr /R /C:"^[ ]*Path[ ]"') do (
    call :try_csc "%%C\csc.exe"
    if defined CSC exit /b 0
)
exit /b 0

:extract_csharp
set "OUT=%~1"
set "MARKER_LINE="
for /F "tokens=1 delims=:" %%N in ('findstr /n /b /c:"// __WINDOWS_LOAD_CSHARP_BELOW__" "%~f0"') do (
    if not defined MARKER_LINE set "MARKER_LINE=%%N"
)

if not defined MARKER_LINE (
    echo Could not find embedded C# marker in %~f0 1>&2
    exit /b 1
)

more +%MARKER_LINE% "%~f0" > "%OUT%"
if errorlevel 1 (
    echo Failed to extract embedded C# source. 1>&2
    exit /b 1
)
exit /b 0

// __WINDOWS_LOAD_CSHARP_BELOW__
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Esseforma LLC
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class WindowsLoad
{
    private const int SystemProcessInformation = 5;
    private const int StatusSuccess = 0;
    private const int StatusInfoLengthMismatch = unchecked((int)0xC0000004);
    private const int StatusBufferTooSmall = unchecked((int)0xC0000023);
    private const int StatusBufferOverflow = unchecked((int)0x80000005);
    private const uint ThreadQueryInformation = 0x0040;

    // Waitable-timer constants.
    // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION requires Win10 1803+.
    // Fall back to a default-resolution timer if the flag is rejected.
    private const uint CreateWaitableTimerHighResolution = 0x00000002;
    private const uint Synchronize = 0x00100000;
    private const uint TimerModifyState = 0x00000002;
    private const uint TimerAccess = Synchronize | TimerModifyState;
    private const uint WaitObject0 = 0x00000000;
    private const uint WaitFailed = 0xFFFFFFFF;
    private const uint Infinite = 0xFFFFFFFF;
    private const uint JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;

    // Single source of truth for SYSTEM_PROCESS_INFORMATION and
    // SYSTEM_THREAD_INFORMATION layouts. Sequential layout + default
    // pack matches what ntdll produces on x86 and x64. If Microsoft
    // ever changes the layout, only these struct declarations need
    // to follow; downstream constants are derived via Marshal.OffsetOf
    // and Marshal.SizeOf.
    [StructLayout(LayoutKind.Sequential)]
    private struct UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_PROCESS_INFORMATION
    {
        public uint NextEntryOffset;
        public uint NumberOfThreads;
        public long WorkingSetPrivateSize;
        public uint HardFaultCount;
        public uint NumberOfThreadsHighWatermark;
        public ulong CycleTime;
        public long CreateTime;
        public long UserTime;
        public long KernelTime;
        public UNICODE_STRING ImageName;
        public int BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
        public uint HandleCount;
        public uint SessionId;
        public IntPtr UniqueProcessKey;
        public IntPtr PeakVirtualSize;
        public IntPtr VirtualSize;
        public uint PageFaultCount;
        public IntPtr PeakWorkingSetSize;
        public IntPtr WorkingSetSize;
        public IntPtr QuotaPeakPagedPoolUsage;
        public IntPtr QuotaPagedPoolUsage;
        public IntPtr QuotaPeakNonPagedPoolUsage;
        public IntPtr QuotaNonPagedPoolUsage;
        public IntPtr PagefileUsage;
        public IntPtr PeakPagefileUsage;
        public IntPtr PrivatePageCount;
        public long ReadOperationCount;
        public long WriteOperationCount;
        public long OtherOperationCount;
        public long ReadTransferCount;
        public long WriteTransferCount;
        public long OtherTransferCount;
        // Variable-length Threads[NumberOfThreads] follows at
        // Marshal.SizeOf(this).
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_THREAD_INFORMATION
    {
        public long KernelTime;
        public long UserTime;
        public long CreateTime;
        public uint WaitTime;
        public IntPtr StartAddress;
        public IntPtr ClientId_UniqueProcess;
        public IntPtr ClientId_UniqueThread;
        public int Priority;
        public int BasePriority;
        public uint ContextSwitches;
        public uint ThreadState;
        public uint WaitReason;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    // Field offsets / sizes derived from the structs above, computed
    // once at type init.
    private static readonly int ProcessHeadSize =
        Marshal.SizeOf(typeof(SYSTEM_PROCESS_INFORMATION));
    private static readonly int ProcessImageNameOffset =
        (int)Marshal.OffsetOf(typeof(SYSTEM_PROCESS_INFORMATION), "ImageName");
    private static readonly int ProcessUniquePidOffset =
        (int)Marshal.OffsetOf(typeof(SYSTEM_PROCESS_INFORMATION), "UniqueProcessId");
    private static readonly int UnicodeStringBufferOffset =
        (int)Marshal.OffsetOf(typeof(UNICODE_STRING), "Buffer");
    private static readonly int ThreadSize =
        Marshal.SizeOf(typeof(SYSTEM_THREAD_INFORMATION));
    private static readonly int ThreadUniqueThreadOffset =
        (int)Marshal.OffsetOf(typeof(SYSTEM_THREAD_INFORMATION), "ClientId_UniqueThread");
    private static readonly int ThreadStateOffset =
        (int)Marshal.OffsetOf(typeof(SYSTEM_THREAD_INFORMATION), "ThreadState");
    private static readonly int ThreadWaitReasonOffset =
        (int)Marshal.OffsetOf(typeof(SYSTEM_THREAD_INFORMATION), "WaitReason");

    // Documented bounds for ThreadState (KTHREAD_STATE) and
    // WaitReason (KWAIT_REASON). Both have been stable for years;
    // out-of-range values almost certainly indicate layout drift.
    private const uint MaxKnownThreadState = 9;
    private const uint MaxKnownWaitReason = 42;
    private const int DefaultIntervalMs = 100;
    private const double OneMinuteEmaWindowMs = 60000.0;

    private static IntPtr buffer = IntPtr.Zero;
    private static int bufferSize = 1024 * 1024;
    // Bytes the kernel said the most recent snapshot occupies (the
    // out-parameter from NtQuerySystemInformation). Always <=
    // bufferSize. Used as the upper bound for buffer-fit checks so
    // we don't grant slack between the snapshot end and the
    // high-water allocation.
    private static int lastReturnLength;

    [DllImport("ntdll.dll")]
    private static extern int NtQuerySystemInformation(
        int systemInformationClass,
        IntPtr systemInformation,
        int systemInformationLength,
        out int returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenThread(
        uint desiredAccess,
        bool inheritHandle,
        uint threadId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetThreadIOPendingFlag(
        IntPtr threadHandle,
        [MarshalAs(UnmanagedType.Bool)] out bool ioIsPending);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWaitableTimerExW(
        IntPtr lpTimerAttributes,
        string lpTimerName,
        uint dwFlags,
        uint dwDesiredAccess);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWaitableTimer(
        IntPtr hTimer,
        ref long lpDueTime,
        int lPeriod,
        IntPtr pfnCompletionRoutine,
        IntPtr lpArgToCompletionRoutine,
        [MarshalAs(UnmanagedType.Bool)] bool fResume);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObjectW(
        IntPtr lpJobAttributes,
        string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob,
        uint jobObjectInfoClass,
        IntPtr lpJobObjectInfo,
        uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(
        IntPtr hJob,
        IntPtr hProcess);

    private struct Sample
    {
        public long R;
        public long DIsh;
        public long ThreadsExamined;
        public long ThreadsRejectedOutOfRange;
        public long ProcessesRejectedNextEntry;
    }

    private sealed class Options
    {
        public int IntervalMs = DefaultIntervalMs;
        public int MaxSamples;
        public bool DebugRtchart;
        public bool Auto = true;
        public string XRange = "30";
        public string OhlcSpan = "1";
        public string WeightLow = "0";
        public string WeightHigh = "11";
        public string RtchartPath;
        public bool ApplyPriority = true;
        public ProcessPriorityClass PriorityClass = ProcessPriorityClass.AboveNormal;
        public readonly List<string> Rooms = new List<string>();
        public readonly List<string> ExtraRtchartArgs = new List<string>();
    }

    private static volatile bool cancelRequested;

    public static int Main(string[] args)
    {
        Options options;
        try
        {
            options = ParseArgs(args);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }

        if (options == null)
        {
            return 0;
        }

        IntPtr timer = IntPtr.Zero;
        RtchartManager rtchart = null;
        try
        {
            Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
            {
                e.Cancel = true;
                cancelRequested = true;
            };
            TryApplyPriority(
                Process.GetCurrentProcess(),
                options.PriorityClass,
                options.ApplyPriority,
                "sampler");

            buffer = Marshal.AllocHGlobal(bufferSize);

            // (A) Layout self-test against this process. Runs once
            // before the sampling loop; refuses to emit any data if
            // we don't recover our own PID / TID / image name out of
            // the snapshot. This catches the case where future
            // Microsoft additions to SYSTEM_PROCESS_INFORMATION shift
            // all our derived offsets.
            StartupSelfTest();

            // Try a high-resolution waitable timer first (Win10 1803+).
            // On older builds CreateWaitableTimerExW returns NULL with that
            // flag set; fall back to a default-resolution timer.
            timer = CreateWaitableTimerExW(
                IntPtr.Zero, null,
                CreateWaitableTimerHighResolution,
                TimerAccess);
            if (timer == IntPtr.Zero)
            {
                timer = CreateWaitableTimerExW(
                    IntPtr.Zero, null,
                    0,
                    TimerAccess);
            }
            if (timer == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "CreateWaitableTimerExW failed (error " +
                    Marshal.GetLastWin32Error() + ")");
            }

            // dueTime is negative for a relative wait (100-ns units);
            // lPeriod is in milliseconds. The kernel re-signals every
            // options.IntervalMs ms regardless of how long CollectSample takes,
            // so the cadence is fixed by the timer rather than by us
            // subtracting elapsed time from a Sleep budget.
            long dueTime = -((long)options.IntervalMs * 10000L);
            if (!SetWaitableTimer(
                    timer, ref dueTime, options.IntervalMs,
                    IntPtr.Zero, IntPtr.Zero, false))
            {
                throw new InvalidOperationException(
                    "SetWaitableTimer failed (error " +
                    Marshal.GetLastWin32Error() + ")");
            }

            double load1 = 0.0;
            double load1WarmupMs = 0.0;
            bool load1Initialized = false;

            if (options.Rooms.Count > 0)
            {
                rtchart = RtchartManager.Start(options);
            }
            else
            {
                Console.WriteLine("ms R D_ish load1");
                Console.Out.Flush();
            }

            Stopwatch stopwatch = Stopwatch.StartNew();
            int samples = 0;

            while (!cancelRequested &&
                   (options.MaxSamples <= 0 || samples < options.MaxSamples))
            {
                uint waitResult = WaitForSingleObject(timer, Infinite);
                if (waitResult != WaitObject0)
                {
                    throw new InvalidOperationException(
                        "WaitForSingleObject(timer) returned 0x" +
                        waitResult.ToString("X8") +
                        " (error " + Marshal.GetLastWin32Error() + ")");
                }

                Sample sample = CollectSample();

                // (B, continued) Per-tick rejection-rate gates.
                // > 1% rejected per sample: noisy warning to stderr;
                // > 10%: assume the layout is wrong and abort. The
                // bounds are documented and decade-stable; spurious
                // violation means we're reading garbage.
                if (sample.ThreadsExamined > 0)
                {
                    long rejected = sample.ThreadsRejectedOutOfRange;
                    if (rejected * 10 > sample.ThreadsExamined)
                    {
                        throw new InvalidOperationException(
                            "out-of-range ThreadState/WaitReason for " +
                            rejected + " of " + sample.ThreadsExamined +
                            " threads (>10%) - layout drift suspected, aborting");
                    }
                    if (rejected * 100 > sample.ThreadsExamined)
                    {
                        Console.Error.WriteLine(
                            "warning: " + rejected + " of " +
                            sample.ThreadsExamined +
                            " threads had out-of-range state/wait reason");
                    }
                }

                // Flush per line so a downstream consumer (rtchart, tee,
                // a pipe) sees rows in real time. .NET's default stdout
                // writer block-buffers when stdout is redirected.
                double active = (double)(sample.R + sample.DIsh);
                if (!load1Initialized)
                {
                    load1 = active;
                    load1WarmupMs = options.IntervalMs;
                    load1Initialized = true;
                }
                else
                {
                    load1WarmupMs += options.IntervalMs;
                    if (load1WarmupMs > OneMinuteEmaWindowMs)
                    {
                        load1WarmupMs = OneMinuteEmaWindowMs;
                    }
                    double load1Alpha = (double)options.IntervalMs / load1WarmupMs;
                    load1 = load1 + load1Alpha * (active - load1);
                }

                if (rtchart != null)
                {
                    rtchart.Write(sample, load1);
                }
                else
                {
                    Console.WriteLine(string.Format(
                        CultureInfo.InvariantCulture,
                        "{0} {1} {2} {3:F3}",
                        stopwatch.ElapsedMilliseconds,
                        sample.R,
                        sample.DIsh,
                        load1));
                    Console.Out.Flush();
                }
                samples++;
            }

            return cancelRequested ? 130 : 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.GetType().Name + ": " + ex.Message);
            return 1;
        }
        finally
        {
            if (rtchart != null)
            {
                rtchart.Dispose();
            }
            if (timer != IntPtr.Zero)
            {
                CloseHandle(timer);
            }
            if (buffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(buffer);
                buffer = IntPtr.Zero;
            }
        }
    }

    private static Options ParseArgs(string[] args)
    {
        Options options = new Options();

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            string value;

            if (arg == "--help" || arg == "-h" || arg == "/?")
            {
                PrintHelp();
                return null;
            }
            else if (TakeValue(args, ref i, "--interval-ms", arg, out value) ||
                     TakeValue(args, ref i, "--sample-ms", arg, out value))
            {
                options.IntervalMs = ParseInt(value, arg);
            }
            else if (TakeValue(args, ref i, "--samples", arg, out value))
            {
                options.MaxSamples = ParseInt(value, arg);
            }
            else if (TakeValue(args, ref i, "--x-range", arg, out value))
            {
                options.XRange = value;
            }
            else if (TakeValue(args, ref i, "--ohlc-span", arg, out value))
            {
                options.OhlcSpan = value;
            }
            else if (TakeValue(args, ref i, "--weight-low", arg, out value))
            {
                options.WeightLow = value;
            }
            else if (TakeValue(args, ref i, "--weight-high", arg, out value))
            {
                options.WeightHigh = value;
            }
            else if (TakeValue(args, ref i, "--rtchart", arg, out value))
            {
                options.RtchartPath = value;
            }
            else if (TakeValue(args, ref i, "--priority", arg, out value))
            {
                options.PriorityClass = ParsePriority(value);
                options.ApplyPriority = true;
            }
            else if (arg == "--debug")
            {
                options.DebugRtchart = true;
            }
            else if (arg == "--no-priority")
            {
                options.ApplyPriority = false;
            }
            else if (arg == "--auto")
            {
                options.Auto = true;
            }
            else if (arg == "--no-auto")
            {
                options.Auto = false;
            }
            else if (arg.Length > 0 && arg[0] == '-')
            {
                options.ExtraRtchartArgs.Add(arg);
            }
            else
            {
                options.Rooms.Add(arg);
            }
        }

        if (options.IntervalMs < 10)
        {
            throw new ArgumentException("--interval-ms must be at least 10");
        }
        if (options.MaxSamples < 0)
        {
            throw new ArgumentException("--samples must be non-negative");
        }
        if (options.Rooms.Count > 3)
        {
            throw new ArgumentException("Too many room IDs; expected 0, 1, 2, or 3");
        }

        return options;
    }

    private static ProcessPriorityClass ParsePriority(string value)
    {
        string normalized = value.Trim().ToLowerInvariant();
        switch (normalized)
        {
            case "normal":
                return ProcessPriorityClass.Normal;
            case "above":
            case "above-normal":
            case "abovenormal":
                return ProcessPriorityClass.AboveNormal;
            case "high":
                return ProcessPriorityClass.High;
            default:
                throw new ArgumentException(
                    "--priority must be normal, above-normal, or high");
        }
    }

    private static void TryApplyPriority(
        Process process,
        ProcessPriorityClass priorityClass,
        bool applyPriority,
        string label)
    {
        if (!applyPriority)
        {
            return;
        }

        try
        {
            process.PriorityClass = priorityClass;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(
                "warning: could not set " + label + " priority to " +
                priorityClass + " (" + ex.Message + ")");
        }
    }

    private static bool TakeValue(
        string[] args,
        ref int index,
        string name,
        string arg,
        out string value)
    {
        value = null;
        string prefix = name + "=";
        if (arg.StartsWith(prefix, StringComparison.Ordinal))
        {
            value = arg.Substring(prefix.Length);
            return true;
        }
        if (arg == name)
        {
            if (index + 1 >= args.Length)
            {
                throw new ArgumentException(name + " requires a value");
            }
            value = args[++index];
            return true;
        }
        return false;
    }

    private static int ParseInt(string value, string optionName)
    {
        int parsed;
        if (!int.TryParse(
                value,
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out parsed))
        {
            throw new ArgumentException(optionName + " requires an integer value");
        }
        return parsed;
    }

    private static void PrintHelp()
    {
        Console.Error.WriteLine("Usage: windows_load.cmd [<room-id> ...] [options]");
        Console.Error.WriteLine();
        Console.Error.WriteLine("Sample per-thread runqueue and I/O-wait counts every 100 ms and either");
        Console.Error.WriteLine("print the stream to stdout or drive rtchart instances. rtchart is a");
        Console.Error.WriteLine("streaming OHLC chart renderer that consumes one numeric value per line");
        Console.Error.WriteLine("on stdin; see https://rtchart.cloud.esseforma.com.");
        Console.Error.WriteLine();
        Console.Error.WriteLine("No room IDs: print samples to stdout:");
        Console.Error.WriteLine("    ms R D_ish load1");
        Console.Error.WriteLine();
        Console.Error.WriteLine("With 1-3 room IDs: start three rtchart peers and feed R, D_ish, load1.");
        Console.Error.WriteLine("Room mapping:");
        Console.Error.WriteLine("    1 room  -> all streams share it");
        Console.Error.WriteLine("    2 rooms -> R uses room 1; D_ish and load1 share room 2");
        Console.Error.WriteLine("    3 rooms -> R, D_ish, and load1 each use their own room");
        Console.Error.WriteLine();
        Console.Error.WriteLine("The rtchart-driving modes additionally require the rtchart binary.");
        Console.Error.WriteLine("windows_load.cmd searches PATH for rtchart-windows-amd64.exe and");
        Console.Error.WriteLine("rtchart-windows-arm64.exe (host-arch preferred). If neither is found,");
        Console.Error.WriteLine("--rtchart PATH or RTCHART=PATH is required.");
        Console.Error.WriteLine();
        Console.Error.WriteLine("Sampler options:");
        Console.Error.WriteLine("  --interval-ms N, --sample-ms N   sample interval (default 100)");
        Console.Error.WriteLine("  --samples N                      stop after N samples");
        Console.Error.WriteLine();
        Console.Error.WriteLine("rtchart options:");
        Console.Error.WriteLine("  --rtchart PATH                   path to rtchart binary. Equivalent to the");
        Console.Error.WriteLine("                                    RTCHART environment variable. Mandatory if");
        Console.Error.WriteLine("                                    neither rtchart-windows-amd64.exe nor");
        Console.Error.WriteLine("                                    rtchart-windows-arm64.exe is on PATH.");
        Console.Error.WriteLine("  --debug                          leave rtchart output attached");
        Console.Error.WriteLine("  --x-range N                      rtchart --x-range (default 30)");
        Console.Error.WriteLine("  --ohlc-span N                    rtchart --ohlc-span (default 1)");
        Console.Error.WriteLine("  --auto, --no-auto                value-axis auto-range (default on)");
        Console.Error.WriteLine("  --weight-low N                   rtchart --weight-low (default 0)");
        Console.Error.WriteLine("  --weight-high N                  rtchart --weight-high (default 11)");
        Console.Error.WriteLine();
        Console.Error.WriteLine("Priority options:");
        Console.Error.WriteLine("  --priority normal|above-normal|high");
        Console.Error.WriteLine("                                    sampler/rtchart priority (default above-normal)");
        Console.Error.WriteLine("  --no-priority                    leave process priorities unchanged");
        Console.Error.WriteLine();
        Console.Error.WriteLine("Unknown -flags are forwarded to rtchart; use --flag=value form.");
    }

    private sealed class RtchartManager : IDisposable
    {
        private readonly IntPtr job;
        private readonly Process[] processes;
        private readonly StreamWriter[] inputs;

        private RtchartManager(IntPtr job, Process[] processes, StreamWriter[] inputs)
        {
            this.job = job;
            this.processes = processes;
            this.inputs = inputs;
        }

        public static RtchartManager Start(Options options)
        {
            string rtchart = ResolveRtchartPath(options.RtchartPath);
            IntPtr job = CreateKillOnCloseJob();
            Process[] processes = new Process[3];
            StreamWriter[] inputs = new StreamWriter[3];

            try
            {
                string[] rooms = ResolveRooms(options.Rooms);
                string[] names = new string[]
                {
                    "R (runnable)",
                    "D-ish",
                    "load1 (1-min avg)"
                };

                for (int i = 0; i < 3; i++)
                {
                    List<string> childArgs = BuildRtchartArgs(options);
                    childArgs.Add("--name=" + names[i]);
                    childArgs.Add(rooms[i]);

                    Process process = StartChild(
                        rtchart,
                        childArgs,
                        options.DebugRtchart,
                        options.ApplyPriority,
                        options.PriorityClass);
                    if (!AssignProcessToJobObject(job, process.Handle))
                    {
                        int error = Marshal.GetLastWin32Error();
                        TryKill(process);
                        process.Dispose();
                        throw new InvalidOperationException(
                            "AssignProcessToJobObject(rtchart) failed (error " +
                            error + ")");
                    }

                    processes[i] = process;
                    inputs[i] = process.StandardInput;
                    inputs[i].AutoFlush = true;
                }

                return new RtchartManager(job, processes, inputs);
            }
            catch
            {
                CloseInputs(inputs);
                KillProcesses(processes);
                CloseHandle(job);
                throw;
            }
        }

        public void Write(Sample sample, double load1)
        {
            WriteValue(0, sample.R.ToString(CultureInfo.InvariantCulture));
            WriteValue(1, sample.DIsh.ToString(CultureInfo.InvariantCulture));
            WriteValue(2, load1.ToString("F3", CultureInfo.InvariantCulture));
        }

        public void Dispose()
        {
            CloseInputs(inputs);
            WaitForProcesses(processes, 1500);
            KillProcesses(processes);

            if (job != IntPtr.Zero)
            {
                CloseHandle(job);
            }

            for (int i = 0; i < processes.Length; i++)
            {
                if (processes[i] != null)
                {
                    processes[i].Dispose();
                    processes[i] = null;
                }
            }
        }

        private void WriteValue(int index, string value)
        {
            Process process = processes[index];
            if (process == null)
            {
                throw new InvalidOperationException("rtchart process was not started");
            }
            if (process.HasExited)
            {
                throw new IOException(
                    "rtchart exited with code " + process.ExitCode);
            }

            inputs[index].WriteLine(value);
            inputs[index].Flush();
        }

        private static List<string> BuildRtchartArgs(Options options)
        {
            List<string> args = new List<string>();
            args.Add("--x-range=" + options.XRange);
            args.Add("--ohlc-span=" + options.OhlcSpan);
            args.Add("--weight-low=" + options.WeightLow);
            args.Add("--weight-high=" + options.WeightHigh);
            if (options.Auto)
            {
                args.Add("--auto");
            }
            args.AddRange(options.ExtraRtchartArgs);
            return args;
        }

        private static string[] ResolveRooms(List<string> rooms)
        {
            string rRoom = rooms[0];
            string dRoom = rooms.Count >= 2 ? rooms[1] : rRoom;
            string lRoom = rooms.Count >= 3 ? rooms[2] : dRoom;
            return new string[] { rRoom, dRoom, lRoom };
        }

        private static Process StartChild(
            string rtchart,
            List<string> args,
            bool debug,
            bool applyPriority,
            ProcessPriorityClass priorityClass)
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = rtchart;
            psi.Arguments = JoinArguments(args);
            psi.UseShellExecute = false;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = !debug;
            psi.RedirectStandardError = !debug;
            psi.CreateNoWindow = !debug;
            psi.WorkingDirectory = Environment.CurrentDirectory;

            Process process = new Process();
            process.StartInfo = psi;
            process.EnableRaisingEvents = true;
            if (!debug)
            {
                process.OutputDataReceived += delegate { };
                process.ErrorDataReceived += delegate { };
            }

            try
            {
                if (!process.Start())
                {
                    throw new InvalidOperationException("failed to start rtchart");
                }
                TryApplyPriority(process, priorityClass, applyPriority, "rtchart");

                if (!debug)
                {
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                }
            }
            catch
            {
                TryKill(process);
                process.Dispose();
                throw;
            }

            return process;
        }

        private static IntPtr CreateKillOnCloseJob()
        {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "CreateJobObjectW failed (error " +
                    Marshal.GetLastWin32Error() + ")");
            }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags =
                JobObjectLimitKillOnJobClose;

            int length = Marshal.SizeOf(
                typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr pointer = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(info, pointer, false);
                if (!SetInformationJobObject(
                        job,
                        JobObjectExtendedLimitInformation,
                        pointer,
                        (uint)length))
                {
                    int error = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    throw new InvalidOperationException(
                        "SetInformationJobObject(KILL_ON_JOB_CLOSE) failed (error " +
                        error + ")");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }

            return job;
        }

        private static string ResolveRtchartPath(string overridePath)
        {
            // Explicit override (--rtchart PATH or RTCHART env) wins.
            // Otherwise look for the host-arch arch-named binary on
            // PATH; fall back to the other arch's name (the user may
            // have only one installed regardless of host).
            string candidate = CleanPath(overridePath);
            if (candidate.Length > 0)
            {
                return ResolveExecutableCandidate(candidate, true);
            }

            candidate = CleanPath(Environment.GetEnvironmentVariable("RTCHART"));
            if (candidate.Length > 0)
            {
                return ResolveExecutableCandidate(candidate, true);
            }

            string[] orderedNames = PreferredRtchartNames();
            for (int i = 0; i < orderedNames.Length; i++)
            {
                string fromPath = FindOnPath(orderedNames[i]);
                if (fromPath.Length > 0)
                {
                    return fromPath;
                }
            }

            throw new FileNotFoundException(
                "rtchart binary not found. Neither " +
                "rtchart-windows-amd64.exe nor " +
                "rtchart-windows-arm64.exe is on PATH. " +
                "Specify --rtchart PATH or set RTCHART=PATH.");
        }

        private static string[] PreferredRtchartNames()
        {
            string arch = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
            string wow64Arch = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432");
            bool isArm64 =
                string.Equals(arch, "ARM64", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(wow64Arch, "ARM64", StringComparison.OrdinalIgnoreCase);
            if (isArm64)
            {
                return new string[] {
                    "rtchart-windows-arm64.exe",
                    "rtchart-windows-amd64.exe"
                };
            }
            return new string[] {
                "rtchart-windows-amd64.exe",
                "rtchart-windows-arm64.exe"
            };
        }

        private static string ResolveExecutableCandidate(
            string candidate,
            bool required)
        {
            if (HasDirectoryPart(candidate))
            {
                string path = Path.GetFullPath(candidate);
                if (File.Exists(path))
                {
                    return path;
                }
                if (required)
                {
                    throw new FileNotFoundException(
                        "rtchart binary not found: " + candidate);
                }
                return "";
            }

            string found = FindOnPath(candidate);
            if (found.Length > 0)
            {
                return found;
            }
            if (required)
            {
                throw new FileNotFoundException(
                    "rtchart binary not found on PATH: " + candidate);
            }
            return "";
        }

        private static bool HasDirectoryPart(string path)
        {
            return path.IndexOf(Path.DirectorySeparatorChar) >= 0 ||
                   path.IndexOf(Path.AltDirectorySeparatorChar) >= 0 ||
                   path.IndexOf(':') >= 0;
        }

        private static string CleanPath(string path)
        {
            if (path == null)
            {
                return "";
            }
            return path.Trim().Trim('"');
        }

        private static string FindOnPath(string fileName)
        {
            string path = Environment.GetEnvironmentVariable("PATH");
            if (path == null)
            {
                return "";
            }

            string[] parts = path.Split(Path.PathSeparator);
            for (int i = 0; i < parts.Length; i++)
            {
                if (parts[i].Length == 0)
                {
                    continue;
                }

                string candidate = Path.Combine(parts[i], fileName);
                if (File.Exists(candidate))
                {
                    return Path.GetFullPath(candidate);
                }
            }
            return "";
        }

        private static string JoinArguments(List<string> args)
        {
            StringBuilder builder = new StringBuilder();
            for (int i = 0; i < args.Count; i++)
            {
                if (i > 0)
                {
                    builder.Append(' ');
                }
                builder.Append(QuoteArgument(args[i]));
            }
            return builder.ToString();
        }

        private static string QuoteArgument(string arg)
        {
            if (arg == null || arg.Length == 0)
            {
                return "\"\"";
            }

            bool needsQuotes = false;
            for (int i = 0; i < arg.Length; i++)
            {
                if (char.IsWhiteSpace(arg[i]) || arg[i] == '"')
                {
                    needsQuotes = true;
                    break;
                }
            }
            if (!needsQuotes)
            {
                return arg;
            }

            StringBuilder builder = new StringBuilder();
            builder.Append('"');
            int backslashes = 0;
            for (int i = 0; i < arg.Length; i++)
            {
                char c = arg[i];
                if (c == '\\')
                {
                    backslashes++;
                }
                else if (c == '"')
                {
                    builder.Append('\\', backslashes * 2 + 1);
                    builder.Append('"');
                    backslashes = 0;
                }
                else
                {
                    builder.Append('\\', backslashes);
                    builder.Append(c);
                    backslashes = 0;
                }
            }
            builder.Append('\\', backslashes * 2);
            builder.Append('"');
            return builder.ToString();
        }

        private static void CloseInputs(StreamWriter[] writers)
        {
            for (int i = 0; i < writers.Length; i++)
            {
                if (writers[i] == null)
                {
                    continue;
                }
                try
                {
                    writers[i].Close();
                }
                catch
                {
                }
                writers[i] = null;
            }
        }

        private static void WaitForProcesses(Process[] processes, int milliseconds)
        {
            for (int i = 0; i < processes.Length; i++)
            {
                if (processes[i] == null)
                {
                    continue;
                }
                try
                {
                    if (!processes[i].HasExited)
                    {
                        processes[i].WaitForExit(milliseconds);
                    }
                }
                catch
                {
                }
            }
        }

        private static void KillProcesses(Process[] processes)
        {
            for (int i = 0; i < processes.Length; i++)
            {
                TryKill(processes[i]);
            }
        }

        private static void TryKill(Process process)
        {
            if (process == null)
            {
                return;
            }
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(1000);
                }
            }
            catch
            {
            }
        }
    }

    private static Sample CollectSample()
    {
        QueryProcesses();

        Sample sample = new Sample();
        int offset = 0;

        while (true)
        {
            IntPtr process = Add(buffer, offset);
            uint nextEntryOffset = ReadUInt32(process, 0);
            uint numberOfThreads = ReadUInt32(process, 4);
            long pid = ReadIntPtr(process, ProcessUniquePidOffset).ToInt64();
            bool isIdleProcess = pid == 0;
            bool denyDIsh = IsDIshDenylistedProcess(process, pid);

            // (C) NextEntryOffset plausibility + snapshot-fit check.
            // If NextEntryOffset > 0, it must accommodate at least
            // the head + N thread records. If NextEntryOffset == 0
            // (last entry), the head + Threads[] array must still
            // fit in the bytes the kernel said the snapshot occupies
            // (lastReturnLength), not the larger high-water buffer.
            // Either failure means the layout interpretation is
            // wrong; refuse to walk garbage.
            uint minSize = (uint)(ProcessHeadSize + numberOfThreads * (uint)ThreadSize);
            if (nextEntryOffset != 0 && nextEntryOffset < minSize)
            {
                sample.ProcessesRejectedNextEntry++;
                throw new InvalidOperationException(
                    "NextEntryOffset (" + nextEntryOffset + ") < min(" +
                    minSize + ") for entry pid=" + pid + " with " +
                    numberOfThreads + " threads - layout drift suspected");
            }
            long bytesAvailable = (long)lastReturnLength - offset;
            if ((long)minSize > bytesAvailable)
            {
                sample.ProcessesRejectedNextEntry++;
                throw new InvalidOperationException(
                    "entry pid=" + pid + " with " + numberOfThreads +
                    " threads claims " + minSize + " bytes but only " +
                    bytesAvailable + " remain in the kernel snapshot - " +
                    "layout drift suspected");
            }

            IntPtr thread = Add(process, ProcessHeadSize);
            for (uint i = 0; i < numberOfThreads; i++)
            {
                if (!isIdleProcess)
                {
                    uint state = ReadUInt32(thread, ThreadStateOffset);
                    uint waitReason = ReadUInt32(thread, ThreadWaitReasonOffset);
                    sample.ThreadsExamined++;

                    // (B) Sanity bounds: out-of-range values indicate
                    // layout drift (or, in the worst case, a future
                    // Windows that added new enum values). Skip the
                    // thread and let the caller decide whether to abort
                    // based on the rejection rate across the sample.
                    if (state > MaxKnownThreadState || waitReason > MaxKnownWaitReason)
                    {
                        sample.ThreadsRejectedOutOfRange++;
                        thread = Add(thread, ThreadSize);
                        continue;
                    }

                    if (IsRunnableState(state))
                    {
                        sample.R++;
                    }

                    if (!denyDIsh && IsExplicitDIshWait(state, waitReason))
                    {
                        sample.DIsh++;
                    }
                    else if (!denyDIsh && IsTransitionDIshState(state))
                    {
                        sample.DIsh++;
                    }
                    else if (!denyDIsh && state == 5 && (waitReason == 0 || waitReason == 7))
                    {
                        uint tid = unchecked((uint)ReadIntPtr(thread, ThreadUniqueThreadOffset).ToInt64());
                        if (ThreadHasPendingIo(tid))
                        {
                            sample.DIsh++;
                        }
                    }
                }

                thread = Add(thread, ThreadSize);
            }

            if (nextEntryOffset == 0)
            {
                break;
            }

            offset += unchecked((int)nextEntryOffset);
        }

        return sample;
    }

    private static void QueryProcesses()
    {
        while (true)
        {
            int returnLength;
            int status = NtQuerySystemInformation(SystemProcessInformation, buffer, bufferSize, out returnLength);
            if (status == StatusSuccess)
            {
                lastReturnLength = returnLength;
                return;
            }

            if (status == StatusInfoLengthMismatch ||
                status == StatusBufferTooSmall ||
                status == StatusBufferOverflow ||
                returnLength > bufferSize)
            {
                int newSize = bufferSize * 2;
                if (returnLength > newSize)
                {
                    newSize = returnLength + (64 * 1024);
                }

                IntPtr replacement = Marshal.AllocHGlobal(newSize);
                Marshal.FreeHGlobal(buffer);
                buffer = replacement;
                bufferSize = newSize;
                continue;
            }

            throw new InvalidOperationException("NtQuerySystemInformation failed with NTSTATUS 0x" + status.ToString("X8"));
        }
    }

    private static bool IsRunnableState(uint state)
    {
        return state == 1 || state == 2 || state == 3 || state == 7;
    }

    private static bool IsTransitionDIshState(uint state)
    {
        return state == 6 || state == 9;
    }

    private static bool IsExplicitDIshWait(uint state, uint waitReason)
    {
        if (state != 5)
        {
            return false;
        }

        switch (waitReason)
        {
            case 1:  // FreePage
            case 2:  // PageIn
            case 3:  // PoolAllocation
            case 8:  // WrFreePage
            case 9:  // WrPageIn
            case 10: // WrPoolAllocation
            case 18: // WrVirtualMemory
            case 19: // WrPageOut
            case 23: // WrProcessInSwap
            case 27: // WrResource
            case 28: // WrPushLock
            case 34: // WrFastMutex
            case 35: // WrGuardedMutex
            case 36: // WrRundown
            case 39: // WrPhysicalFault
            case 41: // WrMdlCache
            case 42: // WrRcu
                return true;
            default:
                return false;
        }
    }

    private static bool IsDIshDenylistedProcess(IntPtr process, long pid)
    {
        if (pid == 4)
        {
            return true;
        }

        string name = ReadProcessImageName(process);
        if (name.Length == 0)
        {
            return false;
        }

        return EqualsIgnoreCase(name, "Registry") ||
               EqualsIgnoreCase(name, "Memory Compression") ||
               EqualsIgnoreCase(name, "smss.exe") ||
               EqualsIgnoreCase(name, "csrss.exe");
    }

    private static string ReadProcessImageName(IntPtr process)
    {
        try
        {
            int length = ReadUInt16(process, ProcessImageNameOffset);
            if (length <= 0 || length > 1024)
            {
                return "";
            }

            IntPtr text = ReadIntPtr(process, ProcessImageNameOffset + UnicodeStringBufferOffset);
            if (text == IntPtr.Zero)
            {
                return "";
            }

            string value = Marshal.PtrToStringUni(text, length / 2);
            return value == null ? "" : value;
        }
        catch
        {
            return "";
        }
    }

    private static bool ThreadHasPendingIo(uint threadId)
    {
        if (threadId == 0)
        {
            return false;
        }

        IntPtr thread = OpenThread(ThreadQueryInformation, false, threadId);
        if (thread == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            bool pending;
            if (!GetThreadIOPendingFlag(thread, out pending))
            {
                return false;
            }
            return pending;
        }
        finally
        {
            CloseHandle(thread);
        }
    }

    private static bool EqualsIgnoreCase(string left, string right)
    {
        return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    }

    private static void StartupSelfTest()
    {
        QueryProcesses();

        long expectedPid = Process.GetCurrentProcess().Id;
        uint expectedTid = GetCurrentThreadId();
        int offset = 0;
        bool foundProcess = false;

        while (true)
        {
            IntPtr process = Add(buffer, offset);
            uint nextEntryOffset = ReadUInt32(process, 0);
            uint numberOfThreads = ReadUInt32(process, 4);
            long pid = ReadIntPtr(process, ProcessUniquePidOffset).ToInt64();

            if (pid == expectedPid)
            {
                foundProcess = true;

                // Lower bound: every live process has at least one
                // thread (the one calling us, if no others). Upper
                // bound: the Threads[] array must physically fit in
                // the bytes the kernel said the snapshot occupies
                // (lastReturnLength), not the larger high-water
                // buffer allocation. We don't impose any arbitrary
                // ceiling on legitimate thread counts.
                long fitsInSnapshot =
                    ((long)lastReturnLength - offset - ProcessHeadSize) / ThreadSize;
                if (numberOfThreads < 1 || numberOfThreads > fitsInSnapshot)
                {
                    Drift("recovered NumberOfThreads=" + numberOfThreads +
                          " for our own PID (must be 1..snapshot-fit=" +
                          fitsInSnapshot + ")");
                }

                string name = ReadProcessImageName(process);
                if (name.Length == 0 ||
                    name.IndexOf("windows_load",
                        StringComparison.OrdinalIgnoreCase) < 0)
                {
                    Drift("recovered ImageName='" + name +
                          "' for our own PID (expected to contain 'windows_load')");
                }

                // Walk threads and find ourselves; check enum bounds.
                IntPtr thread = Add(process, ProcessHeadSize);
                bool foundThread = false;
                for (uint i = 0; i < numberOfThreads; i++)
                {
                    uint tid = unchecked((uint)ReadIntPtr(
                        thread, ThreadUniqueThreadOffset).ToInt64());
                    if (tid == expectedTid)
                    {
                        foundThread = true;
                        uint state = ReadUInt32(thread, ThreadStateOffset);
                        if (state > MaxKnownThreadState)
                        {
                            Drift("our own thread TID=" + tid +
                                  " has ThreadState=" + state +
                                  " (exceeds documented max " +
                                  MaxKnownThreadState + ")");
                        }
                        uint waitReason = ReadUInt32(thread, ThreadWaitReasonOffset);
                        if (waitReason > MaxKnownWaitReason)
                        {
                            Drift("our own thread WaitReason=" + waitReason +
                                  " exceeds documented max (" + MaxKnownWaitReason + ")");
                        }
                        break;
                    }
                    thread = Add(thread, ThreadSize);
                }
                if (!foundThread)
                {
                    Drift("self-walk did not find our TID=" + expectedTid +
                          " among " + numberOfThreads +
                          " threads in our own process");
                }

                break;
            }

            if (nextEntryOffset == 0)
            {
                break;
            }
            offset += unchecked((int)nextEntryOffset);
        }

        if (!foundProcess)
        {
            Drift("self-walk did not find our PID=" + expectedPid +
                  " in the process list");
        }
    }

    private static void Drift(string detail)
    {
        throw new InvalidOperationException(
            "SYSTEM_PROCESS_INFORMATION layout drift detected on Windows " +
            Environment.OSVersion.Version + "; refusing to emit samples. " +
            "Reason: " + detail);
    }

    private static IntPtr Add(IntPtr pointer, int offset)
    {
        return new IntPtr(pointer.ToInt64() + offset);
    }

    private static ushort ReadUInt16(IntPtr pointer, int offset)
    {
        return unchecked((ushort)Marshal.ReadInt16(pointer, offset));
    }

    private static uint ReadUInt32(IntPtr pointer, int offset)
    {
        return unchecked((uint)Marshal.ReadInt32(pointer, offset));
    }

    private static IntPtr ReadIntPtr(IntPtr pointer, int offset)
    {
        return Marshal.ReadIntPtr(pointer, offset);
    }
}
