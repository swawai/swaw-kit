Set-StrictMode -Version 2.0

$script:ProjRequiredProjectDeclarations = @(
    'SWAWKIT_PROJ_ID',
    'SWAWKIT_PROJ_DIR',
    'SWAWKIT_PROJ_ACTION_ROOT',
    'SWAWKIT_PROJ_DATA_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND',
    'SWAWKIT_PROJ_ENTRY_FILE'
)

function Get-ProjRequiredProjectDeclaration {
    param([Parameter(Mandatory = $true)][string]$Name)

    $Value = [Environment]::GetEnvironmentVariable(
        $Name,
        [EnvironmentVariableTarget]::Process
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required project declaration is missing: $Name"
    }
    return [string]$Value
}

function Get-ProjDeclaredFullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not [IO.Path]::IsPathRooted($Value)) {
        throw "Project path declaration $Name must be absolute: $Value"
    }

    try {
        $FullPath = [IO.Path]::GetFullPath($Value)
    } catch {
        throw "Invalid project path declaration $Name='$Value': $($_.Exception.Message)"
    }

    $PathRoot = [IO.Path]::GetPathRoot($FullPath)
    if ($FullPath.Length -gt $PathRoot.Length) {
        $FullPath = $FullPath.TrimEnd([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ))
    }
    return $FullPath
}

function Get-ProjProjectContext {
    $Protocol = [Environment]::GetEnvironmentVariable(
        'SWAWKIT_PROJ_PROTOCOL',
        [EnvironmentVariableTarget]::Process
    )
    if ([string]$Protocol -cne '1') {
        throw 'Unsupported or missing SWAWKIT_PROJ_PROTOCOL. Expected protocol version 1.'
    }

    $Declarations = @{}
    foreach ($Name in [string[]]$script:ProjRequiredProjectDeclarations) {
        $Declarations[$Name] = Get-ProjRequiredProjectDeclaration -Name $Name
    }

    $ProjectId = $Declarations['SWAWKIT_PROJ_ID']
    if ($ProjectId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw "Invalid SWAWKIT_PROJ_ID '$ProjectId'."
    }

    $ProjectRoot = Get-ProjDeclaredFullPath `
        -Value $Declarations['SWAWKIT_PROJ_DIR'] `
        -Name 'SWAWKIT_PROJ_DIR'
    if (-not [IO.Directory]::Exists($ProjectRoot)) {
        throw "Declared project directory does not exist: $ProjectRoot"
    }

    $ActionRoot = Get-ProjDeclaredFullPath `
        -Value $Declarations['SWAWKIT_PROJ_ACTION_ROOT'] `
        -Name 'SWAWKIT_PROJ_ACTION_ROOT'
    $DataRoot = Get-ProjDeclaredFullPath `
        -Value $Declarations['SWAWKIT_PROJ_DATA_ROOT'] `
        -Name 'SWAWKIT_PROJ_DATA_ROOT'
    $EntryFile = Get-ProjDeclaredFullPath `
        -Value $Declarations['SWAWKIT_PROJ_ENTRY_FILE'] `
        -Name 'SWAWKIT_PROJ_ENTRY_FILE'
    if (-not [IO.File]::Exists($EntryFile)) {
        throw "Declared project entry file does not exist: $EntryFile"
    }

    return [pscustomobject]@{
        Protocol = '1'
        ProjectId = $ProjectId
        ProjectRoot = $ProjectRoot
        ActionRoot = $ActionRoot
        DataRoot = $DataRoot
        EntryCommand = $Declarations['SWAWKIT_PROJ_ENTRY_COMMAND']
        EntryFile = $EntryFile
    }
}
