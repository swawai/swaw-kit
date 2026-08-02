[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EntryFile,
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'install', 'remove', 'cleanup')]
    [string]$Action,
    [AllowEmptyString()][string]$HostAlias = '',
    [string]$CommandName = 'rdp',
    [switch]$Uac,
    [switch]$DryRun,
    [switch]$Elevated,
    [switch]$Pause,
    [string]$HostsPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'entry.ps1')
. (Join-Path $PSScriptRoot 'text-file.ps1')
. (Join-Path $PSScriptRoot 'hosts-core.ps1')

function Test-RdpClientAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
        return $Principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    } finally {
        if ($null -ne $Identity) {
            $Identity.Dispose()
        }
    }
}

function Get-RdpClientNativeSystemDirectory {
    $WindowsDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Windows
    )
    if ([Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess) {
        return Join-Path $WindowsDirectory 'Sysnative'
    }
    return Join-Path $WindowsDirectory 'System32'
}

function Get-RdpClientSystemHostsPath {
    return Join-Path `
        (Get-RdpClientNativeSystemDirectory) `
        'drivers\etc\hosts'
}

function ConvertTo-RdpClientQuotedArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-RdpClientHostsElevated {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedEntry,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ResolvedAlias
    )

    $PowerShellPath = Join-Path `
        (Get-RdpClientNativeSystemDirectory) `
        'WindowsPowerShell\v1.0\powershell.exe'
    if (-not [IO.File]::Exists($PowerShellPath)) {
        throw "Native Windows PowerShell not found: $PowerShellPath"
    }

    $Arguments = [string]::Join(' ', [string[]]@(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy Bypass',
        '-File ' + (ConvertTo-RdpClientQuotedArgument $PSCommandPath),
        '-EntryFile ' + (ConvertTo-RdpClientQuotedArgument $ResolvedEntry),
        '-Action ' + $Action,
        '-HostAlias ' + (ConvertTo-RdpClientQuotedArgument $ResolvedAlias),
        '-CommandName ' + (ConvertTo-RdpClientQuotedArgument $CommandName),
        '-Elevated',
        '-Pause'
    ))

    Write-Host '[RDP] Requesting administrator approval for:'
    Write-Host "  $CommandName .hosts $Action --uac"
    try {
        $Process = Start-Process `
            -FilePath $PowerShellPath `
            -Verb RunAs `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru
    } catch {
        throw "Elevation was cancelled or failed. $($_.Exception.Message)"
    }
    if ($null -eq $Process -or $null -eq $Process.ExitCode) {
        throw 'The elevated hosts process did not return an exit code.'
    }
    return [int]$Process.ExitCode
}

function Clear-RdpClientDnsCache {
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Host '[RDP] Cleared the Windows DNS client cache.'
    } catch {
        Write-Warning "Hosts changed, but the DNS client cache could not be cleared: $($_.Exception.Message)"
    }
}

$ExitCode = 0
try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom

    $ResolvedEntry = [IO.Path]::GetFullPath($EntryFile)
    $ResolvedAlias = Resolve-RdpClientHostAlias -Value $HostAlias
    $UseSystemHosts = [string]::IsNullOrWhiteSpace($HostsPath)
    $ResolvedHostsPath = if ($UseSystemHosts) {
        Get-RdpClientSystemHostsPath
    } else {
        [IO.Path]::GetFullPath($HostsPath)
    }

    if ($Elevated -and $UseSystemHosts -and
        -not (Test-RdpClientAdministrator)) {
        throw 'The elevated hosts process does not have administrator privileges.'
    }
    $File = Read-RdpClientTextFile -Path $ResolvedHostsPath
    $OrphanedEntries = @(
        Get-RdpClientOrphanedHostsEntries -Lines $File.Lines
    )

    if ($Action -eq 'cleanup') {
        Write-Host $(if ($DryRun) {
            '[RDP] Hosts cleanup --dry-run'
        } else {
            '[RDP] Hosts cleanup'
        })
        Write-Host "  File:         $ResolvedHostsPath"
        Write-Host "  Orphaned:     $($OrphanedEntries.Count)"
        foreach ($Orphan in $OrphanedEntries) {
            Write-Host "  REMOVE line $($Orphan.Index + 1): $($Orphan.Alias) <- $($Orphan.EntryFile)"
        }
        if ($OrphanedEntries.Count -eq 0) {
            Write-Host '[RDP] No orphaned managed hosts mappings found.'
        } elseif ($DryRun) {
            Write-Host '[RDP] Dry run: no hosts entries were changed.'
        } elseif ($UseSystemHosts -and -not (Test-RdpClientAdministrator)) {
            if (-not $Uac) {
                throw "Administrator privileges are required. Run: $CommandName .hosts cleanup --uac"
            }
            $ElevatedExitCode = Invoke-RdpClientHostsElevated `
                -ResolvedEntry $ResolvedEntry `
                -ResolvedAlias $ResolvedAlias
            if ($ElevatedExitCode -ne 0) {
                throw "The elevated hosts command failed with exit code $ElevatedExitCode."
            }
            Write-Host '[RDP] Elevated hosts command completed.'
        } else {
            $NewLines = Remove-RdpClientHostsLines `
                -Lines $File.Lines `
                -Indexes @($OrphanedEntries | ForEach-Object Index)
            $NewText = [string]::Join($File.NewLine, $NewLines)
            Write-RdpClientTextFileAtomic `
                -Path $ResolvedHostsPath `
                -Text $NewText `
                -Encoding $File.Encoding
            Write-Host "[RDP] Removed $($OrphanedEntries.Count) orphaned managed hosts mapping(s)."
            if ($UseSystemHosts) {
                Clear-RdpClientDnsCache
            }
        }
    } elseif ($ResolvedAlias.Length -eq 0) {
        if ($Action -eq 'status') {
            Write-Host '[RDP] Hosts state: Disabled (RDP_HOST_ALIAS is empty)'
            Write-Host "[RDP] Orphaned managed mappings: $($OrphanedEntries.Count)"
        } else {
            throw "RDP_HOST_ALIAS is empty; .hosts $Action cannot identify a managed mapping."
        }
    } else {
        $Document = Read-RdpClientEntryDocument -Path $ResolvedEntry
        $RealAddress = $null
        $null = [Net.IPAddress]::TryParse(
            $Document.FullAddress.Host,
            [ref]$RealAddress
        )
        $State = Get-RdpClientHostsState `
            -Lines $File.Lines `
            -Alias $ResolvedAlias `
            -EntryFile $ResolvedEntry `
            -DesiredAddress $RealAddress

        if ($Action -eq 'status') {
            Write-Host '[RDP] Hosts status'
            Write-Host "  File:         $ResolvedHostsPath"
            Write-Host "  Alias:        $ResolvedAlias"
            Write-Host "  Entry file:   $ResolvedEntry"
            Write-Host "  Real address: $($Document.FullAddress.Host)"
            Write-Host "  State:        $($State.Name)"
            Write-Host "  Orphaned:     $($OrphanedEntries.Count) (run $CommandName .hosts cleanup)"
            if ($State.ProblemLines.Count -gt 0) {
                $LineNumbers = @($State.ProblemLines | ForEach-Object { $_ + 1 })
                Write-Host "  Lines:        $($LineNumbers -join ', ')"
            }
        } else {
            $NeedsMutation = $false
            if ($Action -eq 'install') {
                if ($null -eq $RealAddress) {
                    throw 'The source full address must use an IP address for hosts installation; hosts cannot map an alias to another host name.'
                }
                if ($State.Name -eq 'Conflict') {
                    $LineNumbers = @($State.ProblemLines | ForEach-Object { $_ + 1 })
                    throw "The alias has conflicting hosts entries at line(s): $($LineNumbers -join ', ')."
                }
                if ($State.Name -eq 'Ready') {
                    Write-Host '[RDP] Hosts mapping is already ready.'
                } elseif ($State.Name -eq 'External') {
                    Write-Host '[RDP] An equivalent unowned hosts mapping already exists; left unchanged.'
                } else {
                    $NeedsMutation = $true
                }
            } elseif ($State.OwnedIndexes.Count -eq 0) {
                Write-Host '[RDP] No managed hosts mapping found; left unowned entries unchanged.'
            } else {
                $NeedsMutation = $true
            }

            if ($NeedsMutation -and $UseSystemHosts -and
                -not (Test-RdpClientAdministrator)) {
                if (-not $Uac) {
                    throw "Administrator privileges are required. Run: $CommandName .hosts $Action --uac"
                }
                $ElevatedExitCode = Invoke-RdpClientHostsElevated `
                    -ResolvedEntry $ResolvedEntry `
                    -ResolvedAlias $ResolvedAlias
                if ($ElevatedExitCode -ne 0) {
                    throw "The elevated hosts command failed with exit code $ElevatedExitCode."
                }
                Write-Host '[RDP] Elevated hosts command completed.'
            } elseif ($NeedsMutation) {
                $NewLines = if ($Action -eq 'install') {
                    if ($State.Name -eq 'Drifted') {
                        $Copy = [string[]]@($File.Lines.Clone())
                        $Copy[$State.OwnedIndexes[0]] = $State.DesiredLine
                        $Copy
                    } else {
                        Add-RdpClientHostsLine `
                            -Lines $File.Lines `
                            -Line $State.DesiredLine
                    }
                } else {
                    Remove-RdpClientHostsLines `
                        -Lines $File.Lines `
                        -Indexes $State.OwnedIndexes
                }
                $NewText = [string]::Join($File.NewLine, $NewLines)
                Write-RdpClientTextFileAtomic `
                    -Path $ResolvedHostsPath `
                    -Text $NewText `
                    -Encoding $File.Encoding
                if ($Action -eq 'install') {
                    Write-Host "[RDP] Installed hosts mapping: $($State.DesiredLine)"
                } else {
                    Write-Host "[RDP] Removed $($State.OwnedIndexes.Count) managed hosts mapping(s)."
                }
                if ($UseSystemHosts) {
                    Clear-RdpClientDnsCache
                }
            }
        }
    }
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    $ExitCode = 1
}

if ($Pause) {
    Write-Host ''
    [void](Read-Host 'Press Enter to close')
}
exit $ExitCode
