# Creates android/key.properties and android/app/upload-keystore.jks.
# Re-running keeps the existing keystore so release builds stay on one key.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$propertiesPath = Join-Path $root "android\key.properties"
$keystorePath = Join-Path $root "android\app\upload-keystore.jks"

if (Test-Path $propertiesPath) {
    Write-Host "Release signing already exists at $propertiesPath"
    exit 0
}

if (Test-Path $keystorePath) {
    throw "Keystore exists without key.properties. Refusing to replace $keystorePath"
}

function Find-Keytool {
    if (Get-Command keytool -ErrorAction SilentlyContinue) {
        return (Get-Command keytool).Source
    }
    $candidates = @(
        "$env:JAVA_HOME\bin\keytool.exe",
        "$env:ANDROID_STUDIO\jbr\bin\keytool.exe"
    )
    $studio = Get-ChildItem "C:\Program Files\Android\Android Studio*" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($studio) {
        $candidates += (Join-Path $studio.FullName "jbr\bin\keytool.exe")
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    throw "keytool was not found. Install a JDK or Android Studio and retry."
}

$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = [Convert]::ToBase64String($bytes)
$keytool = Find-Keytool

& $keytool -genkeypair -v `
    -keystore $keystorePath `
    -alias upload `
    -keyalg RSA `
    -keysize 2048 `
    -validity 10000 `
    -storepass $password `
    -keypass $password `
    -dname "CN=Meshenger, OU=Meshenger, O=Meshenger, L=Local, ST=Local, C=US"
if ($LASTEXITCODE -ne 0) { throw "keytool failed with exit code $LASTEXITCODE" }

@"
storePassword=$password
keyPassword=$password
keyAlias=upload
storeFile=upload-keystore.jks
"@ | Set-Content -Path $propertiesPath -Encoding ascii

Write-Host "Created $keystorePath"
Write-Host "Created $propertiesPath"
Write-Host "Keep both files private. They are gitignored."
