================================================================
  Boot Integrity Mask v3.6
  Автор:    ExchNow (by Lolokeksu)
  Версия:   v3.6 (09.06.2026)
  Root:     Magisk 27+ / KernelSU / APatch / Magisk Delta
  Android:  12-16  |  ARM64  |  A/B и A-only
================================================================


  ЧТО ДЕЛАЕТ МОДУЛЬ
----------------------------------------------------------------
  Скрывает модификацию загрузочных разделов (boot, init_boot,
  vbmeta, vendor_boot, recovery, dtbo) и динамических разделов
  (super) от приложений, читающих их через /dev/block/by-name.

  Подмена включается на раннем этапе загрузки через loop-
  устройства и tmpfs, и поддерживается адаптивным watchdog'ом
  всё время работы устройства.

  ! Модуль не скрывает разблокированный загрузчик и не помогает
    пройти Play Integrity / SafetyNet.


  ТРЕБОВАНИЯ
----------------------------------------------------------------
  Android       : 12 - 16
  Root-менеджер : Magisk 27+, KernelSU, APatch, Magisk Delta
  Архитектура   : ARM64 (arm64-v8a)
  Разметка      : A/B и A-only
  Ядро          : поддержка loop-устройств и tmpfs
  Обязательно   : stock_boot.img в папке common/ архива


  УСТАНОВКА
----------------------------------------------------------------
  1. ПОДГОТОВКА ОБРАЗА

     Возьмите стоковый образ (boot.img или init_boot.img) из
     официальной прошивки вашего устройства. Образ должен
     соответствовать установленной версии прошивки.

     Переименуйте в stock_boot.img
     Поддерживается .img.gz — распакуется автоматически.
     Целевой раздел определяется автоматически по размеру.

     Опционально — образы дополнительных разделов:
       stock_vbmeta.img
       stock_vendor_boot.img
       stock_recovery.img
       stock_dtbo.img

  2. СБОРКА АРХИВА

     - Скачайте BootMask3.5.zip
     - Откройте ZIP не распаковывая (MT Manager и т.п.)
     - Перейдите в папку common/
     - Поместите stock_boot.img и опциональные образы
     - Для подмены динамических разделов создайте файл
       .super_targets (по одному разделу на строку):
         system
         vendor
         product
     - Закройте архив

  3. УСТАНОВКА

     Magisk / KernelSU / APatch
       -> Модули -> Установить из хранилища -> BootMask3.5.zip
     Дождитесь "Installation complete" и перезагрузите устройство.

  4. ПРОВЕРКА

     su -c "/data/adb/modules/bootmask/bootmask-ctrl status"

     Если статус АКТИВЕН и указано loop-устройство — работает.
     Подробная проверка:
     su -c "/data/adb/modules/bootmask/bootmask-ctrl analyze"


  ОСНОВНЫЕ КОМАНДЫ
----------------------------------------------------------------
  Все команды: su -c "/data/adb/modules/bootmask/bootmask-ctrl <команда>"

  -- Статус и диагностика --

  status              Сводный дашборд
  status --json       Статус в формате JSON
  analyze             Полный анализ с рекомендациями
  check-integrity     Проверка хеша loop против образа
  image-info          Размер, SHA256 и magic образов
  diag                Диагностика системы
  logs                Журнал событий
  logs 100            Последние 100 строк журнала
  report              Полный отчёт -> /sdcard/BootMask/reports/
  diff-report         Сравнение двух последних отчётов

  -- Управление --

  enable              Включить модуль (+ перезагрузка)
  disable             Отключить модуль (+ перезагрузка)
  restore             Убрать подмену и отключить немедленно
  restart-watchdog    Перезапустить фоновый watchdog
  freeze              Временно приостановить подмену
  thaw                Возобновить подмену после freeze

  -- Режимы работы --

  compatibility-mode on|off|status
  stealth on|off|status
  monitor on|off|status

  -- Хуки --

  hooks list              Список установленных хуков
  hooks run <событие>     Запустить хуки события вручную


  РЕЖИМЫ РАБОТЫ
