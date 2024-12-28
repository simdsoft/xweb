#
# Copyright (c) 2024-present Simdsoft Limited.
#
# xweb - A nginx + mysql + php environment
#  Notes:
#   - now only support windows
#   - TODO: Linux support
#
param(
    $op = 'start',
    $targets = 'all',
    [switch]$force,
    [switch]$version
)

$xweb_ver = '1.0.0'

Set-Alias println Write-Host

println "xweb version $xweb_ver"

if($version) { return }

$Global:IsWin = $IsWindows -or ("$env:OS" -eq 'Windows_NT')
. (Join-Path $PSScriptRoot 'manifest.ps1')

$download_path = Join-Path $PSScriptRoot 'cache'
$install_prefix = $PSScriptRoot

function ConvertFrom-Props {
    param(
        [Parameter(Mandatory=$true)]
        $InputObject
    )

    $props = @{}

    foreach($_ in $InputObject) {
        if ($_ -match "^#.*$") {
            continue
        }
        if ($_ -match "^(.+?)\s*=\s*(.*)$") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $props[$key] = $value
        }
    }

    return $props
}

function gen_random_key {
    param(
        [Parameter(Mandatory=$true)]
        [int]$Length
    )

    $charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-=[]{}|;:,.<>/?'
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
    if (!(Test-Path $path)) { New-Item $path -ItemType Directory }
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
        if($out.EndsWith('.zip')) {
            if($IsWin) {
                Expand-Archive -Path $out -DestinationPath $dest -Force
            }
            else {
                unzip -d $dest $out | Out-Null
            }
        }
        elseif ($out.EndsWith('.tar.gz')) {
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
    } else {
        if(!$prefix) { $prefix = $install_prefix }
        return Join-Path $prefix $path
    }
}

