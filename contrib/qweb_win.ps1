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
            $xdebug_lines = Get-Content -Path (Join-Path $qweb_root 'etc/php/xdebug.ini')
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
            $my_conf_file = Join-Path $qweb_root 'etc/mysql/my.ini'
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
        $nginx_conf = Join-Path $qweb_root "etc/nginx/$nginx_ver/nginx.conf"
        $nginx_cwd = Join-Path $qweb_root 'var/nginx'
        Push-Location $nginx_cwd
        &$nginx_prog -t -c $nginx_conf | Out-Host
        Pop-Location
        Start-Process $nginx_prog -ArgumentList "-c `"$nginx_conf`"" -WorkingDirectory $nginx_cwd -WindowStyle Hidden
    }
    php   = {
        $php_dir = Join-Path $install_prefix "php/$php_ver"
        $php_cgi_prog = Join-Path $php_dir 'php-cgi.exe'
        $php_cgi_cwd = Join-Path $qweb_root 'var/php-cgi'
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
