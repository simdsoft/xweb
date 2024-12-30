## xweb - A nginx + mysql + php environment

### commands:

`xweb.ps1 action_name targets`

- *`action_name`*: `install`, `start`, `stop`, `restart`
- *`targets`*(optional): possible values: `all`, `nginx`, `php`, `phpmyadmin`, `mysql`

## Support platforms

- Windows: ready
- Ubuntu Linux: testing
   - nginx, mysql runas current user
   - php runas root

examples:  

- `xweb.ps1 install`: install WNMP on windows or LNMP on ubuntu linux
- `xweb.ps1 start`: start nginx, mysqld, php-cgi
- `xweb.ps1 stop`: stop nginx, mysqld, php-cgi
- `xweb.ps1 restart`: restart nginx, mysqld, php-cgi
- `xweb.ps1 passwd mysql`: reset mysqld password

Note: if xweb was moved to other location, please rerun `xweb.ps1 init nginx -f`

## Export DB from aliyun


1. Use aliyun DMS, ensure follow option was checked

   - Data And Structure
   - Compress insert statements


2. Aliyun website control console

   - Delete: `FOREIGN_KEY_CHECKS` statements at HAED and tail
   - Delete UTF-8 BOM of file
