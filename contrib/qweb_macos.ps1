$actions.fetch = @{
    nginx = {
        $nginx_dir = "$install_prefix/nginx/$nginx_ver"
        if (!(Test-Path $nginx_dir -PathType Container)) {
            fetch_pkg -url "https://nginx.org/download/nginx-${nginx_ver}.tar.gz" -prefix 'cache'
            $nginx_src = Join-Path $download_path "nginx-${nginx_ver}"
            Push-Location $nginx_src
            ./configure --with-http_ssl_module --prefix=$nginx_dir
            make ; make install
            Pop-Location
        }
    }

    php = {
        brew install php
    }

    mysql = {
        $tuple = "macos15-$qweb_host_cpu"
        if ($mysql_ver -eq $mysql_latest) {
            fetch_pkg "https://cdn.mysql.com//Downloads/MySQL-$($mysql_ver.Major).$($mysql_ver.Minor)/mysql-$mysql_ver-$tuple.tar.gz" -exrep "mysql-${mysql_ver}-$tuple=${mysql_ver}" -prefix 'opt/mysql'
        }
        else {
            fetch_pkg "https://downloads.mysql.com/archives/get/p/23/file/mysql-${mysql_ver}-$tuple.tar.gz" -exrep "mysql-${mysql_ver}-$tuple=${mysql_ver}" -prefix 'opt/mysql'
        }
    }
}

$actions.init = @{
    php   = {
        $php_ver = [Version]([Regex]::Match($(php -v), '(\d+\.)+(\*|\d+)(\-[a-z0-9]+)?').Value)
        $php_ini_file = "/opt/homebrew/etc/php/$($php_ver.Major).$($php_ver.Minor)/php.ini"
        $lines, $mods = mod_php_ini $php_ini_file $false
        if ($mods) {
            Set-Content -Path $php_ini_file -Value $lines
        }
        else {
            println "php init: nothing need to do"
        }
    }

    mysql = {
        # enable plugin mysql_native_password, may don't required
        $mysql_dir = Join-Path $install_prefix "mysql/$mysql_ver"
        if (Test-Path $mysqld_data -PathType Container) {
            $anwser = if ($force) { Read-Host "Are you sure force reinit mysqld, will lost all database(y/N)?" } else { 'N' }
            if ($anwser -inotlike 'y*') {
                println "mysql init: nothing need to do"
                return
            }
            
            println "Deleting $mysqld_data"
            pkill -f mysqld 2>$null
            Remove-Item $mysqld_data -Recurse -Force
        }

        $mysql_bin = Join-Path $mysql_dir 'bin'
        $mysqld_prog = Join-Path $mysql_bin 'mysqld'
        $mysql_prog = Join-Path $mysql_bin 'mysql'
        
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
            pkill -f mysqld 2>$null
        }
        Pop-Location
    }
}

$actions.start = @{
    nginx = {
        $nginx_dir = Join-Path $install_prefix "nginx/$nginx_ver"
        $nginx_conf = Join-Path $qweb_root "etc/nginx/$nginx_ver/nginx.conf"
        Push-Location $nginx_dir
        bash -c "./sbin/nginx -t -c '$nginx_conf'" | Out-Host
        bash -c "./sbin/nginx -c '$nginx_conf' >/dev/null 2>&1 &"
        Pop-Location
    }
    php   = {
        bash -c "nohup php-cgi -b 127.0.0.1:9000 >/dev/null 2>&1 &"
    }
    mysql = {
        # bash -c "nohup sudo mysqld --user=$qweb_user >/dev/null 2>&1 &"
        $mysql_dir = Join-Path $install_prefix "mysql/$mysql_ver"
        $myslqd_prog = Join-Path $mysql_dir 'bin/mysqld'
        Start-Process $myslqd_prog -ArgumentList "--datadir `"$mysqld_data`"" -WorkingDirectory $mysqld_cwd
    }
}

function  status-process ($process_name) {
    $hint = ps -ef | grep $process_name
    if ($hint) {
        println "The $process_name running."
    } else {
        println "The $process_name not started."
    }
}

$actions.status = @{
    nginx = {
        status-process nginx
    }
    php = {
        status-process php-cgi
    }
    mysql = {
        status-process mysqld
    }
}

$actions.stop = @{
    nginx = {
        pkill -f nginx
    }
    php   = {
        pkill -f php-cgi
    }
    mysql = {
        pkill -f mysqld
    }
}
