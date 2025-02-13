#
# Copyright (c) 2024-present Simdsoft Limited.
#
# qweb - A quick web environment(nginx + mysql + php) supporting both windows and ubuntu
#
param(
    $op = 'start',
    $targets = 'all',
    [switch]$force,
    [switch]$version
)

$qweb_ver = '1.3.0'

$global:qweb_host_cpu = [System.Runtime.InteropServices.RuntimeInformation, mscorlib]::OSArchitecture.ToString().ToLower()

Set-Alias println Write-Host

println "qweb version $qweb_ver"

if ($version) { return }

$Global:IsWin = $IsWindows -or ("$env:OS" -eq 'Windows_NT')
$Global:IsUbuntu = !$IsWin -and ($PSVersionTable.OS -like 'Ubuntu *')

. (Join-Path $PSScriptRoot 'manifest.ps1')

$download_path = Join-Path $PSScriptRoot 'cache'
$install_prefix = Join-Path $PSScriptRoot 'opt'

function parse_prop($line_text) {
    if ($line_text -match "^#.*$") {
        return $null
    }
    if ($line_text -match "^(.+?)\s*=\s*(.*)$") {
        $key = $matches[1].Trim()
        $value = $matches[2].Trim()
        return $key, $value
    }
    return $null
}

function ConvertFrom-Props {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    $props = @{}

    foreach ($_ in $InputObject) {
        $key, $val = parse_prop $_
        if ($key) {
            $props[$key] = $val
        }
    }

    return $props
}

function gen_random_key {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Length
    )

    $charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@$%^&*~'
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $key = [System.Text.StringBuilder]::new($Length)

    $byte = New-Object Byte[] 1
    for ($i = 0; $i -lt $Length; $i++) {
        $random.GetBytes($byte)
        $index = [convert]::ToInt32($byte[0]) % $charset.Length
        $key.Append($charset[$index]) | Out-Null
    }

    return $key.ToString()
}

function mkdirs($path) {
    if (!(Test-Path $path)) { New-Item $path -ItemType Directory 1>$null }
}

function download_file($url, $out) {
    if (Test-Path $out -PathType Leaf) { return }
    println "Downloading $url to $out ..."
    Invoke-WebRequest -Uri $url -OutFile $out
}

function download_and_expand($url, $out, $dest) {

    download_file $url $out
    try {
        mkdirs($dest)
        if ($out.EndsWith('.zip')) {
            if ($IsWin) {
                Expand-Archive -Path $out -DestinationPath $dest -Force
            }
            else {
                unzip -d $dest $out | Out-Null
            }
        }
        elseif ($out.EndsWith('.tar.gz') -or $out.EndsWith('.tar')) {
            tar xf "$out" -C $dest | Out-Host
        }
        elseif ($out.EndsWith('.7z') -or $out.EndsWith('.exe')) {
            7z x "$out" "-o$dest" -bsp1 -snld -y | Out-Host
        }
        elseif ($out.EndsWith('.sh')) {
            chmod 'u+x' "$out" | Out-Host
        }
        if (!$?) { throw "1kiss: Expand fail" }
    }
    catch {
        Remove-Item $out -Force
        throw "1kiss: Expand archive $out fail, please try again"
    }
}

function resolve_path ($path, $prefix = $null) { 
    if ([IO.Path]::IsPathRooted($path)) { 
        return $path 
    }
    else {
        if (!$prefix) { $prefix = $PSScriptRoot }
        return Join-Path $prefix $path
    }
}

