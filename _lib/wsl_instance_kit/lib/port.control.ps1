function Invoke-PortControl {
    param([string[]]$Rest)

    if ($Rest.Count -eq 0 -or $Rest[0] -in @("-h", "--help", "/?", "help")) {
        return Show-WslPortUsage
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)

    switch ($action) {
        "status" {
            return Show-WslPortStatus $tail
        }
        "doctor" {
            return Show-WslPortStatus $tail
        }
        "expose" {
            return Add-WslPortExposure $tail
        }
        "remove" {
            return Remove-WslPortExposure $tail
        }
        "sync" {
            return Sync-WslPortExposure $tail
        }
        default {
            Write-Fail "Unknown control command: port $action"
            [void](Show-WslPortUsage)
            return 1
        }
    }
}
