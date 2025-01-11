## qweb - A quick web environment(nginx + mysql + php) supporting both windows and ubuntu

[![Latest Release](https://img.shields.io/github/v/release/simdsoft/qweb?label=release)](https://github.com/simdsoft/qweb/releases)

## Quick Start

### install and start service
1. Install [powershell 7](https://github.com/PowerShell/PowerShell) and open pwsh terminal
2. Clone https://github.com/simdsoft/qweb.git and goto to root directory of qweb
3. `./qweb install`
4. `./etc/certs/gen.sh`, on windows, please enter wsl to execute script `gen.sh`
5. `./qweb start`

### visit local web

1. Add domain `sandbox.qweb.dev` to your system hosts
2. Install `./etc/certs/ca-cer.crt` to `Trusted Root Certificate Authorities` of current user
3. visit web on your browser
   - http:
      - http://localhost/phpinfo.php to check does php works
      - http://localhost/phpmyadmin to manage database
   - https
      - https://sandbox.qweb.dev/phpinfo.php to check does php works
      - https://sandbox.qweb.dev/phpmyadmin to manage database
   visit by curl.exe: `curl -v --ssl-no-revoke https://sandbox.qweb.dev/phpinfo.php`
Note:  

if qweb was moved to other location or you modify domain name in `local.properties`, 
then please re-run `qweb init nginx -f` and restart nginx by `qweb restart nginx`

## qweb-cmdline usage

`qweb action_name targets`

- *`action_name`*: `install`, `start`, `stop`, `restart`
- *`targets`*(optional): possible values: `all`, `nginx`, `php`, `phpmyadmin`, `mysql`

examples:  

- `qweb install`: install WNMP on windows or LNMP on ubuntu linux
- `qweb start`: start nginx, mysqld, php-cgi
- `qweb stop`: stop nginx, mysqld, php-cgi
- `qweb restart`: restart nginx, mysqld, php-cgi
- `qweb passwd mysql`: reset mysqld password

## Support platforms

- ✅ Windows
- ✅ Ubuntu

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
