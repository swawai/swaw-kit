Set-StrictMode -Version 2.0

@{
    Name = 'go'
    Install = {
        param($Context, $Definition, $Plan, $Dependencies)

        Install-XvenvArchiveDefinition -Context $Context -Definition $Definition
    }
    ContributeEnvironment = {
        param($Context, $Definition, $Plan, $Dependencies)

        $InstallRoot = Get-XvenvInstallRoot -Context $Context -Definition $Definition
        $GoPath = Join-Path $Context.ProjectDataRoot 'work\go\gopath'
        $GoCache = Join-Path $Context.ProjectDataRoot 'cache\go\build'
        [void][IO.Directory]::CreateDirectory($GoPath)
        [void][IO.Directory]::CreateDirectory($GoCache)

        Set-XvenvPlanVariable $Plan 'XVENV_GO_HOME' $InstallRoot
        Set-XvenvPlanVariable $Plan 'GOROOT' $InstallRoot
        Set-XvenvPlanVariable $Plan 'GOPATH' $GoPath
        Set-XvenvPlanVariable $Plan 'GOCACHE' $GoCache
        Add-XvenvPlanPath $Plan (Join-Path $InstallRoot 'bin')
        Add-XvenvPlanPath $Plan (Join-Path $GoPath 'bin')
    }
}
