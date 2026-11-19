param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [Parameter(Mandatory=$true)][string]$ConfigFirebird
)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'Este pacote requer Windows x64.' }
if (-not (Test-Path -LiteralPath $ConfigFirebird)) { throw 'Informe o configFirebird.ini existente do Middleware.' }
$source = Join-Path (Split-Path $PSScriptRoot) 'bin'
$exe = Join-Path $Destination 'AguiaEmail.exe'
if (Test-Path -LiteralPath $exe) {
  & $exe --parar-servico
  if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel parar o servico anterior.' }
  Copy-Item -LiteralPath $exe -Destination ($exe+'.bak-'+(Get-Date -Format yyyyMMddHHmmss))
}
New-Item -ItemType Directory -Force $Destination | Out-Null
Copy-Item -Path (Join-Path $source '*.dll') -Destination $Destination -Force
Copy-Item -LiteralPath (Join-Path $source 'AguiaEmail.exe'), (Join-Path $source 'cacert.pem') -Destination $Destination -Force
$ini = Join-Path $Destination 'email.ini'
if (-not (Test-Path -LiteralPath $ini)) {
  $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'email.ini.windows'))
  $text = $text.Replace('..\Middleware\configFirebird.ini', (Resolve-Path -LiteralPath $ConfigFirebird).Path)
  [IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false))
}
& icacls.exe $Destination /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q
if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger os arquivos do servico.' }
& $exe $ini --verificar
if ($LASTEXITCODE -ne 0) { throw 'Confira a migracao 000654, a conexao e o pacote CA antes de iniciar.' }
& $exe --instalar-servico $ini
if ($LASTEXITCODE -ne 0) { throw 'Falha ao instalar o servico.' }
Start-Service -Name ServiceEmailAguia
Get-Service -Name ServiceEmailAguia

