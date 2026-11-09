# Локальный Kubernetes для CORTEX

Один узел k3s в Ubuntu / WSL2 на Windows. Docker Desktop не требуется:
k3s поставляется с containerd, kubectl, CoreDNS, Traefik и ServiceLB.
Traefik остаётся в `kube-system`, компоненты платформы размещаются в
`cortex-system`, демо-приложения — в `cortex-apps`.

## 1. Подготовить WSL2

В PowerShell **от имени администратора**:

```powershell
wsl --install -d Ubuntu-24.04 --no-launch
```

Если системный `wsl.exe` показывает только базовую справку или сообщение
«Подсистема Windows для Linux не установлена», сначала выполнить
`wsl --install` в административном PowerShell, завершить установку и при
необходимости перезагрузить Windows. Затем установить выбранный дистрибутив
приведённой выше командой.

Если установщик потребует перезагрузку, сохранить работу и перезагрузить Windows.
Затем открыть Ubuntu, завершить первичную настройку Linux-пользователя и пароля:

```powershell
wsl -d Ubuntu-24.04
```

Проверить `wsl --list --verbose`: версия дистрибутива должна быть `2`.
При необходимости: `wsl --set-version Ubuntu-24.04 2`.
Для небольшого стенда рекомендуется иметь свободными 4 CPU, 8 ГБ RAM и 20 ГБ диска;
это ориентир для стенда, а не измеренное потребление CORTEX.

В Ubuntu проверить:

```bash
ps -p 1 -o comm=
sudo apt-get update
sudo apt-get install -y curl ca-certificates
```

Первый вывод должен быть `systemd`. Если это не так, добавить в `/etc/wsl.conf`
(сохранив остальные настройки):

```ini
[boot]
systemd=true
```

После этого выйти из Ubuntu и выполнить из PowerShell
`wsl --terminate Ubuntu-24.04`, затем снова открыть Ubuntu. Команда останавливает
все процессы выбранного дистрибутива; сначала завершить нужную работу.

## 2. Установить кластер и kubeconfig

Команды выполнять в Ubuntu из своего клона репозитория обычным пользователем
с правом sudo. Имя Linux-пользователя выбирает разработчик; совпадение с именем
пользователя Windows не требуется. Bootstrap определяет пользователя через
`id -un`, а домашний каталог — через `$HOME`; учётные записи он не создаёт.

```bash
cd /path/to/tpu-cortex
bash infra/k3s/bootstrap.sh
export KUBECONFIG="$HOME/.kube/cortex-local.yaml"
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide
kubectl get namespaces cortex-system cortex-apps
kubectl get pods -A
```

Заменить `/path/to/tpu-cortex` путём своего клона внутри Linux / WSL.
Для административного развёртывания скрипт также поддерживает запуск от root:

```bash
CORTEX_USER='<existing-linux-user>' bash infra/k3s/bootstrap.sh
```

Указать существующего обычного Linux-пользователя. Скрипт создаёт kubeconfig
для него, но не задаёт пароль и не выдаёт sudo. Этот режим необязателен;
обычный запуск использует текущего пользователя.

Скрипт устанавливает k3s из канала `stable`, создаёт узел `cortex-local`,
отдельный kubeconfig с правами `600` и контекст `cortex-local`
с namespace `cortex-apps`. Существующий `~/.kube/config` не изменяется.
Скрипт добавляет `KUBECONFIG` в начало `~/.profile` и `~/.bashrc` для новых
терминалов и создаёт ссылку `~/.kube/config`, только если этого пути ещё нет.
В текущем терминале выполнить приведённый выше `export`.
Kubeconfig содержит права администратора: хранить вне репозитория и не публиковать.

Для повторяемости записать версию из `k3s --version` в результаты выполнения задачи.
На другой машине можно установить ту же версию:

```bash
K3S_VERSION='vX.Y.Z+k3sN' bash infra/k3s/bootstrap.sh
```

Заменить пример фактической версией. Повторный запуск не обновляет установленный
k3s; обновление версий — отдельная операция. Скрипт рассчитан на выделенный
локальный кластер с узлом `cortex-local`, а не на настройку произвольного кластера.
После обновления сертификатов повторно запустить bootstrap для обновления копии kubeconfig.

`kubectl` работает внутри WSL; отдельный Windows kubectl пока не требуется.
Из PowerShell можно пользоваться тем же подключением:

```powershell
wsl -d Ubuntu-24.04 -- bash -lc 'KUBECONFIG=$HOME/.kube/cortex-local.yaml kubectl get nodes'
```

## 3. Ingress и проверка

Traefik настраивается через `HelmChartConfig` из
`manifests/traefik-config.yaml`: включены access logs, сервис типа LoadBalancer.
ServiceLB использует порты узла 80/443; они должны быть свободны внутри Linux.
Не редактировать генерируемый k3s файл `traefik.yaml`.

```bash
bash infra/k3s/verify.sh
```

Проверка ждёт готовности узла и Traefik, разворачивает `ingress-smoke` в
`cortex-apps` и проверяет цепочку Traefik → Ingress → Service → nginx.
Запрос идёт через временный port-forward на `127.0.0.1:18080` с
`Host: cortex.local`; ожидаются HTTP 200 и стандартная страница nginx.
Занятый порт 18080 считается ошибкой проверки. Smoke-приложение остаётся для демонстрации.