----------------------------------------------------------------
  SAFE BOOT (автоматический)
    Если система не подтвердит успешную загрузку за 120 секунд,
    модуль автоматически отключится. При bootloop — просто
    перезагрузитесь ещё раз, модуль уже будет неактивен.

  COMPAT-РЕЖИМ (режим совместимости)
    Использует прямые symlink'и вместо tmpfs.
    Включайте если:
      - В dmesg есть ошибки mount tmpfs
      - После установки пропадают разделы в /dev/block/by-name
    Команда: compatibility-mode on
    ! Требуется перезагрузка после изменения.

  STEALTH-РЕЖИМ
    Отключает всю запись в dmesg и bootmask.log.
    Устраняет следы работы в системных логах.
    Команда: stealth on
    Действует немедленно, без перезагрузки.

  MONITOR-РЕЖИМ
    Watchdog обнаруживает нарушения ссылок и логирует их,
    но НЕ восстанавливает. Полезно для диагностики.
    Команда: monitor on
    Действует немедленно, без перезагрузки.

  FREEZE / THAW
    freeze — временно отключить подмену без деактивации модуля.
    thaw   — возобновить подмену.
    Не требует перезагрузки.


  КОНФИГУРАЦИЯ WATCHDOG
----------------------------------------------------------------
  Файл: /data/adb/modules/bootmask/common/watchdog.conf

  Строка 1: интервал проверки в секундах (минимум 10, по умол. 120)
  Строка 2: debug — подробное логирование всех событий

  Пример watchdog.conf:
    120
    debug

  Адаптация интервала:
    Экран выключен          -> интервал x2
    Заряд батареи <= 20%    -> интервал x2
    Оба условия             -> интервал x4
    Максимум                -> 600 секунд


  СИСТЕМА ХУКОВ
----------------------------------------------------------------
  Хуки — ваши скрипты, которые модуль запускает автоматически
  при ключевых событиях.

  Расположение:
    /data/adb/modules/bootmask/common/hooks/<событие>/скрипт.sh

  Поддерживаемые события:
    pre-activate      До активации подмены (ранняя загрузка)
    post-activate     После успешной активации
    pre-deactivate    Перед отключением (disable/restore/freeze)
    post-deactivate   После отключения
    on-link-broken    Watchdog обнаружил повреждённую ссылку
    on-link-restored  Watchdog восстановил ссылку
    on-ota-detected   Обнаружено системное обновление

  Переменные окружения в скрипте:
    HOOK_EVENT        имя события
    HOOK_TARGET       целевой раздел (boot / init_boot)
    HOOK_LOOP         путь к loop-устройству
    HOOK_LINK         путь к симлинку (on-link-broken/restored)
    HOOK_TIMESTAMP    время события (Unix timestamp)

  Правила:
    - Первая строка: #!/system/bin/sh
    - Права: 755 (rwxr-xr-x)
    - Таймаут: 30 секунд
    - Выполняются асинхронно, не блокируют загрузку
    - В pre-activate избегайте тяжёлых операций
      (/data может быть ещё недоступен)

  Пример — лог активации:
    #!/system/bin/sh
    LOG="/sdcard/BootMask/activation.log"
    mkdir -p "$(dirname "$LOG")"
    echo "$(date) | $HOOK_EVENT | $HOOK_TARGET | $HOOK_LOOP" >> "$LOG"

  Пример — резервная копия при OTA:
    #!/system/bin/sh
    BACKUP="/sdcard/BootMask/ota_backup"
    mkdir -p "$BACKUP"
    cp /data/adb/modules/bootmask/common/stock_boot.img \
       "$BACKUP/stock_boot_$(date +%Y%m%d_%H%M%S).img"


  СТРУКТУРА ФАЙЛОВ МОДУЛЯ
