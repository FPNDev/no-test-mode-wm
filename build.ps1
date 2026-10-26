# Builds ntmwm.dll (x64, MSVC /O2 /guard:cf, static CRT) from src\ntmwm.cpp.
# Output: ntmwm.dll in the repo root (committed, ready to run). Intermediate files go in obj\.
$ErrorActionPreference = 'Stop'

$src = "$PSScriptRoot\src"
$obj = "$PSScriptRoot\obj"
if (Test-Path $obj) {
    Remove-Item -Recurse -Force $obj
}
New-Item -ItemType Directory -Force $obj | Out-Null

# MSVC x64 environment (latest installed Windows SDK).
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) {
    throw 'MSVC x64 toolset not found'
}
foreach ($line in (cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>nul && set")) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item "env:$($Matches[1])" $Matches[2]
    }
}

cl /nologo /c /std:c++20 /permissive- /W4 /WX /O2 /EHsc /MT /Gy /Gw /guard:cf /Brepro `
    "/Fo$obj\" "$src\ntmwm.cpp"
if ($LASTEXITCODE) {
    throw 'cl failed'
}

link /nologo /DLL /guard:cf /Brepro /OPT:REF /OPT:ICF "/DEF:$src\ntmwm.def" `
    user32.lib advapi32.lib "/OUT:$PSScriptRoot\ntmwm.dll" "/IMPLIB:$obj\ntmwm.lib" "$obj\ntmwm.obj"
if ($LASTEXITCODE) {
    throw 'link failed'
}
Write-Host "Built $PSScriptRoot\ntmwm.dll ($((Get-Item "$PSScriptRoot\ntmwm.dll").Length) bytes)"
