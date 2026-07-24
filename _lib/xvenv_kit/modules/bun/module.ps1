Set-StrictMode -Version 2.0

@{
    Name = 'bun'
    Install = {
        param($Context, $Definition, $Plan, $Dependencies)

        $Prepare = {
            param($StagedPath)

            $BunxPath = Join-Path $StagedPath 'bunx.cmd'
            $Content = "@echo off`r`n`"%~dp0bun.exe`" x %*`r`n"
            [IO.File]::WriteAllText($BunxPath, $Content, [Text.UTF8Encoding]::new($false))
        }
        Install-XvenvArchiveDefinition `
            -Context $Context `
            -Definition $Definition `
            -Prepare $Prepare
    }
    Validate = {
        param($Context, $Definition, $InstallRoot)

        $BunxPath = Join-Path $InstallRoot 'bunx.cmd'
        return [IO.File]::Exists($BunxPath) -and
            (Get-Item -LiteralPath $BunxPath).Length -gt 0
    }
    ContributeEnvironment = {
        param($Context, $Definition, $Plan, $Dependencies)

        $InstallRoot = Get-XvenvInstallRoot -Context $Context -Definition $Definition
        Set-XvenvPlanVariable $Plan 'XVENV_BUN_HOME' $InstallRoot
        Add-XvenvPlanPath $Plan $InstallRoot
    }
}