function fetch_pkg($url, $out = $null, $exrep = $null, $prefix = $null) {
    if (!$out) { $out = Join-Path $download_path $(Split-Path $url.Split('?')[0] -Leaf) }
    else { $out = resolve_path $out $download_path }

    $pfn_rename = $null

    if ($exrep) {
        $exrep = $exrep.Split('=')
        if ($exrep.Count -eq 1) {
            # single file
            if (!$prefix) {
                $prefix = resolve_path $exrep[0]
            }
            else {
                $prefix = resolve_path $prefix
            }
        }
        else {
            $prefix = resolve_path $prefix
            $inst_dst = Join-Path $prefix $exrep[1]
            $pfn_rename = {
                # move to plain folder name
                $full_path = (Get-ChildItem -Path $prefix -Filter $exrep[0]).FullName
                if ($full_path) {
                    Move-Item $full_path $inst_dst
                }
                else {
                    throw "1kiss: rename $($exrep[0]) to $inst_dst fail"
                }
            }
            if (Test-Path $inst_dst -PathType Container) { Remove-Item $inst_dst -Recurse -Force }
        }
    }
    else {
        if (!$prefix) {
            $prefix = $install_prefix
        }
        else {
            $prefix = resolve_path $prefix
        }
    }
    
    download_and_expand $url $out $prefix

    if ($pfn_rename) { &$pfn_rename }
}

