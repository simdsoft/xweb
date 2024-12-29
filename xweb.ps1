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

$xweb_ver = '1.1.0'

Set-Alias println Write-Host

println "xweb version $xweb_ver"

if($version) { return }

$Global:IsWin = $IsWindows -or ("$env:OS" -eq 'Windows_NT')
$Global:IsUbuntu = !$IsWin -and ($PSVersionTable.OS -like 'Ubuntu *')

. (Join-Path $PSScriptRoot 'manifest.ps1')

$download_path = Join-Path $PSScriptRoot 'cache'
$install_prefix = $PSScriptRoot

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
        [Parameter(Mandatory=$true)]
        $InputObject
    )

    $props = @{}

    foreach($_ in $InputObject) {
        $key,$val = parse_prop $_
        if ($key) {
            $props[$key] = $val
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
        if (!$prefix) {
            $prefix = $install_prefix
        } else {
            $prefix = resolve_path $prefix
        }
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
            $props_lines = @("mysql_pass=$mysql_pass", "mysql_auth_backport=0", "server_names=sandbox.xweb.com")
            Set-Content -Path $prop_file -Value $props_lines
        }
        $Script:local_props = ConvertFrom-Props $props_lines

        $Script:php_ver = [version]$php_ver
        $is_php8 = $php_ver -ge [Version]'8.0.0'
        $Script:php_vs = @('vc15', 'vs17')[$is_php8]
    }
}

