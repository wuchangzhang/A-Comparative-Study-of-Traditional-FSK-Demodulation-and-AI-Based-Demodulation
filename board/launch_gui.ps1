$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pythonPath = Join-Path $projectRoot '.venv\Scripts\python.exe'
Push-Location $projectRoot
try {
    $venvWorks = $false
    if (Test-Path -LiteralPath $pythonPath) {
        try {
            & $pythonPath -c 'import serial, tkinter' 2>$null
            $venvWorks = ($LASTEXITCODE -eq 0)
        } catch { $venvWorks = $false }
    }
    if ($venvWorks) { & $pythonPath (Join-Path $projectRoot 'src\host\gui.py') }
    else { & py -3.13 (Join-Path $projectRoot 'src\host\gui.py') }
    exit $LASTEXITCODE
}
finally { Pop-Location }