function fetch_pkg($url, $out = $null, $exrep = $null, $prefix = $null) {
    if (!$out) { $out = Join-Path $download_path $(Split-Path $url.Split('?')[0] -Leaf) }
    else { $out = resolve_path $out $download_path }

    $pfn_rename = $null

    if($exrep) {
        $exrep = $exrep.Split('=')
        if ($exrep.Count -eq 1) { # single file
            if (!$prefix) {
                $prefix = resolve_path $exrep[0]
            } else {
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
    } else {
        $prefix = $install_prefix
    }
    
    download_and_expand $url $out $prefix

    if ($pfn_rename) { &$pfn_rename }
}

$Script:local_props = $null
$actions = @{
    setup_env = {
        if(!$targets) {
            throw "targets is empty!"
        }

        if ($targets -eq 'all') {
            $targets = @('nginx', 'php', 'mysql')
            if ($op -eq 'init' -or $op -eq 'fetch') { $targets += 'phpmyadmin' }
        } elseif($targets -isnot [array]) {
            $targets = "$targets".Split(',')
        }

        $Script:targets = $targets

        mkdirs $download_path
        mkdirs $(Join-Path $PSScriptRoot 'temp')
        $prop_file = (Join-Path $PSScriptRoot 'local.properties')
        if (Test-Path $prop_file -PathType Leaf) {
            $props_lines = (Get-Content -Path $prop_file)
        }
        else {
            $mysql_pass = gen_random_key -Length 16
            $props_lines = @("mysql_pass=$mysql_pass", "mysql_auth_backport=0", "server_names=127.0.0.1")
            Set-Content -Path $prop_file -Value $props_lines
        }
        $Script:local_props = ConvertFrom-Props $props_lines

        $Script:php_ver = [version]$php_ver
        $is_php8 = $php_ver -ge [Version]'8.0.0'
        $Script:php_vs = @('vc15', 'vs17')[$is_php8]
    }
    fetch = @{
        nginx = {
            fetch_pkg "https://nginx.org/download/nginx-${nginx_ver}.zip"  -exrep "nginx-${nginx_ver}=${nginx_ver}" -prefix 'bin/nginx'
        }
        php = {
            if ($php_ver -eq $php_latset_ver) {
                fetch_pkg "https://windows.php.net/downloads/releases/php-${php_ver}-Win32-$php_vs-x64.zip" -exrep "bin/php/${php_ver}"
            } else {
                fetch_pkg "https://windows.php.net/downloads/releases/archives/php-${php_ver}-Win32-$php_vs-x64.zip" -exrep "bin/php/${php_ver}"
            }
        }
        phpmyadmin = {
            fetch_pkg "https://files.phpmyadmin.net/phpMyAdmin/${phpmyadmin_ver}/phpMyAdmin-${phpmyadmin_ver}-all-languages.zip" -exrep "phpMyAdmin-${phpmyadmin_ver}-all-languages=${phpmyadmin_ver}" -prefix 'apps/phpmyadmin'
        }
        mysql = {
            fetch_pkg "https://downloads.mysql.com/archives/get/p/23/file/mysql-${mysql_ver}-winx64.zip" -exrep "mysql-${mysql_ver}-winx64=${mysql_ver}" -prefix 'bin/mysql'
        }
        mariadb = {
            fetch_pkg "https://mirrors.tuna.tsinghua.edu.cn/mariadb///mariadb-$mariadb_ver/winx64-packages/mariadb-$mariadb_ver-winx64.zip" -exrep "mariadb-$mariadb_ver-winx64=$mariadb_ver" -prefix 'bin/mariadb'
        }
    }
    init = @{
        nginx = {
            $nginx_conf_dir = Join-Path $PSScriptRoot "etc/nginx/$nginx_ver"
            $nginx_conf_file = Join-Path $nginx_conf_dir 'nginx.conf'
            if (Test-Path $nginx_conf_file -PathType Leaf) {
                if ($force) {
                    $anwser = Read-Host "Are you want force init nginx, will lost conf?(y/N)"
                    if ($anwser -inotlike 'y*') {
                        return
                    }
                }
                else {
                    return
                }
            }

            if (!(Test-Path $nginx_conf_dir -PathType Container)) { 
                mkdirs $nginx_conf_dir
                Copy-Item (Join-Path $PSScriptRoot "bin/nginx/$nginx_ver/conf/*") $nginx_conf_dir
            }
            else {
                $lines = Get-Content -Path (Join-Path $nginx_conf_dir 'nginx.conf.in')
                $line_index = 0
                $xweb_root = $PSScriptRoot.Replace('\', '/')
                foreach($line_text in $lines) {
                    if ($line_text.Contains('@XWEB_ROOT@')) {
                        $lines[$line_index] = $line_text.Replace('@XWEB_ROOT@', $xweb_root)
                    } elseif($line_text.Contains('@XWEB_SERVER_NAMES@')) {
                        $lines[$line_index] = $line_text.Replace('@XWEB_SERVER_NAMES@', $local_props['server_names'])
                    }
                    ++$line_index
                }
                Set-Content -Path (Join-Path $nginx_conf_dir 'nginx.conf') -Value $lines
            }
        }
        php = {
            $php_dir = Join-Path $PSScriptRoot "bin/php/$php_ver"
            $php_ini = (Join-Path $php_dir 'php.ini')
        
            if (!(Test-Path $php_ini -PathType Leaf) -or $force) {
                $match_ext = {
                    param($ext, $exts)
                    foreach($item in $exts) {
                        if($ext -like $item) {
                            return $true
                        }
                    }
                    return $false
                }

                # TODO:
                $upload_props = @{upload_max_filesize='64MB'; post_max_size='64MB'; memory_limit='128MB'}

                $exclude_exts = @('*=oci8_12c*', '*=pdo_firebird*', '*=pdo_oci*', '*=snmp*')

                $lines = Get-Content -Path (Join-Path $php_dir 'php.ini-production')
                $line_index = 0
                foreach($line_text in $lines) {
                    if($line_text -like ';extension_dir = "ext"') {
                        $lines[$line_index] = 'extension_dir = "ext"'
                    } 
                    elseif($line_text -like '*extension=*') {
                        if ($line_text -like ';extension=*') {
                            if (-not (&$match_ext $line_text $exclude_exts)) {
                                $line_text = $line_text.Substring(1)
                                $lines[$line_index] = $line_text
                            }
                        }
        
                        $match_info = [Regex]::Match($line_text, '(?<!;)\bextension=([^;]+)')
                        if($match_info.Success -and $line_text.StartsWith('extension=')) {
                            println "php.ini: $($match_info.value)"
                        }
                    }
                    ++$line_index
                }
        
                # xdebug ini
                $lines += '`n'
                $xdebug_lines = Get-Content -Path (Join-Path $PSScriptRoot 'etc/php/xdebug.ini')
                foreach($line_text in $xdebug_lines) {
                    $lines += $line_text
                }
        
                Set-Content -Path $php_ini -Value $lines
            }
        
            # xdebug
            $xdebug_php_ver = "$($php_ver.Major).$($php_ver.Minor)"
            $xdebug_file_name = "php_xdebug-$xdebug_ver-$xdebug_php_ver-$php_vs-x86_64.dll"
            download_file -url "https://xdebug.org/files/$xdebug_file_name" -out $(Join-Path $download_path $xdebug_file_name)
            $xdebug_src = Join-Path $download_path $xdebug_file_name
            $xdebug_dest = Join-Path $php_dir 'ext/php_xdebug.dll'
            Copy-Item $xdebug_src $xdebug_dest -Force
        }
        phpmyadmin = {
            $phpmyadmin_dir = Join-Path $PSScriptRoot "apps/phpmyadmin/$phpmyadmin_ver"
            $phpmyadmin_conf = (Join-Path $phpmyadmin_dir 'config.inc.php')
        
            if (!(Test-Path $phpmyadmin_conf -PathType Leaf) -or $force) {
                $blowfish_secret = gen_random_key -Length 32
                $lines = Get-Content -Path (Join-Path $phpmyadmin_dir 'config.sample.inc.php')
                $line_index = 0
                foreach($line_text in $lines) {
                    if ($line_text -like "*blowfish_secret*") {
                        $lines[$line_index] = $line_text -replace "''", "'$blowfish_secret'"
                    }
                    ++$line_index
                }
                Set-Content -Path $phpmyadmin_conf -Value $lines
            }
        }
        mysql = {
            # enable plugin mysql_native_password, may don't required
            $mysql_dir = Join-Path $PSScriptRoot "bin/mysql/$mysql_ver"
            $mysql_data = Join-Path $mysql_dir 'data'
            if (Test-Path $mysql_data -PathType Container) {
                println "mysql already inited."
                return
            }

            $mysql_auth_backport = [int]$local_props['mysql_auth_backport']
            if ($mysql_auth_backport) {
                Copy-Item (Join-Path $PSScriptRoot "etc/mysql/my.ini") $mysql_dir -Force
                $init_cmds = "use mysql; ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$mysql_pass'; FLUSH PRIVILEGES;"
            } else {
                $init_cmds = "use mysql; UPDATE user SET authentication_string='' WHERE user='root'; ALTER user 'root'@'localhost' IDENTIFIED BY 'BfKWSMeshh9v7Gmp+&^';"
            }

            $mysql_bin = Join-Path $mysql_dir 'bin'

            Push-Location $mysql_bin
            & .\mysqld --initialize-insecure
            $mysql_pass = $local_props['mysql_pass']
            Start-Process .\mysqld.exe -ArgumentList '--console'

            println "Wait mysqld ready ..."
            Start-Sleep -Seconds 3

            & .\mysql -u root -e $init_cmds | Out-Host
            Pop-Location
        }
    }
    start = @{
        nginx = {
            $nginx_dir = Join-Path $install_prefix "bin/nginx/$nginx_ver"
            $nginx_prog = Join-Path $nginx_dir 'nginx.exe'
            $nginx_conf = Join-Path $PSScriptRoot "etc/nginx/$nginx_ver/nginx.conf"
            &$nginx_prog -t -c $nginx_conf | Out-Host
            Start-Process $nginx_prog -ArgumentList "-c `"$nginx_conf`"" -WorkingDirectory $nginx_dir -WindowStyle Hidden
        }
        php = {
            $php_dir = Join-Path $install_prefix "bin/php/$php_ver"
            $php_prog = Join-Path $php_dir 'php-cgi.exe'
            Start-Process $php_prog -ArgumentList "-b 127.0.0.1:9000" -WorkingDirectory $php_dir -WindowStyle Hidden
        }
        mysql = {
            $mysql_dir = Join-Path $install_prefix "bin/mysql/$mysql_ver/bin"
            $myslqd_prog = Join-Path $mysql_dir 'mysqld.exe'
            Start-Process $myslqd_prog -WorkingDirectory $mysql_dir -WindowStyle Hidden
        }
    }
    stop = @{
        nginx = {
            taskkill /f /im nginx.exe 2>$null
        }
        php = {
            taskkill /f /im php-cgi.exe 2>$null
            taskkill /f /im intelliphp.ls.exe 2>$null
        }
        mysql = {
            taskkill /f /im mysqld.exe 2>$null
        }
    }
}

function run_action($name, $targets) {
    $action = $actions[$name]
    foreach($target in $targets) {
        $action_comp = $action.$target
        if ($action_comp) {
            & $action_comp
        } else {
            println "The $target not support action: $name"
        }
    }
}

& $actions.setup_env

switch($op){
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
}

if($? -and !$LASTEXITCODE) {
    println "The operation successfully."
}
else {
    throw "The operation fail!"
}
