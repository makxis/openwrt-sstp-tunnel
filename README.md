# openwrt-sstp-tunnel
Интерактивный установщик SSTP-клиента для OpenWrt.
Скрипт настраивает защищённый SSTP-тоннель от OpenWrt-роутера к SSTP-серверу и открывает через VPN только минимально необходимый доступ к самому роутеру:
- SSH — порт `22`
- HTTP — порт `80`
- ICMP ping
По умолчанию доступ в локальную сеть клиента не открывается.
---

## Назначение
Скрипт предназначен для безопасного удалённого доступа к OpenWrt-роутеру без публикации файлов, подписок или интерфейсов управления в открытой сети.
Типовая схема:
```text
Администратор / сервер управления
        │
        │ SSTP
        ▼
OpenWrt-роутер клиента
```
Дополнительно скрипт может настроить маршрут к серверной LAN-сети за SSTP-сервером, если сам OpenWrt-роутер должен забирать файл с Debian-сервера.
Расширенная схема:
```text
SSTP-сеть:              172.16.66.0/24
LAN клиента:            192.168.1.0/24
LAN за SSTP-сервером:   192.168.65.0/24
Debian/file server:     192.168.65.10:80
```
---
## Быстрая установка
Рекомендуемый запуск на OpenWrt:
```sh
wget -O - https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main/install.sh | sh -s install
```
---
## Ручная установка
```sh
cd /root
wget -O install.sh https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main/install.sh
chmod +x install.sh
sh install.sh install
```
---
## Проверка статуса
Если скрипт сохранён на роутере:
```sh
sh /root/install.sh status
```
Если нужно выполнить проверку без сохранения файла:
```sh
wget -O - https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main/install.sh | sh -s status
```
Скрипт покажет:
- установленную версию `sstp-client`;
- состояние интерфейса `sstp`;
- активные процессы `sstpc` и `pppd`;
- последние SSTP/PPP-логи;
- маршрут до file-server, если включён дополнительный доступ к серверной LAN.
---
## Удаление настройки
Если скрипт сохранён на роутере:
```sh
sh /root/install.sh remove
```
Если нужно выполнить удаление без сохранения файла:
```sh
wget -O - https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main/install.sh | sh -s remove
```
При удалении убираются:
- интерфейс `network.sstp`;
- firewall-зона `sstp`;
- правила доступа SSH/HTTP/ping из SSTP;
- маршрут к серверной LAN, если он был добавлен;
- правило доступа к Debian/file-server, если оно было добавлено;
- hotplug-автозапуск SSTP после подъёма WAN.
---
## Что запрашивает установщик
При запуске установки скрипт попросит:
```text
SSTP server:
Username:
Password:
```
## Доступ через SSTP
После установки через SSTP разрешено только:
```text
SSTP → OpenWrt:22
SSTP → OpenWrt:80
SSTP → OpenWrt:ICMP ping
```
Доступ из SSTP в LAN клиента не включается.
Это сделано специально, чтобы не открывать всю локальную сеть клиента.
---
## Опциональный доступ к file-server за SSTP-сервером
Если OpenWrt-роутеру нужно самому забирать файл с Debian-сервера, находящегося за SSTP-сервером, при установке можно включить дополнительный режим:
```text
Add route to LAN behind SSTP server and allow router to one file server [y/N]:
```
Если ответить:
```text
y
```
скрипт предложит значения по умолчанию:
```text
Server-side LAN CIDR [192.168.65.0/24]:
Debian/file server IP [192.168.65.10]:
Debian/file server TCP port [80]:
```
Если просто нажать `Enter`, будут использованы дефолтные значения:
```text
192.168.65.0/24
192.168.65.10
80
```
После этого OpenWrt сможет обращаться к файлу, например:
```sh
wget -O - http://192.168.65.10/file.txt
```
или:
```sh
wget -O /tmp/subscription.txt http://192.168.65.10/subscription.txt
```
Этот режим не открывает LAN клиента наружу. Он только разрешает самому OpenWrt-роутеру сходить через SSTP к одному серверу на один TCP-порт.
---
## Проверка маршрута до Debian/file-server
На OpenWrt:
```sh
ip route get 192.168.65.10
```
Ожидаемо маршрут должен идти через SSTP/PPP-интерфейс.
Проверка скачивания файла:
```sh
wget -O - http://192.168.65.10/
```
или:
```sh
wget -O - http://192.168.65.10/subscription.txt
```
---
## Особенность OpenWrt 24.10.x
В OpenWrt `24.10.x` пакет `sstp-client 1.0.20-r1` может ломать запуск PPP с ошибкой:
```text
pppd: unrecognized option ''
```
Поэтому скрипт принудительно откатывает `sstp-client` до рабочей версии:
```text
sstp-client 1.0.15-1
```
из репозитория OpenWrt `23.05.5`.
Это необходимо для стабильной работы SSTP на OpenWrt `24.10.x`.
---
## Firewall-модель
Скрипт создаёт отдельную firewall-зону:
```text
sstp
```
Базовая политика зоны закрытая:
```text
input   REJECT
forward REJECT
output  REJECT
```
Затем добавляются только точечные разрешения:
```text
Allow-SSH-from-SSTP
Allow-HTTP-from-SSTP
Allow-Ping-from-SSTP
```
Если включён доступ к Debian/file-server, дополнительно создаётся правило, разрешающее самому роутеру обращаться к конкретному IP и порту за SSTP-сервером.
---
## Автозапуск
Скрипт добавляет hotplug-обработчик:
```text
/etc/hotplug.d/iface/95-sstp-wan
```
Он пытается поднять SSTP после появления WAN.
Если интерфейс уже поднят или находится в состоянии `pending`, бесконечный перезапуск не выполняется.
---
## Резервные копии
Перед изменениями скрипт сохраняет резервные копии конфигураций:
```text
/etc/config/network
/etc/config/firewall
```
в каталог:
```text
/root/sstp-backup
```
---
## Полезные команды диагностики
Проверить интерфейс:
```sh
ifstatus sstp
```
Посмотреть процессы:
```sh
ps w | grep -E 'sstp|sstpc|pppd' | grep -v grep
```
Посмотреть маршруты:
```sh
ip route
```
Проверить маршрут до file-server:
```sh
ip route get 192.168.65.10
```
Посмотреть логи:
```sh
logread | grep -Ei 'sstp|ppp|pppd|chap|mschap|auth' | tail -80
```
Перезапустить SSTP:
```sh
ifdown sstp
ifup sstp
```
---
## Требования
- OpenWrt;
- доступ в интернет с роутера;
- установленный `opkg`;
- рабочий SSTP-сервер;
- корректные логин и пароль SSTP-пользователя.
---
## Безопасность
Скрипт не включает полный доступ из SSTP в LAN клиента.
По умолчанию открыты только:
```text
SSH 22
HTTP 80
ping
```
Для доступа к серверу с файлом используется точечное правило, ограниченное одним IP и одним TCP-портом.
Не рекомендуется открывать полный forwarding:
```text
sstp → lan
```
если в этом нет строгой необходимости.
---
## Пример использования
Установка:
```sh
wget -O - https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main/install.sh | sh -s install
```
Проверка:
```sh
wget -O - https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main/install.sh | sh -s status
```
Скачивание файла с Debian-сервера за SSTP-сервером:
```sh
wget -O /tmp/subscription.txt http://192.168.65.10/subscription.txt
```
Удаление:
```sh
wget -O - https://raw.githubusercontent.com/makxis/openwrt-sstp-tunnel/main/install.sh | sh -s remove
```
---
## License
MIT
