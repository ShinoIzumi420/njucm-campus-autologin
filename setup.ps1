# 保存校园网账号密码（DPAPI 加密，仅当前 Windows 用户可解密）
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $dir 'config.json'

$cfg = @{ username = ''; domain = 'default' }
if (Test-Path $cfgPath) {
    $old = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($old.username) { $cfg.username = $old.username }
    if ($old.domain)   { $cfg.domain = $old.domain }
}

Write-Host '=========================================='
Write-Host ' NJUCM 校园网无感认证 - 账号配置'
Write-Host '=========================================='
Write-Host ("当前用户名: " + $cfg.username)
Write-Host ("当前运营商: " + $cfg.domain + "   (default=校园网  cmcc=移动  telecom=电信  unicom=联通)")
Write-Host ''

$u = Read-Host '上网账号 (直接回车=保持不变)'
if ($u -and $u.Trim()) { $cfg.username = $u.Trim() }

$d = Read-Host '运营商域 default/cmcc/telecom/unicom (直接回车=保持不变)'
if ($d -and $d.Trim()) { $cfg.domain = $d.Trim() }

$sec = Read-Host '上网密码 (输入不回显)' -AsSecureString
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
if ($plain -eq '') {
    Write-Host '密码为空，未保存任何更改。' -ForegroundColor Yellow
    exit 1
}

$enc = $sec | ConvertFrom-SecureString
# 不留末尾换行，否则 ConvertTo-SecureString 解析会失败
[IO.File]::WriteAllText((Join-Path $dir 'cred.bin'), $enc)
$cfg | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8

# 保存成功即清除失败冷却
Remove-Item (Join-Path $dir 'lastfail.txt') -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '已保存。凭据经 Windows DPAPI 加密，仅当前 Windows 用户可解密。' -ForegroundColor Green
Write-Host '可以运行 2-安装开机自启.cmd（若已注册过则无需重复安装）。'
