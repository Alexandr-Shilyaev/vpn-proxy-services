# AmneziaWG (backend)

Backend протокола **AmneziaWG 2** — WireGuard с обфускацией для обхода DPI.
Часть проекта [vpn-proxy-services](../README.md); управляется общим ботом из `../bot`.

## Скрипты

| Скрипт | Назначение |
|--------|------------|
| `install_server.sh` | установка пакетов и `amneziawg` из PPA, ключи сервера, обфускация, `awg0.conf`, NAT, форвардинг, служба `awg-quick@awg0` |
| `add_user.sh <имя>` | ключи клиента, свободный IP, peer на лету, `.conf` + QR. Печатает `CONF=… QR=…` |
| `del_user.sh <имя>` | снимает peer, чистит конфиг, удаляет файлы. Печатает `DELETED=…` |
| `list_users.sh` | список клиентов и статус последнего хендшейка |
| `lib/common.sh` | общие функции |

Эти три «пользовательских» скрипта (`add`/`del`/`list`) — и есть контракт, который вызывает бот.

## Установка

Обычно ставится из корня проекта одной командой:

```bash
sudo ../setup.sh --token <BOT_TOKEN> --admins <id> --protocols amneziawg
```

Либо только сервер протокола, вручную:

```bash
sudo ./install_server.sh                 # значения по умолчанию
sudo ./install_server.sh --port 51820 --subnet 10.8.0 --dns 1.1.1.1,1.0.0.1 --ip <публичный_IP>
```

`install_server.sh`:
- ставит `amneziawg` из официального PPA `ppa:amnezia/ppa`;
- генерирует ключи сервера и случайные **параметры обфускации** (`Jc, Jmin, Jmax, S1, S2, H1–H4`);
- создаёт `/etc/amnezia/amneziawg/awg0.conf`;
- включает IP-форвардинг и NAT (iptables MASQUERADE);
- запускает `awg-quick@awg0`, состояние хранит в `/etc/awg-vpn/`.

> Не забудьте открыть **UDP-порт** (по умолчанию 51820) у провайдера/в облаке.

## Управление вручную

```bash
sudo ./add_user.sh alex      # клиент + .conf и QR
sudo ./del_user.sh alex      # удалить
sudo ./list_users.sh         # список
```

Файлы клиента: `/etc/awg-vpn/clients/<имя>/` (`<имя>.conf`, `<имя>.png`).

## Клиент

Конфиг и QR содержат параметры обфускации, поэтому импортируйте их в приложение
**AmneziaWG / Amnezia VPN**. Обычный (ванильный) WireGuard к серверу с обфускацией
**не подключится** — нужен AmneziaWG-клиент. Для совместимости с ванильным WG обнулите
`Jc/Jmin/Jmax/S1/S2/H1–H4` и у сервера, и у клиента.

## Источники

- [AmneziaWG — документация](https://docs.amnezia.org/documentation/amnezia-wg/)
- [Установка на Ubuntu (EDIS Global)](https://docs.edisglobal.com/advanced-setup-guides/install-amneziawg-on-ubuntu-22_04/install-amneziawg-on-ubuntu-2204)
- [AmneziaWG 2.0: self-host obfuscated WireGuard (DEV)](https://dev.to/bivlked/amneziawg-20-self-host-an-obfuscated-wireguard-vpn-that-bypasses-dpi-4692)