if ($IsWin) {
    $qweb_root = $PSScriptRoot.Replace('\', '/')
}
else {
    $qweb_root = $PSScriptRoot
}

$Script:local_props = $null
$actions = @{
    setup_env = {
        if (!$targets) {
            throw "targets is empty!"
        }

        if ($targets -eq 'all') {
            $targets = @('nginx', 'php', 'mysql')
            $setup_actions = @('init'; 'fetch'; 'install')
            if ($setup_actions.Contains($op)) { $targets += 'phpmyadmin' }
        }
        elseif ($targets -isnot [array]) {
            $targets = "$targets".Split(',')
        }

        $Script:targets = $targets

        mkdirs $install_prefix
        mkdirs $download_path
        mkdirs $(Join-Path $PSScriptRoot 'var/nginx/logs')
        mkdirs $(Join-Path $PSScriptRoot 'var/nginx/temp')
        mkdirs $(Join-Path $PSScriptRoot 'var/php-cgi')
        mkdirs $(Join-Path $PSScriptRoot 'var/mysqld')
        $prop_file = (Join-Path $PSScriptRoot 'local.properties')
        if (Test-Path $prop_file -PathType Leaf) {
            $props_lines = (Get-Content -Path $prop_file)
        }
        else {
            $mysql_pass = gen_random_key -Length 16
            $props_lines = @("mysql_pass=$mysql_pass", "mysql_auth_backport=0", "server_names=sandbox.qweb.dev")
            Set-Content -Path $prop_file -Value $props_lines
        }
        $Script:local_props = ConvertFrom-Props $props_lines

        if ($IsWin) {
            $is_php8 = $php_ver -ge [Version]'8.0.0'
            $Script:php_vs = @('vc15', 'vs17')[$is_php8]
        }

        if ($IsWin -or $IsMacOS) {
            $Script:mysqld_cwd = Join-Path $PSScriptRoot 'var/mysqld'
            $Script:mysqld_data = Join-Path $PSScriptRoot 'var/mysqld/data'
        }
    }
}

function mod_php_ini($php_ini_file, $do_setup) {
    $match_ext = {
        param($ext, $exts)
        foreach ($item in $exts) {
            if ($ext -like $item) {
                return $true
            }
        }
        return $false
    }

    $upload_props = @{upload_max_filesize = '64M'; post_max_size = '64M'; memory_limit = '128M' }

    $exclude_exts = @('*=oci8_12c*', '*=pdo_firebird*', '*=pdo_oci*', '*=snmp*')

    $lines = Get-Content -Path $php_ini_file
    $line_index = 0
    $mods = 0
    foreach ($line_text in $lines) {
        if ($line_text -like ';extension_dir = "ext"') {
            if ($do_setup) {
                $lines[$line_index] = 'extension_dir = "ext"'
                ++$mods
            }
        } 
        elseif ($line_text -like '*extension=*') {
            if ($do_setup) {
                if ($line_text -like ';extension=*') {
                    if (-not (&$match_ext $line_text $exclude_exts)) {
                        $line_text = $line_text.Substring(1)
                        $lines[$line_index] = $line_text
                        ++$mods
                    }
                }

                $match_info = [Regex]::Match($line_text, '(?<!;)\bextension=([^;]+)')
                if ($match_info.Success -and $line_text.StartsWith('extension=')) {
                    println "php.ini: $($match_info.value)"
                }
            }
        }
        else {
            $key, $val = parse_prop $line_text
            if ($key -and $upload_props.Contains($key)) {
                $new_val = $upload_props[$key]
                $lines[$line_index] = "$key = $new_val"
                ++$mods
            }
        }
        ++$line_index
    }

    return $lines, $mods
}

if ($IsWin) {
    . $(Join-Path $PSScriptRoot 'contrib/qweb_win.ps1')
}
elseif ($IsUbuntu) {
    . $(Join-Path $PSScriptRoot 'contrib/qweb_linux.ps1')
}
elseif ($IsMacOS) {
    . $(Join-Path $PSScriptRoot 'contrib/qweb_macos.ps1')
}
else {
    throw "Unsupported OS: $($PSVersionTable.OS)"
}

$actions.fetch.phpmyadmin = {
    if ($php_ver -ge [Version]'8.0.0') {
        fetch_pkg "https://files.phpmyadmin.net/snapshots/phpMyAdmin-6.0+snapshot-all-languages.zip" -exrep "phpMyAdmin-6.0+snapshot-all-languages=${phpmyadmin_ver}" -prefix 'opt/phpmyadmin'
    }
    else {
        fetch_pkg "https://files.phpmyadmin.net/phpMyAdmin/${phpmyadmin_ver}/phpMyAdmin-${phpmyadmin_ver}-all-languages.zip" -exrep "phpMyAdmin-${phpmyadmin_ver}-all-languages=${phpmyadmin_ver}" -prefix 'opt/phpmyadmin'
    }
    fetch_pkg "https://files.phpmyadmin.net/themes/boodark-nord/1.1.0/boodark-nord-1.1.0.zip" -prefix "opt/phpmyadmin/${phpmyadmin_ver}/themes/"
}

$actions.init.phpmyadmin = {
    $phpmyadmin_dir = Join-Path $install_prefix "phpmyadmin/$phpmyadmin_ver"
    $phpmyadmin_conf = (Join-Path $phpmyadmin_dir 'config.inc.php')

    if (!(Test-Path $phpmyadmin_conf -PathType Leaf) -or $force) {
        $blowfish_secret = gen_random_key -Length 32
        $lines = Get-Content -Path (Join-Path $phpmyadmin_dir 'config.sample.inc.php')
        $line_index = 0
        $has_theme_manager = $false
        $has_theme_default = $false
        foreach ($line_text in $lines) {
            if ($line_text -like "*blowfish_secret*") {
                $lines[$line_index] = $line_text.Replace("''", "'$blowfish_secret'")
            }
            elseif ($line_text -like '*ThemeManager*') {
                $lines[$line_index] = $line_text.Replace("false", "true")
                $has_theme_manager = $true
            }
            elseif ($line_text -like '*ThemeDefault*') {
                $lines[$line_index] = $line_text -replace "'.*'", "'boodark-nord'"
                $has_theme_default = $true
            }
            ++$line_index
        }
        if (!$has_theme_manager) {
            $lines += "`$cfg['ThemeManager'] = true;"
            $lines += "`$cfg['ShowAll'] = true;"
        }
        if (!$has_theme_default) {
            if ([Version]$phpmyadmin_ver -lt [Version]'6.0.0') {
                $lines += "`$cfg['ThemeDefault'] = 'boodark-nord';"
            }
        }
        Set-Content -Path $phpmyadmin_conf -Value $lines
    }
}

$actions.init.nginx = {
    $nginx_conf_dir = Join-Path $PSScriptRoot "etc/nginx/$nginx_ver"
    $nginx_conf_file = Join-Path $nginx_conf_dir 'nginx.conf'
    if (Test-Path $nginx_conf_file -PathType Leaf) {
        $anwser = if ($force) { Read-Host "Are you want force reinit nginx, will lost conf?(y/N)" } else { 'N' }
        if ($anwser -inotlike 'y*') {
            println "nginx init: nothing need to do"
            return
        }
    }

    if ((Test-Path $nginx_conf_dir -PathType Container)) {
        $lines = Get-Content -Path (Join-Path $nginx_conf_dir 'nginx.conf.in')
        $line_index = 0
        $qweb_cert_dir = Join-Path $PSScriptRoot 'etc/certs'
        if (!(Test-Path (Join-Path $qweb_cert_dir 'server.crt') -PathType Leaf) -or
            !(Test-Path (Join-Path $qweb_cert_dir 'server.key') -PathType Leaf)
        ) {
            $qweb_cert_dir = (Join-Path $qweb_cert_dir 'sample').Replace('\', '/')
            $qweb_rel_cert_dir = '../../certs/sample'
            Write-Warning "Using sample certs in dir $qweb_cert_dir"
        }
        else {
            $qweb_rel_cert_dir = '../../certs'
        }
        $qweb_cert_dir = $qweb_cert_dir.Replace('\', '/')
        foreach ($line_text in $lines) {
            if ($line_text.Contains('@QWEB_ROOT@')) {
                $lines[$line_index] = $line_text.Replace('@QWEB_ROOT@', $qweb_root)
            }
            elseif ($line_text.Contains('@QWEB_SERVER_NAMES@')) {
                $lines[$line_index] = $line_text.Replace('@QWEB_SERVER_NAMES@', $local_props['server_names'])
            }
            elseif ($line_text.Contains('@QWEB_CERT_DIR@')) {
                $lines[$line_index] = $line_text.Replace('@QWEB_CERT_DIR@', $qweb_rel_cert_dir)
            }
            elseif ($line_text.Contains('@phpmyadmin_ver@')) {
                $lines[$line_index] = $line_text.Replace('@phpmyadmin_ver@', $phpmyadmin_ver)
            }
            elseif (!$IsWin -and !$IsMacOS -and $line_text.Contains('nobody')) {
                $line_text = $line_text.Replace('nobody', "$(whoami)")
                if ($line_text.StartsWith('#')) { $line_text = $line_text.TrimStart('#') }
                $lines[$line_index] = $line_text
            }
            ++$line_index
        }
        Set-Content -Path (Join-Path $nginx_conf_dir 'nginx.conf') -Value $lines
    }
    else {
        mkdirs $nginx_conf_dir
        Copy-Item (Join-Path $install_prefix "nginx/$nginx_ver/conf/*") $nginx_conf_dir
    }

    if ($IsUbuntu) {
        # $nginx_grp = $(cat /etc/passwd | grep nginx)
        # if (!$nginx_grp) {
        #     sudo groupadd nginx
        #     sudo useradd -g nginx -s /sbin/nologin nginx
        # }
        sudo chown -R ${qweb_user}:${qweb_user} $qweb_root/htdocs
    }
}

function run_action($name, $targets) {
    $action = $actions[$name]
    foreach ($target in $targets) {
        $action_comp = $action.$target
        if ($action_comp) {
            & $action_comp
        }
        else {
            println "The $target not support action: $name"
        }
    }
}

& $actions.setup_env

switch ($op) {
    'fetch' {
        run_action 'fetch' $targets
    }
    'init' {
        run_action 'init' $targets
    }
    'install' {
        println 'Installing server ...'
        run_action 'fetch' $targets
        run_action 'init' $targets
    }
    'start' {
        println "Starting server ..."
        run_action 'start' $targets
    }
    'restart' {
        println "Restarting server ..."
        run_action 'stop' $targets
        run_action 'start' $targets
    }
    'stop' {
        println "Stopping server ..."
        run_action 'stop' $targets
    }
    'passwd' {
        run_action 'passwd' $targets
    }
    'status' {
        run_action 'status' $targets
    }
}

if ($?) {
    println "The operation successfully."
}
else {
    throw "The operation fail!"
}
