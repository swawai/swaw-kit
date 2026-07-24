@{
    Schema = 'xvenv.module.v1'
    Name = 'python'
    Public = $true
    Order = 30
    Version = '3.13'
    RequiredPaths = @(
        '.venv\Scripts\python.exe',
        '.venv\pyvenv.cfg'
    )
    Requires = @('uv')
}
