
# nginx
#  https://nginx.org/download
#  https://nginx.org/download/nginx-1.27.3.zip
$nginx_ver = '1.27.3'

# mysql
#  https://dev.mysql.com/downloads/mysql/
#  latest:
#   https://cdn.mysql.com//Downloads/MySQL-9.2/mysql-9.2.0-winx64.zip
#   https://cdn.mysql.com//Downloads/MySQL-9.2/mysql-9.2.0-macos15-arm64.tar.gz
#  archives:
#   https://downloads.mysql.com/archives/get/p/23/file/mysql-8.4.2-winx64.zip
#   https://downloads.mysql.com/archives/get/p/23/file/mysql-9.1.0-macos14-arm64.tar.gz
$mysql_latest = [Version]'9.2.0'
$mysql_ver = [Version]'9.2.0'
# $mariadb_ver = '11.6.2'

# php
#  https://windows.php.net/download/
#  https://windows.php.net/downloads/releases/php-8.4.2-Win32-vs17-x64.zip
#  https://windows.php.net/downloads/releases/archives/php-7.4.33-Win32-vc15-x64.zip
$php_latset = [Version]'8.4.3'
$php_ver = [Version]'7.4.33' # '8.4.3'

# php xdebug ext
#  https://xdebug.org/files/php_xdebug-3.1.6-7.4-vc15-x86_64.dll
#  https://xdebug.org/files/php_xdebug-3.4.0-8.4-vs17-x86_64.dll
$xdebug_ver_map = @{'7.4' = '3.1.6' ; '8.4' = '3.4.1'}

# phpmyadmin
#  https://files.phpmyadmin.net
#  https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.zip
#  php8.4 require phpMyAdmin 6.0+snapshot: https://files.phpmyadmin.net/snapshots/phpMyAdmin-6.0%2bsnapshot-all-languages.zip
$phpmyadmin_ver = '5.2.2'


if ($IsMacOS -or $IsLinux) {
    $php_ver = [Version]'8.4.3'
    $phpmyadmin_ver = '6.0.0'
}