Для ручного просмотра запустить в Ubuntu:

```bash
export KUBECONFIG="$HOME/.kube/cortex-local.yaml"
kubectl -n kube-system port-forward --address 127.0.0.1 service/traefik 18080:80
```

В другом терминале Ubuntu:

```bash
curl --noproxy '*' --fail -H 'Host: cortex.local' http://127.0.0.1:18080/
```

Для браузера Windows добавить `127.0.0.1 cortex.local` в файл
`C:\Windows\System32\drivers\etc\hosts` с правами администратора,
затем открыть `http://cortex.local:18080/` при работающем port-forward.
Это необязательный способ демонстрации; автоматическая проверка не меняет hosts.
Проверка через port-forward не доказывает доступность портов ServiceLB из Windows.

Удалить только тестовое приложение после демонстрации:

```bash
kubectl delete -f infra/k3s/manifests/smoke.yaml
```

## Критерии завершения задачи

- `systemctl is-active k3s` → `active`; узел `cortex-local` → `Ready`.
- Контекст `cortex-local` подключается через отдельный kubeconfig, `cluster-info` успешен.
- `cortex-system` и `cortex-apps` существуют и имеют статус `Active`.
- Deployment Traefik готов, IngressClass `traefik` существует.
- `verify.sh` завершается с `PASS`; записаны фактическая версия и результаты.

До выполнения этих проверок задача считается подготовленной, но не завершённой.
При ошибках: `sudo journalctl -u k3s -n 100 --no-pager`,
`kubectl get events -A --sort-by=.metadata.creationTimestamp`,
`kubectl -n kube-system logs deployment/traefik --tail=100`.

## Фактический статус на 2026-11-10

- WSL2, Ubuntu 24.04, systemd.
- k3s `v1.37.2+k3s1` (`f6973cb8`); служба `active`, узел `cortex-local` — `Ready`.
- Пользовательский `kubectl` из `bash -lc` подключается, контекст `cortex-local`.
- Kubeconfig `~/.kube/cortex-local.yaml`, права `600`.
- `cortex-system`, `cortex-apps` — `Active`.
- Traefik и `ingress-smoke` успешно прошли rollout, класс ingress — `traefik`.
- Финальный запуск `verify.sh` от обычного Linux-пользователя завершился кодом 0 и `PASS`:
  API → готовый узел → namespaces → Traefik → HTTP-маршрут → страница nginx.
- `bash -n` проходит для всех трёх скриптов; `git diff --check` без ошибок.
- Проверен ingress через port-forward в WSL. Доступ из браузера Windows и TLS
  пока не проверены; TLS не входит в эту базовую настройку.

## Необязательно: сеть с HTTP-прокси Windows

Прокси не является зависимостью CORTEX и не настраивается bootstrap-скриптом.
При прямом доступе к реестрам контейнеров этот раздел пропустить.
Если Windows использует HTTP-прокси на localhost, а загрузки из WSL завершаются
таймаутом, пример `wslconfig.example` включает зеркальную сеть,
`autoProxy=true` и DNS tunneling. Файл настроек Windows — `$env:USERPROFILE\.wslconfig`.
Он влияет на все дистрибутивы WSL.
При существующей `.wslconfig` объединять настройки, а не перезаписывать файл.
Изменение применяется после `wsl --shutdown` (останавливает процессы WSL).

Systemd-службы не получают прокси автоматически из интерактивной оболочки.
Если прокси нужен для загрузки образов, выполнить от root внутри Linux / WSL
из каталога репозитория, указав свой адрес:

```bash
bash infra/k3s/configure-containerd-proxy.sh '<proxy-url>'
```

Скрипт записывает `/etc/systemd/system/k3s.service.d/cortex-proxy.conf`
и перезапускает k3s. Прокси применяется к containerd; трафик приложений
в подах автоматически через него не направляется. Прокси Windows должен
работать при загрузке новых образов. На станции без прокси этот шаг не нужен.
При отключении прокси удалить только этот drop-in, выполнить
`systemctl daemon-reload` и `systemctl restart k3s` от root.
Для локальных HTTP-проверок используется `curl --noproxy '*'`.

На проверенном стенде эти настройки потребовались для загрузок образов.
Адрес прокси хранится только в локальном systemd drop-in; его не нужно
добавлять в Git. Аналогично, kubeconfig и параметры учётной записи принадлежат
конкретной машине, а не конфигурации платформы.

## Источники

- [Установка WSL](https://learn.microsoft.com/en-us/windows/wsl/install)
- [systemd в WSL](https://learn.microsoft.com/en-us/windows/wsl/systemd)
- [Установка k3s](https://docs.k3s.io/quick-start)
- [Доступ к кластеру и сертификаты kubeconfig](https://docs.k3s.io/cluster-access)
- [Traefik и ServiceLB](https://docs.k3s.io/networking/networking-services)
- [HelmChartConfig](https://docs.k3s.io/helm/)
- [Сеть и прокси WSL](https://learn.microsoft.com/en-us/windows/wsl/networking)
- [Прокси k3s и containerd](https://docs.k3s.io/advanced#configuring-an-http-proxy)
