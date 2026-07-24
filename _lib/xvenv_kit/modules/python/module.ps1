Set-StrictMode -Version 2.0

@{
    Name = 'python'
    Install = {
        param($Context, $Definition, $Plan, $Dependencies)

        $UvDefinition = $Dependencies['uv']
        if (-not (Test-XvenvDefinitionInstalled `
            -Context $Context `
            -Definition $UvDefinition)) {
            throw "Python requires uv $($UvDefinition.Version), but it is not installed."
        }
        $Build = {
            param($Target)

            $UvRoot = Get-XvenvInstallRoot -Context $Context -Definition $UvDefinition
            $UvExe = Join-Path $UvRoot 'uv.exe'
            $VenvPath = Join-Path $Target '.venv'
            $UvCache = Join-Path $Context.ProjectDataRoot 'cache\uv'
            $UvPython = Join-Path $Context.ProjectDataRoot 'work\uv\python'
            [void][IO.Directory]::CreateDirectory($UvCache)
            [void][IO.Directory]::CreateDirectory($UvPython)

            $Environment = @{
                UV_CACHE_DIR = $UvCache
                UV_PYTHON_INSTALL_DIR = $UvPython
                UV_MANAGED_PYTHON = 'true'
                UV_NO_CONFIG = 'true'
                VIRTUAL_ENV = ''
                CONDA_PREFIX = ''
                PYTHONHOME = ''
            }
            $ExitCode = Invoke-XvenvExternal `
                -Context $Context `
                -FilePath $UvExe `
                -Arguments @('venv', $VenvPath, '--python', [string]$Definition.Version) `
                -Environment $Environment
            if ($ExitCode -ne 0) {
                throw "uv exited with code $ExitCode while creating Python $($Definition.Version)."
            }
        }.GetNewClosure()
        Install-XvenvCustomDefinition `
            -Context $Context `
            -Definition $Definition `
            -Activity "Creating Python $($Definition.Version) environment" `
            -Build $Build
    }
    Validate = {
        param($Context, $Definition, $InstallRoot)

        $ConfigPath = Join-Path $InstallRoot '.venv\pyvenv.cfg'
        if (-not [IO.File]::Exists($ConfigPath)) {
            return $false
        }
        $Content = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $HomeMatch = [regex]::Match($Content, '(?im)^home\s*=\s*(.+?)\s*$')
        $VersionMatch = [regex]::Match($Content, '(?im)^version_info\s*=\s*(.+?)\s*$')
        if (-not $HomeMatch.Success -or -not $VersionMatch.Success) {
            return $false
        }

        try {
            $PythonHome = Get-XvenvFullPath $HomeMatch.Groups[1].Value
            $ManagedPythonRoot = Get-XvenvFullPath (Join-Path $Context.ProjectDataRoot 'work\uv\python')
        } catch {
            return $false
        }
        $ManagedPrefix = $ManagedPythonRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $PythonHome.StartsWith($ManagedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $BasePython = Join-Path $PythonHome 'python.exe'
        if (-not [IO.File]::Exists($BasePython) -or
            (Get-Item -LiteralPath $BasePython).Length -le 0) {
            return $false
        }

        $ActualVersion = $VersionMatch.Groups[1].Value
        $RequestedVersion = [string]$Definition.Version
        return $ActualVersion -eq $RequestedVersion -or
            $ActualVersion.StartsWith("$RequestedVersion.")
    }
    ContributeEnvironment = {
        param($Context, $Definition, $Plan, $Dependencies)

        $InstallRoot = Get-XvenvInstallRoot -Context $Context -Definition $Definition
        $UvDefinition = $Dependencies.uv
        $UvRoot = Get-XvenvInstallRoot -Context $Context -Definition $UvDefinition
        $Venv = Join-Path $InstallRoot '.venv'
        $UvCache = Join-Path $Context.ProjectDataRoot 'cache\uv'
        $UvPython = Join-Path $Context.ProjectDataRoot 'work\uv\python'

        foreach ($Name in @(
            'VIRTUAL_ENV_DISABLE_PROMPT',
            '_OLD_VIRTUAL_PATH',
            '_OLD_VIRTUAL_PROMPT',
            '_OLD_VIRTUAL_PYTHONHOME',
            'CONDA_PREFIX',
            'CONDA_DEFAULT_ENV',
            'CONDA_SHLVL',
            'CONDA_PROMPT_MODIFIER',
            'PYTHONHOME'
        )) {
            Set-XvenvPlanVariable $Plan $Name $null
        }

        Set-XvenvPlanVariable $Plan 'XVENV_UV_HOME' $UvRoot
        Set-XvenvPlanVariable $Plan 'UV_PROJECT_ENVIRONMENT' $Venv
        Set-XvenvPlanVariable $Plan 'UV_CACHE_DIR' $UvCache
        Set-XvenvPlanVariable $Plan 'UV_PYTHON_INSTALL_DIR' $UvPython
        Set-XvenvPlanVariable $Plan 'VIRTUAL_ENV' $Venv
        Set-XvenvPlanVariable $Plan 'VIRTUAL_ENV_PROMPT' '(.venv) '
        Add-XvenvPlanPath $Plan $UvRoot
        Add-XvenvPlanPath $Plan (Join-Path $Venv 'Scripts')
    }
}
