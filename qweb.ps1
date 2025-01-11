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

$qweb_ver = '1.2.0'

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
    $actions.fetch = @{
        nginx      = {
            fetch_pkg "https://nginx.org/download/nginx-${nginx_ver}.zip" -exrep "nginx-${nginx_ver}=${nginx_ver}" -prefix 'opt/nginx'
        }
        php        = {
            if ($php_ver -eq $php_latset) {
                fetch_pkg "https://windows.php.net/downloads/releases/php-${php_ver}-Win32-$php_vs-x64.zip" -exrep "opt/php/${php_ver}"
            }
            else {
                fetch_pkg "https://windows.php.net/downloads/releases/archives/php-${php_ver}-Win32-$php_vs-x64.zip" -exrep "opt/php/${php_ver}"
            }
        }
        phpmyadmin = {
            fetch_pkg "https://files.phpmyadmin.net/phpMyAdmin/${phpmyadmin_ver}/phpMyAdmin-${phpmyadmin_ver}-all-languages.zip" -exrep "phpMyAdmin-${phpmyadmin_ver}-all-languages=${phpmyadmin_ver}" -prefix 'opt/phpmyadmin'
            fetch_pkg "https://files.phpmyadmin.net/themes/boodark-nord/1.1.0/boodark-nord-1.1.0.zip" -prefix "opt/phpmyadmin/${phpmyadmin_ver}/themes/"
        }
        mysql      = {
            if ($mysql_ver -eq $mysql_latest) {
                fetch_pkg "https://cdn.mysql.com//Downloads/MySQL-$($mysql_ver.Major).$($mysql_ver.Minor)/mysql-$mysql_ver-winx64.zip" -exrep "mysql-${mysql_ver}-winx64=${mysql_ver}" -prefix 'opt/mysql'
            }
            else {
                fetch_pkg "https://downloads.mysql.com/archives/get/p/23/file/mysql-${mysql_ver}-winx64.zip" -exrep "mysql-${mysql_ver}-winx64=${mysql_ver}" -prefix 'opt/mysql'
            }
        }
        mariadb    = {
            fetch_pkg "https://mirrors.tuna.tsinghua.edu.cn/mariadb///mariadb-$mariadb_ver/winx64-packages/mariadb-$mariadb_ver-winx64.zip" -exrep "mariadb-$mariadb_ver-winx64=$mariadb_ver" -prefix 'opt/mariadb'
        }
    }
    $actions.init = @{
        php        = {
            $php_dir = Join-Path $install_prefix "php/$php_ver"
            $php_ini = (Join-Path $php_dir 'php.ini')
        
            if (!(Test-Path $php_ini -PathType Leaf) -or $force) {
                $lines, $_ = mod_php_ini (Join-Path $php_dir 'php.ini-production') $true
        
                # xdebug ini
                $lines += '`n'
                $xdebug_lines = Get-Content -Path (Join-Path $PSScriptRoot 'etc/php/xdebug.ini')
                foreach ($line_text in $xdebug_lines) {
                    $lines += $line_text
                }
        
                Set-Content -Path $php_ini -Value $lines
            }
        
            # xdebug
            $xdebug_php_ver = "$($php_ver.Major).$($php_ver.Minor)"
            $xdebug_ver = $xdebug_ver_map[$xdebug_php_ver]
            $xdebug_file_name = "php_xdebug-$xdebug_ver-$xdebug_php_ver-$php_vs-x86_64.dll"
            download_file -url "https://xdebug.org/files/$xdebug_file_name" -out $(Join-Path $download_path $xdebug_file_name)
            $xdebug_src = Join-Path $download_path $xdebug_file_name
            $xdebug_dest = Join-Path $php_dir 'ext/php_xdebug.dll'
            Copy-Item $xdebug_src $xdebug_dest -Force
        }
        phpmyadmin = {
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
                    $lines += "`$cfg['ThemeDefault'] = 'boodark-nord';"
                }
                Set-Content -Path $phpmyadmin_conf -Value $lines
            }
        }
        mysql      = {
            # enable plugin mysql_native_password, may don't required
            $mysql_dir = Join-Path $install_prefix "mysql/$mysql_ver"
            if (Test-Path $mysqld_data -PathType Container) {
                $anwser = if ($force) { Read-Host "Are you sure force reinit mysqld, will lost all database(y/N)?" } else { 'N' }
                if ($anwser -inotlike 'y*') {
                    println "mysql init: nothing need to do"
                    return
                }
                
                println "Deleting $mysqld_data"
                taskkill /f /im mysqld.exe 2>$null
                Remove-Item $mysqld_data -Recurse -Force
            }

            $mysql_bin = Join-Path $mysql_dir 'bin'
            $mysqld_prog = Join-Path $mysql_bin 'mysqld.exe'
            $mysql_prog = Join-Path $mysql_bin 'mysql.exe'
            
            $mysql_pass = $local_props['mysql_pass']
            $mysql_auth_backport = [int]$local_props['mysql_auth_backport'] -and $mysql_ver.Major -lt 9
            if ($mysql_auth_backport) {
                $my_conf_file = Join-Path $PSScriptRoot 'etc/mysql/my.ini'
                Copy-Item $my_conf_file $mysql_dir -Force
            }

            Push-Location $mysqld_cwd
            & $mysqld_prog --initialize-insecure --datadir $mysqld_data | Out-Host

            Start-Process $mysqld_prog -ArgumentList "--console --datadir `"$mysqld_data`"" -WorkingDirectory $mysqld_cwd
            println "Wait mysqld ready ..."
            Start-Sleep -Seconds 3

            if ($mysql_auth_backport) {
                $set_pass_cmds = "use mysql; ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$mysql_pass'; FLUSH PRIVILEGES;"
            }
            else {
                $set_pass_cmds = "use mysql; UPDATE user SET authentication_string='' WHERE user='root'; ALTER user 'root'@'localhost' IDENTIFIED BY '$mysql_pass';"
            }
            & $mysql_prog -u root -e $set_pass_cmds | Out-Host
            if ($?) {
                taskkill /f /im mysqld.exe 2>$null
            }
            Pop-Location
        }
    }
    $actions.passwd = @{
        mysql = {
            taskkill /f /im mysqld.exe 2>$null
            $mysql_dir = Join-Path $install_prefix "mysql/$mysql_ver"
            $mysql_bin = Join-Path $mysql_dir 'bin'
            $mysqld_prog = Join-Path $mysql_bin 'mysqld.exe'
            $mysql_prog = Join-Path $mysql_bin 'mysql.exe'

            Start-Process $mysqld_prog -ArgumentList "--console --skip-grant-tables --shared-memory --datadir `"$mysqld_data`"" -WorkingDirectory $mysqld_cwd
            println "Wait mysqld ready ..."
            Start-Sleep -Seconds 3
            $mysql_pass1 = Read-Host "Please input new password"
            $mysql_pass2 = Read-Host "input again"
            if ($mysql_pass1 -ne $mysql_pass2) {
                throw "two input passwd mismatch!"
                return
            }

            $set_pass_cmds = "use mysql; FLUSH PRIVILEGES; UPDATE user SET authentication_string='' WHERE user='root'; ALTER user 'root'@'localhost' IDENTIFIED BY '$mysql_pass1';"
            & $mysql_prog -u root -e $set_pass_cmds | Out-Host
            if ($?) {
                taskkill /f /im mysqld.exe 2>$null
            }

            $Global:LASTEXITCODE = 0
        }
    }
    $actions.start = @{
        nginx = {
            $nginx_dir = Join-Path $install_prefix "nginx/$nginx_ver"
            $nginx_prog = Join-Path $nginx_dir 'nginx.exe'
            $nginx_conf = Join-Path $PSScriptRoot "etc/nginx/$nginx_ver/nginx.conf"
            $nginx_cwd = Join-Path $PSScriptRoot 'var/nginx'
            Push-Location $nginx_cwd
            &$nginx_prog -t -c $nginx_conf | Out-Host
            Pop-Location
            Start-Process $nginx_prog -ArgumentList "-c `"$nginx_conf`"" -WorkingDirectory $nginx_cwd -WindowStyle Hidden
        }
        php   = {
            $php_dir = Join-Path $install_prefix "php/$php_ver"
            $php_cgi_prog = Join-Path $php_dir 'php-cgi.exe'
            $php_cgi_cwd = Join-Path $PSScriptRoot 'var/php-cgi'
            Start-Process $php_cgi_prog -ArgumentList "-b 127.0.0.1:9000" -WorkingDirectory $php_cgi_cwd -WindowStyle Hidden
        }
        mysql = {
            $mysql_dir = Join-Path $install_prefix "mysql/$mysql_ver"
            $myslqd_prog = Join-Path $mysql_dir 'bin/mysqld.exe'
            Start-Process $myslqd_prog -ArgumentList "--datadir `"$mysqld_data`"" -WorkingDirectory $mysqld_cwd -WindowStyle Hidden
        }
    }
    $actions.stop = @{
        nginx = {
            taskkill /f /im nginx.exe 2>$null
            $Global:LASTEXITCODE = 0
        }
        php   = {
            taskkill /f /im php-cgi.exe 2>$null
            taskkill /f /im intelliphp.ls.exe 2>$null
            $Global:LASTEXITCODE = 0
        }
        mysql = {
            taskkill /f /im mysqld.exe 2>$null
            $Global:LASTEXITCODE = 0
        }
    }
}
elseif ($IsUbuntu) {
    # Ubuntu Linux
    # local dev, use current user to run mysql
    # please use `mysql` as mysqld runner user when publish your site
    $Script:qweb_user = whoami
    $actions.fetch = @{
        nginx = {
            $nginx_dir = "$install_prefix/nginx/$nginx_ver"
            if (!(Test-Path $nginx_dir -PathType Container)) {
                fetch_pkg -url "https://nginx.org/download/nginx-${nginx_ver}.tar.gz" -prefix 'cache'
                $nginx_src = Join-Path $download_path "nginx-${nginx_ver}"
                Push-Location $nginx_src
                sudo apt install --allow-unauthenticated --yes libpcre3 libpcre3-dev libssl-dev
                ./configure --with-http_ssl_module --prefix=$nginx_dir
                make ; make install
                Pop-Location
            }
        }
        php   = {
            # ensure we can install old releases of php on ubuntu
            $php_ppa = $(grep -ri '^deb.*ondrej/php' /etc/apt/sources.list /etc/apt/sources.list.d/)
            if (!$php_ppa) {
                sudo LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php
                sudo apt update
            }

            $php_pkg = "php$($php_ver.Major).$($php_ver.Minor)"
            sudo apt install --allow-unauthenticated --yes $php_pkg $php_pkg-fpm $php_pkg-mysql $php_pkg-curl $php_pkg-cgi
        }
        mysql = {
            # sudo apt install mysql-server
            # we use offical deb to install latest mysql version 9.1.0
            $os_info = $PSVersionTable.OS.Split(' ')
            $os_name = $os_info[0].ToLower()
            $os_ver = $os_info[1].Split('.')
            $os_id = "$os_name$($os_ver[0]).$($os_ver[1])"
            $mysql_server_deb_bundle = "mysql-server_$mysql_ver-1${os_id}_amd64.deb-bundle.tar"
            if ($mysql_ver -eq $mysql_latest) {
                fetch_pkg "https://cdn.mysql.com//Downloads/MySQL-$($mysql_ver.Major).$($mysql_ver.Minor)/$mysql_server_deb_bundle" -prefix "cache/mysql-$mysql_ver"
            }
            else {
                fetch_pkg "https://downloads.mysql.com/archives/get/p/23/file/$mysql_server_deb_bundle" -prefix "cache/mysql-$mysql_ver"
            }

            $mysqld_cmd = Get-Command mysqld -ErrorAction SilentlyContinue
            if (!$mysqld_cmd) {
                Push-Location $download_path/mysql
                sudo apt install --allow-unauthenticated --yes libaio1 libmecab2
                sudo dpkg -i mysql-common_*.deb
                sudo dpkg -i mysql-community-client-plugins*amd64.deb
                sudo dpkg -i mysql-community-client-core*amd64.deb
                sudo dpkg -i mysql-community-client_*amd64.deb
                sudo dpkg -i libmysqlclient*amd64.deb
                sudo dpkg -i mysql-community-server-core*amd64.deb
                sudo dpkg -i mysql-client_*amd64.deb
                sudo dpkg -i mysql-community-server_*amd64.deb
                sudo dpkg -i mysql-server_*amd64.deb
                sudo dpkg --configure -a
                Pop-Location
            }
        }
    }
    $actions.init = @{
        php   = {
            $php_ini_dir = "/etc/php/$($php_ver.Major).$($php_ver.Minor)/cgi"
            $lines, $mods = mod_php_ini "$php_ini_dir/php.ini" $false
            if ($mods) {
                Set-Content -Path "$download_path/php.ini" -Value $lines
                sudo cp -f "$download_path/php.ini" "$php_ini_dir/php.ini"
            }
            else {
                println "php init: nothing need to do"
            }
        }
        mysql = {
            if (Test-Path /var/lib/mysql* -PathType Container) {
                $anwser = if ($force) { Read-Host "Are you sure force reinit mysqld, will lost all database(y/N)?" } else { 'N' }
                if ($anwser -inotlike 'y*') {
                    println "mysql init: nothing need to do"
                    return
                }
            }

            $mysql_tmp_dirs = @('/var/run/mysql', '/var/run/mysqld', '/var/lib/mysql', '/var/lib/mysql-files', '/var/log/mysql')
            foreach ($tmp_dir in $mysql_tmp_dirs) {
                sudo rm -rf $tmp_dir
                sudo mkdir -p $tmp_dir
                sudo chown -R ${qweb_user}:$qweb_user $tmp_dir
            }

            sudo chown -R ${qweb_user}:$qweb_user /etc/mysql
            sudo chmod -R 750 /var/run/mysql /var/lib/mysql* /var/log/mysql /etc/mysql
            ls -l /var/run | grep mysql
            ls -l /var/lib | grep mysql
            ls -l /var/log | grep mysql

            sudo mysqld --initialize-insecure --user=$qweb_user | Out-Host
            
            $mysql_auth_backport = [int]$local_props['mysql_auth_backport']
            $mysql_pass = $local_props['mysql_pass']
            if ($mysql_auth_backport) {
                Copy-Item (Join-Path $PSScriptRoot "etc/mysql/my.ini") '/etc/mysql/conf.d/mysql.cnf' -Force
                $init_cmds = "use mysql; ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$mysql_pass'; FLUSH PRIVILEGES;"
            }
            else {
                $init_cmds = "use mysql; UPDATE user SET authentication_string='' WHERE user='root'; ALTER user 'root'@'localhost' IDENTIFIED BY '$mysql_pass';"
            }

            bash -c "sudo mysqld --user=$qweb_user >/dev/null 2>&1 &"
            println "Wait mysqld ready ..."
            Start-Sleep -Seconds 3
            mysql -u root -e $init_cmds | Out-Host
            pkill -f mysqld
        }
    }
    $actions.start = @{
        nginx = {
            $nginx_dir = Join-Path $install_prefix "nginx/$nginx_ver"
            $nginx_conf = Join-Path $PSScriptRoot "etc/nginx/$nginx_ver/nginx.conf"
            Push-Location $nginx_dir
            bash -c "sudo ./sbin/nginx -t -c '$nginx_conf'" | Out-Host
            bash -c "sudo ./sbin/nginx -c '$nginx_conf' >/dev/null 2>&1 &"
            Pop-Location
        }
        php   = {
            bash -c "nohup sudo php-cgi -b 127.0.0.1:9000 >/dev/null 2>&1 &"
        }
        mysql = {
            bash -c "nohup sudo mysqld --user=$qweb_user >/dev/null 2>&1 &"
        }
    }
    $actions.stop = @{
        nginx = {
            sudo pkill -f nginx
        }
        php   = {
            sudo pkill -f php-cgi
        }
        mysql = {
            sudo pkill -f mysqld
        }
    }
}
else {
    throw "Unsupported OS: $($PSVersionTable.OS)"
}

$actions.init.nginx = {
    if ($IsWin) {
        $qweb_root = $PSScriptRoot.Replace('\', '/')
    }
    else {
        $qweb_root = $PSScriptRoot
    }

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
        } else {
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
            elseif($line_text.Contains('@QWEB_CERT_DIR@')) {
                $lines[$line_index] = $line_text.Replace('@QWEB_CERT_DIR@', $qweb_rel_cert_dir)
            }
            elseif (!$IsWin -and $line_text.Contains('nobody')) {
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
}

if ($?) {
    println "The operation successfully."
}
else {
    throw "The operation fail!"
}