----------------------------------------------------------------
  /data/adb/modules/bootmask/
  |
  +-- module.prop              метаданные модуля
  +-- post-fs-data.sh          ранняя активация
  +-- service.sh               фоновый watchdog
  +-- bootmask-ctrl            центр управления
  +-- customize.sh             установщик
  +-- disable                  флаг отключения (если есть)
  |
  +-- common/
  |   +-- stock_boot.img       стоковый образ (обязательно)
  |   +-- stock_vbmeta.img     опционально
  |   +-- stock_vendor_boot.img
  |   +-- stock_recovery.img
  |   +-- stock_dtbo.img
  |   +-- compat_mode          флаг compat-режима
  |   +-- watchdog.conf        конфигурация watchdog
  |   +-- hooks/
  |       +-- pre-activate/
  |       +-- post-activate/
  |       +-- pre-deactivate/
  |       +-- post-deactivate/
  |       +-- on-link-broken/
  |       +-- on-link-restored/
  |       +-- on-ota-detected/
  |
  +-- .active_loop             путь к активному loop (boot)
  +-- .target_part             целевой раздел (boot/init_boot)
  +-- .stock_size              размер стокового образа
  +-- .stock_checksum          SHA256 стокового образа
  +-- .byname_dir              путь к by-name каталогу
  +-- .watchdog_pid            PID фонового watchdog
  +-- .restore_count           счётчик восстановлений
  +-- .loop_error_count        счётчик ошибок loop
  +-- .frozen                  флаг заморозки
  +-- .stealth                 флаг stealth-режима
  +-- .monitor                 флаг monitor-режима
  +-- .safe_boot_ok / .safe_boot_failed
  |
  +-- bootmask.log             журнал событий watchdog
  +-- ctrl.log                 журнал команд bootmask-ctrl

  Отчёты и бэкапы: /sdcard/BootMask/


  УСТРАНЕНИЕ НЕПОЛАДОК
----------------------------------------------------------------
  Модуль не активировался
    -> Проверьте размер образа:
       bootmask-ctrl analyze
    -> Убедитесь что stock_boot.img соответствует прошивке
    -> Проверьте журнал:
       bootmask-ctrl logs

  Bootloop после установки
    -> Просто перезагрузитесь ещё раз (Safe Boot отключит модуль)
    -> Проверьте соответствие образа прошивке

  Пропадают разделы в /dev/block/by-name
    -> Включите compat-режим:
       bootmask-ctrl compatibility-mode on
    -> Перезагрузите устройство

  После OTA модуль заморожен
    -> Это штатное поведение
    -> Подготовьте новый stock_boot.img от новой прошивки
    -> Замените образ в common/ архива
    -> Переустановите модуль

  Логи пусты (dmesg недоступен)
    -> На Android 12+ dmesg ограничен ядром (dmesg_restrict)
    -> Используйте журнал модуля:
       bootmask-ctrl logs

  Хук не выполняется
    -> Проверьте права: должно быть 755
    -> Первая строка: #!/system/bin/sh
    -> Имя папки через дефис: pre-activate, не pre_activate
    -> Тест вручную:
       su -c "sh /data/adb/modules/bootmask/common/hooks/post-activate/скрипт.sh"


  CHANGELOG
----------------------------------------------------------------
  v3.6 (09.06.2026) — финальная версия
    + Детальное логирование причины отката в compat-режим:
      теперь видно какая именно ссылка не прошла верификацию
    + analyze проверяет соответствие stock_boot.img текущей
      прошивке (сравнение fingerprint при установке и сейчас)
    + check-integrity: кэш хеша образа по mtime — повторный
      запрос не читает файл заново если образ не менялся
    + Исправлено отображение интервала watchdog в дашборде
      при нестандартном значении watchdog.conf
    + Добавлен README.md в архив модуля

  v3.5 (08.06.2026)
    + Исправлен критический баг tmpfs-пути: бэкап ссылок теперь
      хранится вне by-name и не скрывается при монтировании
    + Защита от bootloop: верификация подмены до передачи
      управления системе с автооткатом в compat при сбое
    + Исправлен сбой активации на mksh/ash
    + Восстановлены команды: check-integrity, image-info, logs,
      diag, restart-watchdog, stealth, monitor, compatibility-mode
    + Watchdog отслеживает все подменяемые разделы (не только boot)
    + SELinux-политика применяется на Magisk, KernelSU и APatch
    + Исправлена система хуков (pre/post-activate)
    + Прямая проверка ссылок вместо хеша каталога
    + Меню перенумеровано по порядку (1-19)
    + JSON-вывод: добавлено булево поле disabled

  v3.0
    + Адаптивный watchdog с backoff-алгоритмом
    + Поддержка динамических разделов (super)
    + Система хуков (7 событий)
    + Safe Boot, Stealth-режим, Monitor-режим
    + Интерактивный центр управления bootmask-ctrl
    + Кроссплатформенный установщик


================================================================
  ExchNow (by Lolokeksu)  |  Boot Integrity Mask v3.6
================================================================
