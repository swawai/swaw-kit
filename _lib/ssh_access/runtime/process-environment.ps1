Set-StrictMode -Version 2.0

function Get-SshAccessTrustedWindowsPaths {
    $WindowsRoot = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Windows
    )
    $SystemDirectory = [Environment]::SystemDirectory
    if ([string]::IsNullOrWhiteSpace($WindowsRoot) -or
        -not [IO.Path]::IsPathRooted($WindowsRoot)) {
        throw 'The trusted Windows directory is unavailable or invalid.'
    }
    if ([string]::IsNullOrWhiteSpace($SystemDirectory) -or
        -not [IO.Path]::IsPathRooted($SystemDirectory)) {
        throw 'The trusted Windows system directory is unavailable or invalid.'
    }

    $WindowsRoot = [IO.Path]::GetFullPath($WindowsRoot)
    $SystemDirectory = [IO.Path]::GetFullPath($SystemDirectory)
    $NativeSystemDirectory = if (
        [Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess
    ) {
        [IO.Path]::Combine($WindowsRoot, 'Sysnative')
    } else {
        $SystemDirectory
    }

    return [pscustomobject]@{
        WindowsRoot           = $WindowsRoot
        SystemDirectory       = $SystemDirectory
        NativeSystemDirectory = [IO.Path]::GetFullPath($NativeSystemDirectory)
    }
}

function Initialize-SshAccessTrustedProcessEnvironment {
    if ([Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess) {
        throw (
            'SSH Access refuses to run under 32-bit PowerShell on 64-bit Windows. ' +
            'Run it through kit.cmd so the native Windows PowerShell host is selected.'
        )
    }

    $WindowsPaths = Get-SshAccessTrustedWindowsPaths
    $CommandProcessor = [IO.Path]::Combine(
        $WindowsPaths.SystemDirectory,
        'cmd.exe'
    )
    $PowerShellModules = [IO.Path]::Combine($PSHOME, 'Modules')
    if (-not [IO.File]::Exists($CommandProcessor)) {
        throw "The trusted Windows command processor was not found: $CommandProcessor"
    }
    if (-not [IO.Directory]::Exists($PowerShellModules)) {
        throw "The trusted Windows PowerShell module directory was not found: $PowerShellModules"
    }

    $env:SystemRoot = $WindowsPaths.WindowsRoot
    $env:windir = $WindowsPaths.WindowsRoot
    $env:ComSpec = [IO.Path]::GetFullPath($CommandProcessor)
    $env:PSModulePath = [IO.Path]::GetFullPath($PowerShellModules)

    return [pscustomobject]@{
        WindowsRoot     = $env:SystemRoot
        SystemDirectory = $WindowsPaths.SystemDirectory
        ComSpec         = $env:ComSpec
        PSModulePath    = $env:PSModulePath
    }
}
