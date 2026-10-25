# Builds dist\Otis-Setup.exe from the files in this repository.
# Developer-only: people who install Otis only ever see Otis-Setup.exe.
# Uses the C# compiler that ships with Windows, so nothing needs to be installed.
$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Root = Split-Path $Here -Parent
$App  = Join-Path $Root "app"
$Obj  = Join-Path $Root "obj"
$Dist = Join-Path $Root "dist"
New-Item -ItemType Directory -Force $Obj, $Dist | Out-Null

$csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "The .NET Framework C# compiler was not found." }
$version = (Get-Content (Join-Path $Here "VERSION") -Raw).Trim()
$icon = Join-Path $App "icons\agenda.ico"

Write-Host "1/4 Compiling Otis.exe"
$exe = Join-Path $Obj "Otis.exe"
if (Test-Path $exe) { Remove-Item $exe -Force }
& $csc /nologo /target:winexe /optimize+ "/win32icon:$icon" /r:System.Windows.Forms.dll "/out:$exe" (Join-Path $App "launcher.cs")
if ($LASTEXITCODE -ne 0) { throw "Compiling Otis.exe failed." }

Write-Host "2/4 Packing the app"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $Obj "payload.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$keepIcons = @("agenda.ico", "agenda-256.png")
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, "Create")
try {
    $appFull = (Resolve-Path $App).Path.TrimEnd('\')
    foreach ($f in Get-ChildItem $appFull -Recurse -File) {
        $rel = $f.FullName.Substring($appFull.Length + 1)
        if ($rel -match '^(tests|icons\\src)\\' -or $rel -eq "launcher.cs") { continue }
        if ($rel -like "icons\*" -and $keepIcons -notcontains $f.Name) { continue }
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, ("app/" + ($rel -replace '\\', '/')), "Optimal")
    }
} finally { $zip.Dispose() }

Write-Host "3/4 Writing version"
$verFile = Join-Path $Obj "version.txt"
[System.IO.File]::WriteAllText($verFile, $version)

Write-Host "4/4 Compiling Otis-Setup.exe"
$out = Join-Path $Dist "Otis-Setup.exe"
if (Test-Path $out) { Remove-Item $out -Force }
$src = Get-ChildItem (Join-Path $Here "*.cs") | ForEach-Object { $_.FullName }
& $csc /nologo /target:winexe /optimize+ "/win32icon:$icon" "/win32manifest:$(Join-Path $Here 'setup.manifest')" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Web.Extensions.dll `
    "/resource:$zipPath,payload.zip" "/resource:$exe,Otis.exe" "/resource:$verFile,version.txt" `
    "/resource:$(Join-Path $Root 'settings.example.json'),settings.example.json" "/resource:$(Join-Path $App 'icons\agenda-256.png'),logo.png" `
    "/out:$out" $src
if ($LASTEXITCODE -ne 0) { throw "Compiling Otis-Setup.exe failed." }
Write-Host ""
Write-Host "Built $out ($([math]::Round((Get-Item $out).Length / 1MB, 1)) MB, version $version)" -ForegroundColor Green
