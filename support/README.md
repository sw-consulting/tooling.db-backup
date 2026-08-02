# Синхронизация файлов удалённой резервной копии

Скрипт `Sync-RemoteFiles.ps1` загружает файлы с Linux-сервера в каталог
Windows с помощью клиентов Windows OpenSSH `ssh.exe` и `scp.exe`.

Скрипт выполняет следующие действия:

- никогда не перезаписывает существующие локальные файлы;
- сравнивает удалённые и локальные файлы по относительному пути и имени;
- по умолчанию обрабатывает только файлы непосредственно в удалённом каталоге;
- при указании `-Recurse` сохраняет структуру вложенных каталогов;
- создаёт локальный каталог назначения, если он отсутствует;
- принимает пароль SSH в виде объекта PowerShell `SecureString`;
- автоматически принимает ключ нового сервера, но отклоняет изменившийся
  ключ уже известного сервера.

## Требования

Используйте Windows PowerShell 5.1 (`powershell.exe`) в Windows. Проверьте
версию PowerShell и наличие программ OpenSSH:

```powershell
$PSVersionTable.PSVersion
ssh.exe -V
Get-Command ssh.exe, scp.exe
```

Если клиент OpenSSH отсутствует, установите его из сеанса PowerShell,
запущенного от имени администратора:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

После установки откройте новый сеанс PowerShell. Другие способы установки
описаны в
[документации Microsoft по установке OpenSSH](https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse).

Если локальная политика запрещает запуск скрипта, сначала проверьте текущие
настройки:

```powershell
Get-ExecutionPolicy -List
```

Администратор может разрешить локальные скрипты и подписанные скрипты из
внешних источников для текущего пользователя:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## 1. Интерактивная настройка и запуск

Откройте Windows PowerShell и перейдите в каталог `support`:

```powershell
Set-Location 'R:\Projects\30.Projects\tooling.db-backup\support'
```

Запустите скрипт без параметра `-Password`. Скрипт запросит пароль и не будет
отображать введённые символы:

```powershell
.\Sync-RemoteFiles.ps1 `
    -RemoteHost 'kreel1.sw.consulting' `
    -Username 'backup-operator' `
    -RemoteFolder '/mnt/logistore/backup/data' `
    -LocalFolder 'D:\Projects\logibooks\backup'
```

Чтобы включить файлы из вложенных каталогов, добавьте `-Recurse`:

Добавьте `-Verbose`, чтобы получить подробные диагностические сообщения
OpenSSH. Они могут содержать имена серверов и пользователей, пути, IP-адреса
и параметры SSH, но скрипт не выводит пароль.

При первом подключении OpenSSH сохраняет ключ сервера в файле
`~\.ssh\known_hosts` текущего пользователя. Если впоследствии появится
предупреждение об изменении ключа сервера, выясните причину изменения, а не
отключайте эту проверку.

## 2. Настройка и запуск в составе автоматизированного процесса

Не сохраняйте пароль в открытом виде в этом или другом скрипте, в системе
контроля версий, переменной окружения либо аргументе командной строки. Скрипт
уже содержит параметр `-Password` типа `SecureString`. Скрипт-обёртка может
загрузить зашифрованные учётные данные и передать пароль через этот параметр.

### Однократное создание зашифрованных учётных данных

Выполните следующие команды интерактивно от имени той же учётной записи
Windows, под которой будет запускаться автоматизированное резервное
копирование:

```powershell
$credentialDirectory = Join-Path $env:LOCALAPPDATA 'tooling.db-backup'
$credentialPath = Join-Path $credentialDirectory `
    'kreel1-backup-operator.xml'

New-Item -ItemType Directory -Path $credentialDirectory -Force | Out-Null

$credential = Get-Credential `
    -UserName 'backup-operator' `
    -Message 'Введите пароль SSH для резервного копирования'

