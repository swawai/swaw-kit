[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('create', 'info', 'prompt', 'help')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$EntryFile,

    [AllowEmptyString()]
    [string]$Project = '',

    [string]$CommandName = 'rdp'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'project-core.ps1')

function Write-RdpClientProjectHelp {
    Write-Output 'RDP execution projects'
    Write-Output "  $CommandName .project create <name|absolute-path>"
    Write-Output "  $CommandName .project info [name|absolute-path]"
    Write-Output "  $CommandName .project prompt [name|absolute-path]"
    Write-Output "  $CommandName .<session-id> exec <name|absolute-path> [--display] [--timeout <seconds>] [-- <script-args...>]"
    Write-Output ''
    Write-Output 'A bare name uses this entry''s local managed projects directory.'
    Write-Output 'Any path must be absolute; relative paths are rejected.'
    Write-Output 'Each project has one fixed entry point: run.ps1.'
}

function Get-RdpClientProjectScaffold {
    return @'
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# This script runs as the user signed in to the selected RDP session.
# Put every artifact to return to the client under RDP_EXEC_OUTPUT_DIR.
# Other context: RDP_EXEC_SESSION_ID and RDP_EXEC_WORK_DIR.
if ([string]::IsNullOrWhiteSpace($env:RDP_EXEC_OUTPUT_DIR)) {
    throw 'RDP_EXEC_OUTPUT_DIR is unavailable. Run this project with rdp exec.'
}

$OutputDirectory = [IO.Path]::GetFullPath($env:RDP_EXEC_OUTPUT_DIR)
Write-Host "RDP project started in session $env:RDP_EXEC_SESSION_ID"

# Add the bounded GUI automation or other task here.
# Example: [IO.File]::WriteAllText((Join-Path $OutputDirectory 'result.txt'), 'done')
'@
}

try {
    $ResolvedEntry = [IO.Path]::GetFullPath($EntryFile)
    $ManagedRoot = Get-RdpClientManagedProjectRoot -EntryFile $ResolvedEntry
    $RunRoot = Get-RdpClientRunRoot -EntryFile $ResolvedEntry

    if ($Action -eq 'help') {
        if (-not [string]::IsNullOrWhiteSpace($Project)) {
            throw '.project --help does not accept a project.'
        }
        Write-RdpClientProjectHelp
        exit 0
    }

    if ($Action -eq 'create') {
        $Resolved = Resolve-RdpClientProject `
            -EntryFile $ResolvedEntry `
            -Value $Project
        if ($Resolved.Exists -or $Resolved.FileExists) {
            throw "RDP execution project already exists: $($Resolved.Path)"
        }
        $Created = $false
        try {
            [IO.Directory]::CreateDirectory($Resolved.Path) | Out-Null
            $Created = $true
            [IO.File]::WriteAllText(
                $Resolved.EntryPoint,
                (Get-RdpClientProjectScaffold),
                (New-Object Text.UTF8Encoding($false))
            )
        } catch {
            if ($Created -and [IO.Directory]::Exists($Resolved.Path)) {
                [IO.Directory]::Delete($Resolved.Path, $true)
            }
            throw
        }
        Write-Output "[RDP] Project created: $($Resolved.Path)"
        Write-Output "[RDP] Edit:            $($Resolved.EntryPoint)"
        Write-Output "[RDP] Run:             $CommandName .2 exec `"$($Resolved.Path)`" --display"
        exit 0
    }

    if ($Action -eq 'info' -and [string]::IsNullOrWhiteSpace($Project)) {
        Write-Output '[RDP] Execution projects'
        Write-Output "  Managed projects: $ManagedRoot"
        Write-Output "  Collected runs:    $RunRoot"
        Write-Output '  Entry point:       run.ps1'
        Write-Output '  Git tracking:      data\ is local and ignored by this repository'
        Write-Output "  Create:            $CommandName .project create <name|absolute-path>"
        Write-Output "  Execute:           $CommandName .2 exec <name|absolute-path> --display"
        Write-Output '  Projects:'
        $Directories = @(
            if ([IO.Directory]::Exists($ManagedRoot)) {
                Get-ChildItem -LiteralPath $ManagedRoot -Directory |
                    Sort-Object Name
            }
        )
        if ($Directories.Count -eq 0) {
            Write-Output '    <none>'
        } else {
            foreach ($Directory in $Directories) {
                $State = if ([IO.File]::Exists(
                    (Join-Path $Directory.FullName 'run.ps1')
                )) { 'READY' } else { 'INVALID: run.ps1 missing' }
                Write-Output "    $($Directory.Name)  [$State]"
            }
        }
        exit 0
    }

    if ($Action -eq 'info') {
        $Resolved = Resolve-RdpClientProject `
            -EntryFile $ResolvedEntry `
            -Value $Project
        Write-Output '[RDP] Execution project'
        Write-Output "  Name:        $($Resolved.Name)"
        Write-Output "  Kind:        $($Resolved.Kind)"
        Write-Output "  Path:        $($Resolved.Path)"
        Write-Output "  Entry point: $($Resolved.EntryPoint)"
        Write-Output "  State:       $(if ($Resolved.Ready) { 'READY' } elseif ($Resolved.Exists) { 'INVALID: run.ps1 missing' } else { 'ABSENT' })"
        $ProjectRunRoot = Join-Path $RunRoot ($Resolved.Name -replace '[^A-Za-z0-9._-]', '_')
        $LastRun = if ([IO.Directory]::Exists($ProjectRunRoot)) {
            Get-ChildItem -LiteralPath $ProjectRunRoot -Directory |
                Sort-Object Name -Descending | Select-Object -First 1
        } else { $null }
        Write-Output "  Last run:    $(if ($null -eq $LastRun) { '<none>' } else { $LastRun.FullName })"
        exit 0
    }

    $ResolvedProject = $null
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
        $ResolvedProject = Resolve-RdpClientProject `
            -EntryFile $ResolvedEntry `
            -Value $Project
    }
    Write-Output 'Give this repository to a coding agent and use the following context:'
    Write-Output ''
    Write-Output "- RDP entry command: $CommandName"
    Write-Output "- Managed project directory: $ManagedRoot"
    Write-Output "- Collected run directory: $RunRoot"
    Write-Output '- A project is a directory with the fixed PowerShell entry point run.ps1.'
    Write-Output '- The script runs as the selected interactive-session user.'
    Write-Output '- Write all returned files under $env:RDP_EXEC_OUTPUT_DIR.'
    Write-Output '- Do not return or print an artifact path; stdout and stderr are logs.'
    if ($null -ne $ResolvedProject) {
        Write-Output "- Project path: $($ResolvedProject.Path)"
        Write-Output "- Edit: $($ResolvedProject.EntryPoint)"
        Write-Output "- Execute: $CommandName .2 exec `"$($ResolvedProject.Path)`" --display --timeout 60s"
    } else {
        Write-Output "- Create: $CommandName .project create <name|absolute-path>"
        Write-Output "- Execute: $CommandName .2 exec <name|absolute-path> --display --timeout 60s"
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    [Console]::Error.WriteLine(
        "[ERROR] Run `"$CommandName .project --help`" for usage."
    )
    exit 1
}
