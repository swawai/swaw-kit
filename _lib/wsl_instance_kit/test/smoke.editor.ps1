function Test-WslEditorLaunchContract {
    . (Join-Path $kitRoot "lib\common.ps1")
    . (Join-Path $kitRoot "lib\config.ps1")
    . (Join-Path $kitRoot "lib\editor.ps1")

    $previousConfig = $script:Config
    $previousParseMode = $env:WSL_KIT_PARSE_ENTRY_FILE
    $previousArgsReady = $env:WSL_KIT_ARGS_READY
    try {
        $script:Config = [pscustomobject]@{
            Protocol      = "2"
            EntryFileName = "wsl01.cmd"
        }
        $env:WSL_KIT_PARSE_ENTRY_FILE = "1"
        Assert-True `
            ((Open-Editor "code" @()) -eq 1) `
            "kit --entry-file must not bypass the clean editor bootstrap"

        Remove-Item Env:WSL_KIT_PARSE_ENTRY_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:WSL_KIT_ARGS_READY -ErrorAction SilentlyContinue
        Assert-True `
            ((Open-Editor "code" @()) -eq 1) `
            "calling the internal kit directly must not bypass the clean editor bootstrap"

        $env:WSL_KIT_ARGS_READY = "1"
        $script:Config.Protocol = "1"
        Assert-True `
            ((Open-Editor "code" @()) -eq 1) `
            "a protocol 1 WSL entry without the clean bootstrap must fail closed"
    } finally {
        $script:Config = $previousConfig
        if ($null -eq $previousParseMode) {
            Remove-Item Env:WSL_KIT_PARSE_ENTRY_FILE -ErrorAction SilentlyContinue
        } else {
            $env:WSL_KIT_PARSE_ENTRY_FILE = $previousParseMode
        }
        if ($null -eq $previousArgsReady) {
            Remove-Item Env:WSL_KIT_ARGS_READY -ErrorAction SilentlyContinue
        } else {
            $env:WSL_KIT_ARGS_READY = $previousArgsReady
        }
    }

    Assert-ArrayEqual `
        @(Get-WslEditorLaunchArguments `
            -Editor "code" `
            -RemoteAuthority "wsl+wsl01" `
            -TargetPath "/home/john/project") `
        @("--remote=wsl+wsl01", "/home/john/project") `
        "existing VS Code remote launch"

    Assert-ArrayEqual `
        @(Get-WslEditorLaunchArguments `
            -Editor "code" `
            -RemoteAuthority "wsl+wsl01" `
            -TargetPath "/home/john/project" `
            -ReuseBootstrapWindow) `
        @("--reuse-window", "--remote=wsl+wsl01", "/home/john/project") `
        "bootstrapped VS Code remote launch"

    Assert-ArrayEqual `
        @(Get-WslEditorLaunchArguments `
            -Editor "cursor" `
            -RemoteAuthority "wsl+wsl01" `
            -TargetPath "/home/john/project") `
        @("--classic", "--remote=wsl+wsl01", "/home/john/project") `
        "existing Cursor classic remote launch"

    Assert-ArrayEqual `
        @(Get-WslEditorLaunchArguments `
            -Editor "cursor" `
            -RemoteAuthority "wsl+wsl01" `
            -TargetPath "/home/john/project" `
            -ReuseBootstrapWindow) `
        @("--classic", "--reuse-window", "--remote=wsl+wsl01", "/home/john/project") `
        "bootstrapped Cursor classic remote launch"
}