$credential | Export-Clixml -Path $credentialPath
```

В Windows команда `Export-Clixml` защищает учётные данные с помощью DPAPI.
Расшифровать их сможет только та же учётная запись Windows на том же
компьютере. Копирование файла на другой компьютер или запуск автоматизации от
имени другого пользователя не сработает. Дополнительные сведения приведены в
[документации `Export-Clixml`](https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-clixml).

Храните файл учётных данных в профиле учётной записи автоматизации и не
добавляйте его в систему контроля версий. Чтобы заменить пароль SSH, повторно
выполните приведённые выше команды `Get-Credential` и `Export-Clixml` от имени
учётной записи автоматизации.

### Вызов синхронизации из основного процесса резервного копирования

В основном PowerShell-скрипте можно задать значения по умолчанию для
несекретных параметров, таких как сервер и пути, а пароль загружать во время
выполнения:

```powershell
# Run-Backup.ps1
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $CredentialPath =
        "$env:LOCALAPPDATA\tooling.db-backup\kreel1-backup-operator.xml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$syncScript =
    'R:\Projects\30.Projects\tooling.db-backup\support\Sync-RemoteFiles.ps1'

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Файл учётных данных не найден: $CredentialPath"
}

[System.Management.Automation.PSCredential] $credential =
    Import-Clixml -Path $CredentialPath

& $syncScript `
    -RemoteHost 'kreel1.sw.consulting' `
    -Username $credential.UserName `
    -Password $credential.Password `
    -RemoteFolder '/mnt/logistore/backup/data' `
    -LocalFolder 'D:\Projects\logibooks\backup' `
    -Recurse

# Здесь можно продолжить основной процесс резервного копирования. Ошибка
# синхронизации завершит этот скрипт, поскольку ErrorActionPreference = Stop.
```

Запускайте скрипт-обёртку в том же процессе PowerShell, чтобы объект
`SecureString` был непосредственно передан в `Sync-RemoteFiles.ps1`:

```powershell
powershell.exe -NoProfile -NonInteractive `
    -File 'R:\Projects\30.Projects\tooling.db-backup\support\Run-Backup.ps1'
```

### Настройка Планировщика заданий Windows

При использовании Планировщика заданий Windows:

1. Настройте запуск задания от имени той же учётной записи Windows, которая
   создала XML-файл учётных данных.
2. В качестве программы укажите `powershell.exe`.
3. Укажите следующие аргументы:

   ```text
   -NoProfile -NonInteractive -File "R:\Projects\30.Projects\tooling.db-backup\support\Run-Backup.ps1"
   ```

4. Убедитесь, что учётная запись задания может читать скрипт и файл учётных
   данных, записывать файлы в локальный каталог резервных копий и подключаться
   к SSH-серверу.
5. Перед включением расписания проверьте задание от имени этой учётной записи.

Параметр `-NonInteractive` запрещает запросы ввода. Если файл учётных данных
отсутствует или не может быть расшифрован, задание завершится с ошибкой вместо
бесконечного ожидания ввода.

Если автоматизация должна выполняться от имени другой учётной записи, на
другом компьютере или под управляемой учётной записью без обычного профиля
Windows, используйте хранилище секретов для автоматизации либо добавьте в
скрипт поддержку аутентификации по ключу SSH вместо копирования файла учётных
данных DPAPI.

## Диагностика

Сначала запустите скрипт интерактивно с параметром `-Verbose`. Для проверки
также можно использовать следующие команды:

```powershell
Test-NetConnection 'kreel1.sw.consulting' -Port 22

ssh.exe -vvv `
    -o PubkeyAuthentication=no `
    -o PreferredAuthentications=password `
    -o NumberOfPasswordPrompts=1 `
    'backup-operator@kreel1.sw.consulting' 'true'
```

Если скрипт сообщает об ошибке аутентификации, сообщение
`Askpass helper invocations: 1` означает, что OpenSSH успешно запросил пароль
из объекта `SecureString`. Значение `0` указывает на локальную ошибку запуска
вспомогательной программы askpass или подключения к ней.

Для автоматизированного задания проверьте учётную запись Windows и путь к
файлу учётных данных непосредственно в контексте выполнения задания:

```powershell
[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$env:LOCALAPPDATA
Test-Path "$env:LOCALAPPDATA\tooling.db-backup\kreel1-backup-operator.xml"
```
