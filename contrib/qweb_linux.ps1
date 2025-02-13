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
            Copy-Item (Join-Path $qweb_root "etc/mysql/my.ini") '/etc/mysql/conf.d/mysql.cnf' -Force
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
        $nginx_conf = Join-Path $qweb_root "etc/nginx/$nginx_ver/nginx.conf"
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
