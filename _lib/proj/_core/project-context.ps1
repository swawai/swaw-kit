Set-StrictMode -Version 2.0

$script:ProjRequiredProjectDeclarations = @(
    'SWAWKIT_PROJ_TARGET_PROJECT_ROOT',
    'SWAWKIT_PROJ_ACTION_ROOT',
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
    param([Parameter(Mandatory = $true)][string]$ProjHome)

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

    $ProjectRoot = Get-ProjDeclaredFullPath `
        -Value $Declarations['SWAWKIT_PROJ_TARGET_PROJECT_ROOT'] `
        -Name 'SWAWKIT_PROJ_TARGET_PROJECT_ROOT'
    if (-not [IO.Directory]::Exists($ProjectRoot)) {
        throw "Declared project directory does not exist: $ProjectRoot"
    }

    $ActionRoot = Get-ProjDeclaredFullPath `
        -Value $Declarations['SWAWKIT_PROJ_ACTION_ROOT'] `
        -Name 'SWAWKIT_PROJ_ACTION_ROOT'
    $EntryFile = Get-ProjDeclaredFullPath `
        -Value $Declarations['SWAWKIT_PROJ_ENTRY_FILE'] `
        -Name 'SWAWKIT_PROJ_ENTRY_FILE'
    if (-not [IO.File]::Exists($EntryFile)) {
        throw "Declared project entry file does not exist: $EntryFile"
    }
    $EntryName = [IO.Path]::GetFileNameWithoutExtension($EntryFile)
    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        throw "The project entry file has no usable entry name: $EntryFile"
    }
    $CanonicalProjHome = Get-ProjDeclaredFullPath `
        -Value $ProjHome `
        -Name 'SWAWKIT_HOME'
    if (-not [IO.Directory]::Exists($CanonicalProjHome)) {
        throw "Declared Swaw Kit Proj home does not exist: $CanonicalProjHome"
    }
    $DataRoot = Resolve-ProjProjectDataRoot `
        -ProjHome $CanonicalProjHome `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $EntryFile

    return [pscustomobject]@{
        Protocol = '1'
        ProjHome = $CanonicalProjHome
        ProjectRoot = $ProjectRoot
        ActionRoot = $ActionRoot
        DataRoot = $DataRoot
        EntryName = $EntryName
        EntryFile = $EntryFile
    }
}
