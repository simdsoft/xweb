## xweb - A nginx + mysql + php environment

[![Latest Release](https://img.shields.io/github/v/release/simdsoft/xweb?label=release)](https://github.com/simdsoft/xweb/releases)

## Quick Start

### install and start service
1. Install [powershell 7](https://github.com/PowerShell/PowerShell) and open pwsh terminal
2. Clone https://github.com/simdsoft/xweb.git and goto to root directory of xweb
3. `./xweb install`
4. `./etc/certs/gen.sh`, on windows, please enter wsl to execute script `gen.sh`
5. `./xweb start`

### visit local web

1. Add domain `sandbox.xweb.dev` to your system hosts
2. Install `./etc/certs/ca-cer.crt` to `Trusted Root Certificate Authorities` of current user
3. visit web on your browser
  - https://sandbox.xweb.dev/phpinfo.php to check does php works
  - https://sandbox.xweb.dev/phpmyadmin to manage database

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
