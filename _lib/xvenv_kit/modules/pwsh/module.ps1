Set-StrictMode -Version 2.0

@{
    Name = 'pwsh'
    Install = {
        param($Context, $Definition, $Plan, $Dependencies)

        Install-XvenvArchiveDefinition -Context $Context -Definition $Definition
    }
    ContributeEnvironment = {
        param($Context, $Definition, $Plan, $Dependencies)

        $InstallRoot = Get-XvenvInstallRoot -Context $Context -Definition $Definition
        Set-XvenvPlanVariable $Plan 'XVENV_PWSH_HOME' $InstallRoot
        Add-XvenvPlanPath $Plan $InstallRoot
        Set-XvenvPlanShell `
            -Plan $Plan `
            -Kind 'pwsh' `
            -Executable (Join-Path $InstallRoot 'pwsh.exe')
    }
}