function mod_php_ini($php_ini_file, $do_setup) {
    $match_ext = {
        param($ext, $exts)
        foreach($item in $exts) {
            if($ext -like $item) {
                return $true
            }
        }
        return $false
    }

    $upload_props = @{upload_max_filesize='64M'; post_max_size='64M'; memory_limit='128M'}

    $exclude_exts = @('*=oci8_12c*', '*=pdo_firebird*', '*=pdo_oci*', '*=snmp*')

    $lines = Get-Content -Path $php_ini_file
    $line_index = 0
    $mods = 0
    foreach($line_text in $lines) {
        if($line_text -like ';extension_dir = "ext"') {
            if ($do_setup) {
                $lines[$line_index] = 'extension_dir = "ext"'
                ++$mods
            }
        } 
        elseif($line_text -like '*extension=*') {
            if ($do_setup) {
                if ($line_text -like ';extension=*') {
                    if (-not (&$match_ext $line_text $exclude_exts)) {
                        $line_text = $line_text.Substring(1)
                        $lines[$line_index] = $line_text
                        ++$mods
                    }
                }

                $match_info = [Regex]::Match($line_text, '(?<!;)\bextension=([^;]+)')
                if($match_info.Success -and $line_text.StartsWith('extension=')) {
                    println "php.ini: $($match_info.value)"
                }
            }
        }
        else {
            $key,$val = parse_prop $line_text
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
        nginx = {
            fetch_pkg "https://nginx.org/download/nginx-${nginx_ver}.zip"  -exrep "nginx-${nginx_ver}=${nginx_ver}" -prefix 'bin/nginx'
        }
        php = {
            if ("$php_ver" -eq $php_latset) {
                fetch_pkg "https://windows.php.net/downloads/releases/php-${php_ver}-Win32-$php_vs-x64.zip" -exrep "bin/php/${php_ver}"
            } else {
                fetch_pkg "https://windows.php.net/downloads/releases/archives/php-${php_ver}-Win32-$php_vs-x64.zip" -exrep "bin/php/${php_ver}"
            }
        }
        phpmyadmin = {
            fetch_pkg "https://files.phpmyadmin.net/phpMyAdmin/${phpmyadmin_ver}/phpMyAdmin-${phpmyadmin_ver}-all-languages.zip" -exrep "phpMyAdmin-${phpmyadmin_ver}-all-languages=${phpmyadmin_ver}" -prefix 'apps/phpmyadmin'
        }
        mysql = {
            if ($mysql_ver -eq $mysql_latest) {
                fetch_pkg "https://cdn.mysql.com//Downloads/MySQL-$($mysql_ver.Major).$($mysql_ver.Minor)/mysql-$mysql_ver-winx64.zip" -exrep "mysql-${mysql_ver}-winx64=${mysql_ver}" -prefix 'bin/mysql'
            }
            else {
                fetch_pkg "https://downloads.mysql.com/archives/get/p/23/file/mysql-${mysql_ver}-winx64.zip" -exrep "mysql-${mysql_ver}-winx64=${mysql_ver}" -prefix 'bin/mysql'
            }
        }
        mariadb = {
            fetch_pkg "https://mirrors.tuna.tsinghua.edu.cn/mariadb///mariadb-$mariadb_ver/winx64-packages/mariadb-$mariadb_ver-winx64.zip" -exrep "mariadb-$mariadb_ver-winx64=$mariadb_ver" -prefix 'bin/mariadb'
        }
    }
    $actions.init = @{
        php = {
            $php_dir = Join-Path $PSScriptRoot "bin/php/$php_ver"
            $php_ini = (Join-Path $php_dir 'php.ini')
        
            if (!(Test-Path $php_ini -PathType Leaf) -or $force) {
                $lines, $_ = mod_php_ini (Join-Path $php_dir 'php.ini-production') $true
        
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
            $xdebug_ver = $xdebug_ver_map[$xdebug_php_ver]
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

            $mysql_bin = Join-Path $mysql_dir 'bin'

            Push-Location $mysql_bin
            & .\mysqld --initialize-insecure

            $mysql_pass = $local_props['mysql_pass']
            $mysql_auth_backport = [int]$local_props['mysql_auth_backport']
            if ($mysql_auth_backport) {
                Copy-Item (Join-Path $PSScriptRoot "etc/mysql/my.ini") $mysql_dir -Force
                $init_cmds = "use mysql; ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$mysql_pass'; FLUSH PRIVILEGES;"
            } else {
                $init_cmds = "use mysql; UPDATE user SET authentication_string='' WHERE user='root'; ALTER user 'root'@'localhost' IDENTIFIED BY '$mysql_pass';"
            }

            Start-Process .\mysqld.exe -ArgumentList '--console'
            println "Wait mysqld ready ..."
            Start-Sleep -Seconds 3
            & .\mysql -u root -e $init_cmds | Out-Host
            Pop-Location
        }
    }
    $actions.start = @{
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
    $actions.stop = @{
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
} elseif($IsUbuntu) { # Ubuntu Linux
    # local dev, use current user to run mysql
    # please use `mysql` as mysqld runner user when publish your site
    $Script:mysql_user = whoami
    $actions.fetch = @{
        nginx = {
            $nginx_dir = "$install_prefix/bin/nginx/$nginx_ver"
            if (!(Test-Path $nginx_dir -PathType Container)) {
                fetch_pkg -url "https://nginx.org/download/nginx-${nginx_ver}.tar.gz" -prefix 'cache'
                $nginx_src = Join-Path $install_prefix "cache/nginx-${nginx_ver}"
                Push-Location $nginx_src
                sudo apt install --allow-unauthenticated --yes libpcre3 libpcre3-dev
                ./configure --with-http_ssl_module --prefix=$nginx_dir
                make ; make install
                Pop-Location
            }
        }
        php = {
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
            # TODO: try https://repo.mysql.com//mysql-apt-config_0.8.33-1_all.deb , step
            #  1. sudo dpkg -i mysql-apt-config_0.8.33-1_all.deb
            #  2. sudo apt update
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
        php = {
            $php_ini_dir = "/etc/php/$($php_ver.Major).$($php_ver.Minor)/cgi"
            $lines, $mods = mod_php_ini "$php_ini_dir/php.ini" $false
            if ($mods) {
                Set-Content -Path "$download_path/php.ini" -Value $lines
                sudo cp -f "$download_path/php.ini" "$php_ini_dir/php.ini"
            } else {
                println "init php: nothing need to do"
            }
        }
        mysql = {
            if (Test-Path /var/lib/mysql* -PathType Container) {
                if (!$force) {
                    println "Skip init mysql due to /var/lib/mysql exists"
                    return
                }
                $anwser = Read-Host "Are you sure force reinit mysqld, will lost all database(y/N)?"
                if ($anwser -inotlike 'y*') {
                    return
                }
            }

            $mysql_tmp_dirs = @('/var/run/mysql', '/var/run/mysqld', '/var/lib/mysql', '/var/lib/mysql-files', '/var/log/mysql')
            foreach($tmp_dir in $mysql_tmp_dirs) {
                sudo rm -rf $tmp_dir
                sudo mkdir -p $tmp_dir
                sudo chown -R ${mysql_user}:$mysql_user $tmp_dir
            }

            sudo chown -R ${mysql_user}:$mysql_user /etc/mysql
            sudo chmod -R 750 /var/run/mysql /var/lib/mysql* /var/log/mysql /etc/mysql
            ls -l /var/run | grep mysql
            ls -l /var/lib | grep mysql
            ls -l /var/log | grep mysql

            sudo mysqld --initialize-insecure --user=$mysql_user | Out-Host
            
            $mysql_auth_backport = [int]$local_props['mysql_auth_backport']
            $mysql_pass = $local_props['mysql_pass']
            if ($mysql_auth_backport) {
                Copy-Item (Join-Path $PSScriptRoot "etc/mysql/my.ini") '/etc/mysql/conf.d/mysql.cnf' -Force
                $init_cmds = "use mysql; ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$mysql_pass'; FLUSH PRIVILEGES;"
            } else {
                $init_cmds = "use mysql; UPDATE user SET authentication_string='' WHERE user='root'; ALTER user 'root'@'localhost' IDENTIFIED BY '$mysql_pass';"
            }

            bash -c "sudo mysqld --user=$mysql_user >/dev/null 2>&1 &"
            println "Wait mysqld ready ..."
            Start-Sleep -Seconds 3
            mysql -u root -e $init_cmds | Out-Host
            pkill -f mysqld
        }
    }
    $actions.start = @{
        nginx = {
            $nginx_dir = Join-Path $install_prefix "bin/nginx/$nginx_ver"
            $nginx_conf = Join-Path $PSScriptRoot "etc/nginx/$nginx_ver/nginx.conf"
            Push-Location $nginx_dir
            bash -c "sudo ./sbin/nginx -t -c '$nginx_conf'" | Out-Host
            bash -c "sudo ./sbin/nginx -c '$nginx_conf' >/dev/null 2>&1 &"
            Pop-Location
        }
        php = {
            bash -c "nohup sudo php-cgi -b 127.0.0.1:9000 >/dev/null 2>&1 &"
        }
        mysql = {
            bash -c "nohup sudo mysqld --user=$mysql_user >/dev/null 2>&1 &"
        }
    }
    $actions.stop = @{
        nginx = {
            sudo pkill -f nginx
        }
        php = {
            sudo pkill -f php-cgi
        }
        mysql = {
            sudo pkill -f mysqld
        }
    }
} else {
    throw "Unsupported OS: $($PSVersionTable.OS)"
}

$actions.init.nginx = {
    if($IsWin) {
        $xweb_root = $PSScriptRoot.Replace('\', '/')
    } else {
        $xweb_root = $PSScriptRoot
    }

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
        foreach($line_text in $lines) {
            if ($line_text.Contains('@XWEB_ROOT@')) {
                $lines[$line_index] = $line_text.Replace('@XWEB_ROOT@', $xweb_root)
            } elseif($line_text.Contains('@XWEB_SERVER_NAMES@')) {
                $lines[$line_index] = $line_text.Replace('@XWEB_SERVER_NAMES@', $local_props['server_names'])
            }
            elseif ($line_text.Contains('nobody')) {
                $line_text = $line_text.Replace('nobody', "$(whoami)")
                if ($line_text.StartsWith('#')) { $line_text = $line_text.TrimStart('#') }
                $lines[$line_index] = $line_text
            }
            ++$line_index
        }
        Set-Content -Path (Join-Path $nginx_conf_dir 'nginx.conf') -Value $lines
    }

    if ($IsUbuntu) {
        # $nginx_grp = $(cat /etc/passwd | grep nginx)
        # if (!$nginx_grp) {
        #     sudo groupadd nginx
        #     sudo useradd -g nginx -s /sbin/nologin nginx
        # }
        sudo chown -R vmroot:vmroot $xweb_root/htdocs
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

if($?) {
    println "The operation successfully."
}
else {
    throw "The operation fail!"
}
