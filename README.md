## xweb - A nginx + mysql + php environment

### commands:

`xweb.ps1 action_name targets`

- *`action_name`*: `fetch`, `init`, `install`, `start`, `stop`, `restart`
- *`targets`*: optional, possible values: `all`, `nginx`, `php`, `phpmyadmin`, `mysql`

examples:  

- `xweb.ps1 install`
- `xweb.ps1 fetch`
- `xweb.ps1 init`
- `xweb.ps1 start`
- `xweb.ps1 stop`
- `xweb.ps1 restart`

Note: if xweb was moved to other location, please rerun `xweb.ps1 init nginx -f`

## 导入数据库失败解决方案

1. 阿里云新版本 DMS 导出的数据库，没有 create table 语句，不能一键导入?  

   解决方案: 导出时选择导出“数据和结构”， 勾选压缩 insert 语句


2. 网页导出  

   删除首尾: `FOREIGN_KEY_CHECKS` 相关语句
   去除 UTF-8 BOM

## 重置 mysql 密码:

- Linux
    vim /etc/my.cnf
    ```conf
    [mysql]
    skip-grant-table
    ```

    ```sh
    systemctl stop mysqld.service
    systemctl start mysqld.service
    mysql –u root
    ```

- Windows

1. 执行：`mysqld --skip-grant-tables`（窗口会一直停止）　
2. 然后另外打开一个命入令行窗口，执行 mysql（或者直接进入Mysql Command Line Cilent），此时无需输入密码即可进入。
