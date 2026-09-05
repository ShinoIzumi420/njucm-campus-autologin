# ============================================================
# NJUCM 校园网自动登录 (net.njucm.edu.cn)
# 协议: POST /api/portal/v1/login  {domain, username, password}
#       失败时自动回退 CHAP (challenge + md5)
#       已在线时通过 GET /api/portal/v1/getinfo 检测并直接退出
# ============================================================
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $dir 'login.log'
$Portal = 'http://net.njucm.edu.cn'

function Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
# 日志超过 512KB 时只保留最后 1000 行
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 512KB)) {
    $keep = Get-Content $log -Tail 1000 -Encoding UTF8
    Set-Content -Path $log -Value $keep -Encoding UTF8
}

function Invoke-PortalJson([string]$Method, [string]$Uri, [string]$Body) {
    # 绕过系统代理直连认证服务器，5 秒超时（不在校园网时快速失败）
    $req = [Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Timeout = 5000
    $req.ReadWriteTimeout = 5000
    $req.AllowAutoRedirect = $false
    $req.Proxy = $null
    $req.ContentType = 'application/json'
    if ($Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream()
        $s.Write($bytes, 0, $bytes.Length)
        $s.Close()
    }
    try { $resp = $req.GetResponse() }
    catch [Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }
    $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    $sr.Close(); $resp.Close()
    return $text
}

function New-ChapPassword([string]$Password, [string]$Challenge) {
    $id = Get-Random -Minimum 0 -Maximum 256
    $str = [string][char]$id + $Password
    for ($i = 0; $i -lt $Challenge.Length; $i += 2) {
        $str += [string][char][Convert]::ToInt32($Challenge.Substring($i, 2), 16)
    }
    $md5 = New-Object Security.Cryptography.MD5CryptoServiceProvider
    $hashBytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($str))
    $md5.Dispose()
    $hash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    return ('{0:x2}' -f $id) + $hash
}

# 0) 暂停开关：存在 PAUSE.txt 时什么都不做
if (Test-Path (Join-Path $dir 'PAUSE.txt')) { Log 'PAUSE.txt 存在，本次跳过。'; exit 0 }

# 1) 探测认证服务器 / 是否已在线
$online = $false
$reachable = $true
$info = $null
try {
    $info = Invoke-PortalJson 'GET' "$Portal/api/portal/v1/getinfo" $null | ConvertFrom-Json
    if ($info.reply_code -eq 0 -and $info.results -and $info.results.rows -and @($info.results.rows).Count -ge 1) { $online = $true }
} catch { $reachable = $false }

if (-not $reachable) { Log '认证服务器不可达（大概率不在校园网），跳过。'; exit 0 }
if ($online) {
    Log ('已在线 (user=' + $info.results.rows[0].username + ')，无需登录。')
    exit 0
}

# 2) 认证失败冷却：最近 1 小时内服务器拒绝过就不再尝试，防止锁号
$failPath = Join-Path $dir 'lastfail.txt'
if (Test-Path $failPath) {
    $last = [int64]0
    [void][int64]::TryParse((Get-Content $failPath -Raw).Trim(), [ref]$last)
    if ($last -gt 0 -and (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) - $last) -lt 3600) {
        Log '上次登录被服务器拒绝，冷却期内（1小时），跳过。'
        exit 0
    }
}

# 3) 读取凭据
$cfgPath = Join-Path $dir 'config.json'
$credPath = Join-Path $dir 'cred.bin'
if (-not (Test-Path $cfgPath) -or -not (Test-Path $credPath)) {
    Log '缺少 config.json 或 cred.bin，请先运行 1-配置账号.cmd'
    exit 2
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
try {
    $sec = ConvertTo-SecureString (Get-Content $credPath -Raw).Trim()
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
} catch {
    Log 'cred.bin 解密失败（换了 Windows 用户？），请重新运行 1-配置账号.cmd'
    exit 2
}

# 4) 登录：先 PAP，被拒再试 CHAP；网络异常才做同轮重试（最多3次）
$ok = $false
$serverJudged = $false
$msgs = @()
for ($i = 1; $i -le 3 -and -not $ok -and -not $serverJudged; $i++) {
    try {
        $body = @{ domain = $cfg.domain; username = $cfg.username; password = $plain } | ConvertTo-Json -Compress
        $r = Invoke-PortalJson 'POST' "$Portal/api/portal/v1/login" $body | ConvertFrom-Json
        $serverJudged = $true
        if ($r.reply_code -eq 0) { $ok = $true; break }
        $msgs += ("PAP: reply_code=" + $r.reply_code + " msg=" + $r.reply_msg + " io=" + $r.results.io_reply_code + " " + $r.results.io_reply_msg)

        $ch = Invoke-PortalJson 'GET' "$Portal/api/portal/v1/challenge" $null | ConvertFrom-Json
        if ($ch.reply_code -eq 0) {
            $chap = New-ChapPassword -Password $plain -Challenge $ch.results
            $body2 = @{ domain = $cfg.domain; username = $cfg.username; password = $chap; challenge = $ch.results } | ConvertTo-Json -Compress
            $r2 = Invoke-PortalJson 'POST' "$Portal/api/portal/v1/login" $body2 | ConvertFrom-Json
            if ($r2.reply_code -eq 0) { $ok = $true; break }
            $msgs += ("CHAP: reply_code=" + $r2.reply_code + " msg=" + $r2.reply_msg + " io=" + $r2.results.io_reply_code + " " + $r2.results.io_reply_msg)
        }
    } catch {
        $msgs += ("第" + $i + "次网络错误: " + $_.Exception.Message)
        if ($i -lt 3) { Start-Sleep -Seconds 8 }
    }
}

if ($ok) {
    Log ('登录成功 (user=' + $cfg.username + ', domain=' + $cfg.domain + ')。')
    Remove-Item $failPath -ErrorAction SilentlyContinue
    exit 0
} else {
    Log ('登录失败: ' + ($msgs -join ' | '))
    if ($serverJudged) { Set-Content -Path $failPath -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Encoding ASCII }
    exit 1
}
