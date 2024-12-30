## xweb - A nginx + mysql + php environment


## Quick Start

- Install [powershell 7](https://github.com/PowerShell/PowerShell) and open pwsh terminal
- Clone https://github.com/simdsoft/xweb.git and goto to root directory of xweb
- `./xweb install`
- `./xweb start`
- visit: https://xweb.dev/phpinfo.php to check does php works
- visit https://sandbox.xweb.dev/phpmyadmin to manage database

Note:  

if xweb was moved to other location or you modify domain name in `local.properties`, 
then please re-run `xweb.ps1 init nginx -f` and restart nginx by `xweb.ps1 restart nginx`

## xweb-cmdline usage

`xweb.ps1 action_name targets`

- *`action_name`*: `install`, `start`, `stop`, `restart`
- *`targets`*(optional): possible values: `all`, `nginx`, `php`, `phpmyadmin`, `mysql`

examples:  

- `xweb.ps1 install`: install WNMP on windows or LNMP on ubuntu linux
- `xweb.ps1 start`: start nginx, mysqld, php-cgi
- `xweb.ps1 stop`: stop nginx, mysqld, php-cgi
- `xweb.ps1 restart`: restart nginx, mysqld, php-cgi
- `xweb.ps1 passwd mysql`: reset mysqld password

## Support platforms

- Windows: ready
- Ubuntu Linux: testing

Note:  

- nginx, mysql runas current user
- php runas root

## Export DB from aliyun

1. Use aliyun DMS, ensure follow option was checked

   - Data And Structure
   - Compress insert statements


2. Aliyun website control console

   - Delete: `FOREIGN_KEY_CHECKS` statements at HAED and tail
   - Delete UTF-8 BOM of file
