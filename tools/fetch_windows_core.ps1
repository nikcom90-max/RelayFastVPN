# Скачивает ядро Xray (под именем rf-core.exe), Wintun и списки geo в папку core/
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path core | Out-Null

function Get-File($url, $out) {
  for ($i = 1; $i -le 4; $i++) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
      if ((Get-Item $out).Length -gt 0) { return }
    } catch {
      Write-Host "попытка $i не удалась: $url ($($_.Exception.Message))"
      Start-Sleep -Seconds (3 * $i)
    }
  }
  throw "Не удалось скачать $url"
}

# Xray-core (последний релиз)
Get-File 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-windows-64.zip' 'xray.zip'
Expand-Archive -Path 'xray.zip' -DestinationPath 'xray_tmp' -Force
Copy-Item 'xray_tmp\xray.exe' 'core\rf-core.exe'

# Wintun (драйвер TUN-адаптера)
Get-File 'https://www.wintun.net/builds/wintun-0.14.1.zip' 'wintun.zip'
Expand-Archive -Path 'wintun.zip' -DestinationPath 'wintun_tmp' -Force
Copy-Item 'wintun_tmp\wintun\bin\amd64\wintun.dll' 'core\wintun.dll'

# Списки geoip/geosite с правилами для РФ (как в Android-версии)
$base = if ($env:GEO_BASE) { $env:GEO_BASE } else { 'https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download' }
Get-File "$base/geoip.dat" 'core\geoip.dat'
Get-File "$base/geosite.dat" 'core\geosite.dat'

Get-ChildItem core | Format-Table Name, Length
& 'core\rf-core.exe' version
