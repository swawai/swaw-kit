@{
    Schema = 'xvenv.module.v1'
    Name = 'go'
    Public = $true
    Order = 40
    Version = '1.22.4'
    Url = 'https://go.dev/dl/go1.22.4.windows-amd64.zip'
    UrlTemplate = 'https://go.dev/dl/go{version}.windows-amd64.zip'
    Hashes = @{
        '1.22.4' = '26321c4d945a0035d8a5bc4a1965b0df401ff8ceac66ce2daadabf9030419a98'
    }
    ArchiveSubdir = 'go'
    RequiredPaths = @('bin\go.exe')
    Requires = @()
}
