[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$SessionId,

    [Parameter(Mandatory = $true)]
    [string]$PayloadBase64
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

$Utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8

$NativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

public sealed class RdpSessionLaunchResult
{
    public int ProcessId { get; private set; }
    public string UserName { get; private set; }

    public RdpSessionLaunchResult(int processId, string userName)
    {
        ProcessId = processId;
        UserName = userName;
    }
}

public static class RdpSessionLauncher
{
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    private const uint TOKEN_QUERY = 0x00000008;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x00000020;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES
    {
        public LUID Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID_AND_ATTRIBUTES Privileges;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQueryUserToken(
        uint sessionId,
        out IntPtr token
    );

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateEnvironmentBlock(
        out IntPtr environment,
        IntPtr token,
        [MarshalAs(UnmanagedType.Bool)] bool inherit
    );

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyEnvironmentBlock(IntPtr environment);

    [DllImport(
        "advapi32.dll",
        EntryPoint = "CreateProcessAsUserW",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessAsUser(
        IntPtr token,
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr process,
        uint desiredAccess,
        out IntPtr token
    );

    [DllImport(
        "advapi32.dll",
        EntryPoint = "LookupPrivilegeValueW",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LookupPrivilegeValue(
        string systemName,
        string name,
        out LUID luid
    );

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr token,
        [MarshalAs(UnmanagedType.Bool)] bool disableAllPrivileges,
        ref TOKEN_PRIVILEGES newState,
        uint bufferLength,
        IntPtr previousState,
        IntPtr returnLength
    );

    private static void EnablePrivilege(string name)
    {
        IntPtr processToken = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
                out processToken
            ))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "OpenProcessToken failed."
                );
            }

            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "LookupPrivilegeValue failed for " + name + "."
                );
            }

            TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
            privileges.PrivilegeCount = 1;
            privileges.Privileges.Luid = luid;
            privileges.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
            if (!AdjustTokenPrivileges(
                processToken,
                false,
                ref privileges,
                0,
                IntPtr.Zero,
                IntPtr.Zero
            ))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "AdjustTokenPrivileges failed for " + name + "."
                );
            }
            int error = Marshal.GetLastWin32Error();
            if (error != 0)
            {
                throw new Win32Exception(
                    error,
                    "The process token does not hold " + name + "."
                );
            }
        }
        finally
        {
            if (processToken != IntPtr.Zero)
            {
                CloseHandle(processToken);
            }
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value == null)
        {
            value = String.Empty;
        }
        if (value.Length > 0 && value.IndexOfAny(
            new char[] { ' ', '\t', '\n', '\v', '"' }
        ) < 0)
        {
            return value;
        }

        StringBuilder result = new StringBuilder();
        result.Append('"');
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                slashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', (slashes * 2) + 1);
                result.Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes);
            result.Append(character);
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static string JoinArguments(string[] arguments)
    {
        StringBuilder commandLine = new StringBuilder();
        for (int index = 0; index < arguments.Length; index++)
        {
            if (index > 0)
            {
                commandLine.Append(' ');
            }
            commandLine.Append(QuoteArgument(arguments[index]));
        }
        return commandLine.ToString();
    }

    public static RdpSessionLaunchResult Launch(
        int sessionId,
        string[] arguments
    )
    {
        if (sessionId <= 0)
        {
            throw new ArgumentOutOfRangeException("sessionId");
        }
        if (arguments == null || arguments.Length == 0)
        {
            throw new ArgumentException("A program is required.", "arguments");
        }

        IntPtr token = IntPtr.Zero;
        IntPtr environment = IntPtr.Zero;
        PROCESS_INFORMATION processInformation = new PROCESS_INFORMATION();
        try
        {
            EnablePrivilege("SeTcbPrivilege");
            EnablePrivilege("SeIncreaseQuotaPrivilege");
            EnablePrivilege("SeAssignPrimaryTokenPrivilege");

            if (!WTSQueryUserToken((uint)sessionId, out token))
            {
                int error = Marshal.GetLastWin32Error();
                string message = error == 2
                    ? "Session " + sessionId +
                        " does not exist or has no logged-on user token."
                    : "WTSQueryUserToken failed for session " + sessionId + ".";
                throw new Win32Exception(
                    error,
                    message
                );
            }

            string userName;
            using (WindowsIdentity identity = new WindowsIdentity(token))
            {
                userName = identity.Name;
            }

            if (!CreateEnvironmentBlock(out environment, token, false))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateEnvironmentBlock failed."
                );
            }

            STARTUPINFO startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startupInfo.lpDesktop = @"winsta0\default";
            StringBuilder commandLine = new StringBuilder(
                JoinArguments(arguments)
            );
            if (!CreateProcessAsUser(
                token,
                null,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                CREATE_UNICODE_ENVIRONMENT,
                environment,
                null,
                ref startupInfo,
                out processInformation
            ))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateProcessAsUser failed."
                );
            }

            return new RdpSessionLaunchResult(
                checked((int)processInformation.dwProcessId),
                userName
            );
        }
        finally
        {
            if (processInformation.hThread != IntPtr.Zero)
            {
                CloseHandle(processInformation.hThread);
            }
            if (processInformation.hProcess != IntPtr.Zero)
            {
                CloseHandle(processInformation.hProcess);
            }
            if (environment != IntPtr.Zero)
            {
                DestroyEnvironmentBlock(environment);
            }
            if (token != IntPtr.Zero)
            {
                CloseHandle(token);
            }
        }
    }
}
'@

try {
    $PayloadJson = $Utf8.GetString(
        [Convert]::FromBase64String($PayloadBase64)
    )
    $Payload = $PayloadJson | ConvertFrom-Json
    $Arguments = @($Payload.Arguments | ForEach-Object { [string]$_ })
    if ($Arguments.Count -eq 0) {
        throw 'A program is required.'
    }

    Add-Type -TypeDefinition $NativeSource -Language CSharp
    $Result = [RdpSessionLauncher]::Launch(
        $SessionId,
        [string[]]$Arguments
    )
    Write-Output (
        '[RDP] Session process started: ' +
        "session=$SessionId user=$($Result.UserName) " +
        "pid=$($Result.ProcessId) program=$($Arguments[0])"
    )
    exit 0
} catch {
    $Failure = $_.Exception
    while ($null -ne $Failure.InnerException) {
        $Failure = $Failure.InnerException
    }
    if ($Failure -is [ComponentModel.Win32Exception]) {
        [Console]::Error.WriteLine(
            "[ERROR] $($Failure.Message) [Win32=$($Failure.NativeErrorCode)]"
        )
    } else {
        [Console]::Error.WriteLine("[ERROR] $($Failure.Message)")
    }
    exit 1
}
