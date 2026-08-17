# Быстрый старт

От скачанного архива до работающего `SELECT` через Oracle-клиент. Всё
необходимое лежит в архиве и этом дистрибутивном репозитории; доступ к закрытым
исходникам продукта для прохождения этой страницы не требуется. Если требуется
— это ошибка страницы, сообщите о ней.

English version: **[QUICKSTART.md](QUICKSTART.md)**.

> orapglink — **экспериментальный preview**. Это не продукт Oracle, он не
> production-ready и по своей конструкции работает только на чтение. Прочитайте
> [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) прежде чем на что-либо здесь
> полагаться.

## 1. Что понадобится

| | |
|---|---|
| **ОС / архитектура** | Linux x86-64, Linux arm64 или macOS на Apple Silicon (arm64). Windows и macOS Intel в этот preview не входят. |
| **Runtime для Linux** | Проверено на `debian:bookworm-slim` **без единого доустановленного пакета**. Точное требование — в разделе «Системные библиотеки для Linux» ниже. |
| **PostgreSQL** | Проверенная версия — **16**. Локальная или удалённая. |
| **`psql` и административная учётная запись** | Нужны **однократно**, для установки: две роли, одно расширение и набор представлений. Сам proxy ничего из этого не делает. |
| **Расширение `orafce`** | Обязательно. В Debian/Ubuntu с репозиторием PGDG: `postgresql-16-orafce`. |
| **Один Oracle-клиент для проверки** | Проще всего `python-oracledb` в режиме thin (`pip install oracledb`) — чистый Python, ПО Oracle не требуется. DBeaver тоже подходит. |
| **Свободный локальный порт** | По умолчанию `1521`. |

**Oracle Database не нужна.** Thin-клиенты и DBeaver подключаются к orapglink
напрямую. Реальная Oracle Database нужна только для сценария `DATABASE LINK` из
раздела 7, и он необязателен.

## 2. Распаковка и проверка бинарника

```sh
# Сначала проверьте загруженный файл (SHA256SUMS публикуется рядом с архивами).
sha256sum -c SHA256SUMS          # macOS: shasum -a 256 -c SHA256SUMS

tar -xzf orapglink_0.1.0-preview.2_linux_amd64.tar.gz
cd orapglink_0.1.0-preview.2_linux_amd64

./orapglink --version
```

`--version` должен напечатать ровно:

```text
v0.1.0-preview.2
```

Если печатается `dev` или git-хеш — у вас сборка для разработки, а не релизный
архив; не используйте её там, где нужен предсказуемый результат.

Публичные release notes и раздел
[Testing and verification](doc/testing.md) перечисляют проверенные семейства
клиентов, число пройденных сценариев и известные ограничения. Прочитайте их
перед подключением production-инструмента.

На macOS первый запуск может заблокировать Gatekeeper, потому что бинарник не
нотаризован. Разрешите запуск в **Системных настройках → Конфиденциальность и
безопасность** либо выполните `xattr -d com.apple.quarantine ./orapglink`.

### Системные библиотеки для Linux

Бинарники для Linux **не** статические. В них встроен SQL-парсер PostgreSQL на
C (см. `THIRD_PARTY_NOTICES.md`), поэтому им нужны системные C- и
C++-библиотеки релизной сборки:

```text
libc.so.6  libm.so.6  libgcc_s.so.1  libstdc++.so.6
```

Публикуемые Linux-архивы собираются на **Ubuntu 22.04 (glibc 2.35)**, и каждый
проверяется запуском распакованного бинарника в чистом контейнере
`debian:bookworm-slim` **без единого доустановленного пакета**: все четыре
библиотеки там уже есть. Конкретнее:

- **Проверенная среда запуска:** чистый контейнер Debian 12
  (`bookworm-slim`). Сборка выполняется на Ubuntu 22.04. Другие glibc-based
  дистрибутивы с четырьмя библиотеками выше, вероятно, совместимы, но не
  заявляются как проверенные.
- **Более старый дистрибутив** (glibc ниже 2.35) — упадёт при старте с
  сообщением `version 'GLIBC_2.xx' not found`. Запускайте опубликованный
  бинарник в совместимом контейнере на glibc.
- **Минимальный образ без C++-runtime** (Alpine, `distroless/static`,
  `scratch`) — работать не будет. В Alpine используется musl вместо glibc;
  берите образ на glibc, например `debian:bookworm-slim`.

Проверить свою систему: `ldd ./orapglink` — ни одна строка не должна содержать
`not found`. Затем выполните `./orapglink --version`: эти проверки полезнее,
чем предположение о совместимости только по названию дистрибутива.

Здесь сказано ровно то, что было проверено, и не больше: обещания «работает на
любом Linux» нет.

## 3. Подготовка PostgreSQL

Здесь однократно, от имени администратора PostgreSQL, делается пять вещей: база
данных, расширение `orafce`, две роли, словарные представления Oracle и проверка
того, что read-only роль действительно read-only.

### 3.0 Задайте пять значений ОДИН раз — всё ниже их переиспользует

Именно на этом чаще всего спотыкаются: одни и те же значения повторяются в
следующих шагах, а потом ещё раз при запуске прокси, и если две копии разойдутся,
всё ломается тихо. Поэтому определите их **один раз**, здесь, как переменные
окружения, а команды ниже вставляйте без изменений. Дальше ничего не
захардкожено.

```sh
# Административное (суперпользовательское) соединение — где вы CREATE'ите. Подставьте
# host/port/user под свой PostgreSQL. (Для одноразового контейнера из этой инструкции
# это postgres:postgres @ 127.0.0.1:5544.)
export PGHOST=127.0.0.1
export PGPORT=5432
export PGADMIN_USER=postgres
export PGADMIN_PASSWORD=postgres

# Что вы создаёте. Пароли для двух ролей orapglink выберите свои.
export DBNAME=appdb
export RUNTIME_PW='выберите-надёжный-пароль'
export INSTALL_PW='выберите-другой-надёжный-пароль'

# Единственное имя Oracle-схемы, которое сообщает прокси. Оно ДОЛЖНО быть именем
# PostgreSQL-схемы с вашими данными в ВЕРХНЕМ регистре — для схемы по умолчанию
# `public` это PUBLIC. Это значение встречается в ТРЁХ местах (3.4, раздел 4,
# раздел 5); задав его здесь, вы держите их в согласии.
export LOGICAL_SCHEMA=PUBLIC
```

Где каждое заданное значение используется снова — держите таблицу перед глазами:

| Значение | Используется снова в |
|---|---|
| `RUNTIME_PW` | DSN runtime-роли при запуске прокси (§4) |
| `INSTALL_PW` | установке словарных представлений (§3.4) |
| `DBNAME` | каждом шаге и в DSN прокси (§4) |
| `LOGICAL_SCHEMA` | словарных представлениях (§3.4), `ORAPGLINK_LOGICAL_SCHEMA` (§4) и имени сервиса клиента (§5) — **все три обязаны совпадать** |

Два производных DSN, которые переиспользуют команды ниже — вставьте и их:

```sh
export PGADMIN_DB_DSN="postgresql://${PGADMIN_USER}:${PGADMIN_PASSWORD}@${PGHOST}:${PGPORT}/${DBNAME}"
export PGADMIN_ROOT_DSN="postgresql://${PGADMIN_USER}:${PGADMIN_PASSWORD}@${PGHOST}:${PGPORT}/postgres"
```

### 3.1 Создать (или выбрать) базу данных

```sh
psql "$PGADMIN_ROOT_DSN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE $DBNAME;"
```

(Если база уже существует — например, её создал контейнер настройки — команда
безобидно завершится ошибкой; пропустите её.) Можно использовать существующую
базу с реальными данными — ничего из этой инструкции ваши таблицы не изменяет.

### 3.2 Установить `orafce`

`orafce` предоставляет функции с Oracle-семантикой (`NVL`, `DECODE`,
`ADD_MONTHS`, `LAST_DAY`, `MONTHS_BETWEEN`, четырёхаргументный `INSTR`,
Oracle-вариант `SUBSTR`, маски `TO_CHAR` / `TO_DATE`, `REGEXP_LIKE`, `RTRIM`,
`RPAD`, …), которые orapglink сознательно не реализует заново. Расширение
**обязательно по умолчанию**, и не зря: часть этих имён существует и в
PostgreSQL, но с *другим* поведением, поэтому отсутствие `orafce` не привело бы
к ошибке — оно молча вернуло бы ответ PostgreSQL вместо ответа Oracle.

```sh
# Debian/Ubuntu с репозиторием PGDG, на хосте PostgreSQL:
sudo apt-get install -y postgresql-16-orafce

psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS orafce;"
```

Если ваш PostgreSQL работает в контейнере, где пакет orafce уже есть (в
контейнере настройки из этой инструкции — есть), **пропустите строку `apt-get`**
и выполните только `CREATE EXTENSION`. На других платформах расширение тоже
пакетируется (`yum install orafce_16`, Homebrew через `pgxnclient install
orafce`, либо сборка из исходников — <https://github.com/orafce/orafce>). Любой
способ подходит, если `CREATE EXTENSION orafce;` выполняется успешно и создаёт
схему `oracle`.

### 3.3 Создать две роли

`sql/provision_roles.sql` содержит три плейсхолдера — `<RUNTIME_PASSWORD>`,
`<INSTALL_PASSWORD>`, `<DATABASE_NAME>`. Вместо ручной правки файла подставьте их
из переменных, заданных в §3.0, и направьте результат прямо в `psql` — так не
останется наполовину отредактированного файла, в котором легко ошибиться, и ни
одного пароля в открытом виде на диске:

```sh
sed -e "s/<RUNTIME_PASSWORD>/${RUNTIME_PW}/g" \
    -e "s/<INSTALL_PASSWORD>/${INSTALL_PW}/g" \
    -e "s/<DATABASE_NAME>/${DBNAME}/g" \
    sql/provision_roles.sql \
  | psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1
```

> **`<DATABASE_NAME>` — это имя УЖЕ существующей базы.** Файл выполняет
> `GRANT CONNECT ON DATABASE <DATABASE_NAME> …`, а PostgreSQL отказывается
> выдавать права на базу, которую не находит (`ERROR: database "…" does not
> exist`). Это должно быть ровно то же `$DBNAME`, которое вы **создали в §3.1**,
> а не новое имя, придуманное здесь. Если через sed подставили имя, которое ни
> разу не создавалось, вернитесь и сначала выполните для него §3.1. Когда всё
> идёт от переменной `$DBNAME` из §3.0, согласованность держится сама собой;
> ошибка вылезает только если вписать другое имя руками.

Что создаётся:

- **`orapglink_runtime`** — роль, под которой подключается сам orapglink. Только
  `CONNECT`, `USAGE` и `SELECT`; никаких `INSERT`/`UPDATE`/`DELETE`, никакого
  DDL. Её пароль — `RUNTIME_PW`, вы передадите его прокси в §4.
- **`orapglink_install`** — используется только для установки словарных
  представлений на следующем шаге (§3.4), с паролем `INSTALL_PW`. orapglink
  никогда не аутентифицируется под этой ролью.

Затем один грант, который сам SQL-файл выполнить не может, — разрешить
runtime-роли вызывать функции orafce (роль появляется только после шага выше):

```sh
psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1 -c \
  "GRANT USAGE ON SCHEMA oracle TO orapglink_runtime;
   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracle TO orapglink_runtime;"
```

Если данные лежат в схеме, ОТЛИЧНОЙ от `public`, выдайте на неё чтение прямо
сейчас (и не забудьте добавить эту схему в `ORAPGLINK_PG_SCHEMAS` в §4):

```sh
# только если НЕ используется схема по умолчанию `public` — замените myschema:
# psql "$PGADMIN_DB_DSN" -c "GRANT USAGE ON SCHEMA myschema TO orapglink_runtime;
#   GRANT SELECT ON ALL TABLES IN SCHEMA myschema TO orapglink_runtime;
#   ALTER DEFAULT PRIVILEGES IN SCHEMA myschema GRANT SELECT ON TABLES TO orapglink_runtime;"
```

> **Все команды этого шага должны выполняться в подключении к вашей целевой базе
> (`$DBNAME`), а не к служебной базе `postgres`.** Команды выше используют
> `$PGADMIN_DB_DSN`, который уже указывает на `$DBNAME`, — так что при запуске
> как показано об этом можно не думать. Проблема возникает, только если
> выполнять команды руками из сессии с базой `postgres`: `GRANT
> CONNECT`/`CREATE ON DATABASE` глобальны и работают откуда угодно, а вот `GRANT
> … ON SCHEMA public`, `GRANT SELECT ON ALL TABLES`, `ALTER DEFAULT PRIVILEGES
> IN SCHEMA public` и гранты на `oracle` действуют на схему `public`/`oracle`
> **той базы, в которой вы сейчас находитесь**. Выполните их из базы `postgres`
> — и они лягут в `postgres.public` вместо `<вашабаза>.public`, а runtime-роль
> не увидит ни одной вашей таблицы. Если так вышло — просто переподключитесь к
> `$DBNAME` и повторите эти строки грантов, они идемпотентны.

### 3.4 Установить словарные представления Oracle

**Вы только что создали роли. Следующие команды выполняются от имени *другого*
пользователя** — `orapglink_install`, а не администратора — **в той же базе
`$DBNAME`.** То есть вы переподключаетесь: DSN ниже меняет и пользователя, и
пароль (`orapglink_install` / `$INSTALL_PW`), сохраняя
`$PGHOST:$PGPORT/$DBNAME`.

`sql/oracle_compat_views.sql` создаёт схему `oradict`: `DUAL` и представления
`ALL_*` / `USER_*` / `DBA_*` поверх живого `pg_catalog`. Без него
`SELECT … FROM dual` и любой запрос метаданных завершатся ошибкой
«отношение не найдено».

В файле два плейсхолдера, и оба берутся из уже заданных значений:

- `<RUNTIME_ROLE>` → `orapglink_runtime` (роль из §3.3);
- литерал `'APP'` → `'<ваш LOGICAL_SCHEMA>'`. **Это то самое значение, которое
  обязано совпадать в трёх местах** — здесь, в `ORAPGLINK_LOGICAL_SCHEMA` из §4
  и в имени сервиса клиента из §5. Использование `$LOGICAL_SCHEMA` из §3.0 во
  всех трёх местах и держит их одинаковыми; при расхождении `USER_TABLES` и
  подобные представления молча вернут ноль строк.

Запускайте **от имени install-роли** (обратите внимание: DSN использует
`orapglink_install` и `INSTALL_PW`, а не администратора — схемой `oradict`
владеет install-роль):

```sh
sed -e "s/<RUNTIME_ROLE>/orapglink_runtime/g" \
    -e "s/'APP'/'${LOGICAL_SCHEMA}'/g" \
    sql/oracle_compat_views.sql \
  | psql "postgresql://orapglink_install:${INSTALL_PW}@${PGHOST}:${PGPORT}/${DBNAME}" \
      -v ON_ERROR_STOP=1
```

Миграция идемпотентная и транзакционная — повторный запуск безопасен, и её
следует выполнять заново после обновления orapglink.

### 3.5 Проверить runtime-роль: читать может, писать не может

Важны обе проверки. Первая показывает, что установка работает; вторая — что
запрет на запись обеспечивается самим PostgreSQL, а не только orapglink.

```sh
export RUNTIME_DSN="postgresql://orapglink_runtime@${PGHOST}:${PGPORT}/${DBNAME}"

# чтение:
PGPASSWORD="$RUNTIME_PW" psql "$RUNTIME_DSN" -c "SELECT * FROM oradict.dual;"
#  dummy
# -------
#  X

# запись должна быть отклонена:
PGPASSWORD="$RUNTIME_PW" psql "$RUNTIME_DSN" -c "CREATE TABLE should_fail (i int);"
# ERROR:  permission denied for schema public
```

Если `CREATE TABLE` прошёл — остановитесь и исправьте роль: вы направили
orapglink на учётную запись с правом записи.

### 3.6 Необязательно: таблица для запросов

Если база пустая, создайте что-нибудь для выборки:

```sh
psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS demo_customers (
    id        integer PRIMARY KEY,
    name      varchar(60) NOT NULL,
    signed_up date
);
INSERT INTO demo_customers VALUES (1, 'Acme',    DATE '2024-03-01'),
                                  (2, 'Globex',  DATE '2025-11-17')
ON CONFLICT DO NOTHING;
GRANT SELECT ON demo_customers TO orapglink_runtime;
SQL
```

Последний `GRANT` — не украшение. `ALTER DEFAULT PRIVILEGES` в
`provision_roles.sql` покрывает только таблицы, созданные *той же ролью, которая
его выполнила*. Если таблицу создаёт другая роль, выдавайте `SELECT` явно —
иначе таблица просто не будет видна orapglink.

## 4. Настройка и запуск orapglink

```sh
cp config.env.example config.env
```

> **`config.env` читается shell'ом (`. ./config.env`), поэтому это синтаксис
> shell, а не `.ini`.** Три правила избавят от кучи проблем:
> - **Без пробелов вокруг `=`.** `KEY=value`, а не `KEY = value` — с пробелами
>   shell воспринимает строку как команду, а не присваивание.
> - **Без `;` в конце.** Точка с запятой попадёт внутрь значения и сломает его.
> - **Значения со спецсимволами — в кавычках.** В DSN есть `?`
>   (`…/test?sslmode=disable`), и zsh пытается раскрыть его как glob по именам
>   файлов (`no matches found`). Оборачивайте такие значения в одинарные кавычки:
>   `ORAPGLINK_POSTGRES_DSN='postgresql://…/test?sslmode=disable'`.
>
> `config.env.example` уже соблюдает все три правила — начните с него (как выше)
> и меняйте только текст справа от каждого `=`.

Отредактируйте `config.env` и задайте эти значения. Три из них — переменные из
§3.0, которые вы уже выбрали; перенесите их точь-в-точь:

- `ORAPGLINK_ORACLE_PASSWORD` — общий пароль, который будут использовать
  Oracle-**клиенты**. Это *новый* пароль, который вы придумываете здесь; он
  никак не связан ни с одной ролью PostgreSQL. С ним принимается любое имя
  пользователя; имя пользователя не является учётной записью PostgreSQL.
- `ORAPGLINK_POSTGRES_DSN` — DSN **runtime**-роли. Это `orapglink_runtime` с
  вашим `RUNTIME_PW`, указывающий на `PGHOST:PGPORT/DBNAME` из §3.0. Чтобы
  вывести точную строку для вставки:

  ```sh
  echo "postgresql://orapglink_runtime:${RUNTIME_PW}@${PGHOST}:${PGPORT}/${DBNAME}?sslmode=disable"
  ```

  Для удалённого PostgreSQL используйте `sslmode=require`; `sslmode=disable`
  оправдан только для базы на loopback. Этот параметр относится к соединению с
  PostgreSQL и никак не влияет на Oracle-listener.
- `ORAPGLINK_LOGICAL_SCHEMA` — задайте равным вашему `$LOGICAL_SCHEMA` из §3.0
  (например, `PUBLIC`). **Это третье из трёх мест, которые обязаны совпадать** —
  оно должно быть равно значению, подставленному вместо `'APP'` в §3.4, и имени
  сервиса, которое клиент использует в §5.
- `ORAPGLINK_PG_SCHEMAS` — PostgreSQL-схема(ы) в нижнем регистре, которые нужно
  открыть (по умолчанию `public`). Если данные лежат в другом месте, укажите его
  здесь — и это должна быть схема, на которую вы выдали `SELECT` в §3.3.

> **База vs схема — почему `LOGICAL_SCHEMA` это `PUBLIC`, а не имя базы.** Это
> два разных уровня, и их легко перепутать. Имя **базы** (например, `test`)
> фигурирует *только* внутри `ORAPGLINK_POSTGRES_DSN` — так прокси добирается до
> PostgreSQL, и Oracle-клиентам оно не показывается (в Oracle нет понятия
> «база» в смысле Postgres). Клиенты видят одну Oracle-**схему/сервис**, и это
> имя берётся из PostgreSQL-*схемы*, где лежат ваши таблицы — `public`, в
> верхнем регистре `PUBLIC`:
>
> ```text
> Сервер PostgreSQL (127.0.0.1:5432)
> └── база  test              ← /test в ORAPGLINK_POSTGRES_DSN
>     └── схема  public        ← ORAPGLINK_PG_SCHEMAS=public   (нижний регистр, сторона PG)
>         └── ваши таблицы
>
> Oracle-клиент видит:
> сервис/owner  PUBLIC         ← ORAPGLINK_LOGICAL_SCHEMA=PUBLIC (верхний регистр) + имя сервиса в §5
> ```
>
> Поэтому «три места, которые обязаны совпадать» — `'APP'`→`'PUBLIC'` в §3.4,
> `ORAPGLINK_LOGICAL_SCHEMA` здесь и имя сервиса клиента в §5 — все про **схему**
> `public`, а не про базу `test`.

Затем:

```sh
set -a
. ./config.env
set +a
./orapglink
```

Здоровый старт выглядит так:

```text
level=INFO msg="orapglink: orafce verified"
level=INFO msg="pgmeta: catalog snapshot loaded" relations=... columns=...
level=INFO msg="orapglink: Oracle-wire (TNS) listening" addr=127.0.0.1:1521
       logical_schema=PUBLIC search_path="public", "oracle", "pg_catalog"
       build_version=v0.1.0-preview.2
```

Если listener привязан не к loopback, дополнительно появится предупреждение о
том, что этот протокол здесь не шифруется. Предупреждение верное — см.
[KNOWN_LIMITATIONS.md §3](KNOWN_LIMITATIONS.md).

Остановка — `Ctrl-C`; процесс корректно завершается по `SIGINT`/`SIGTERM`.

### 4.1 Необязательно: playground трансляции

Встроенная веб-страница, которая прогоняет Oracle→PostgreSQL-транслятор *этого
же* прокси (плюс валидацию libpg_query): вставляете Oracle SQL и видите, во что
он превращается. По умолчанию выключена. Включить можно в `config.env`:

```sh
ORAPGLINK_PLAYGROUND_LISTEN=127.0.0.1:8099
```

или разовым флагом, не трогая `config.env`:

```sh
./orapglink --playground-listen 127.0.0.1:8099
```

При старте появится `translation playground listening addr=127.0.0.1:8099`;
откройте <http://127.0.0.1:8099> в браузере. Авторизации **нет** — привязывайте
только к loopback (`127.0.0.1`); прокси предупредит в логе, если указать не
loopback. Это инструмент разработчика, PostgreSQL он не трогает — только
переводит и валидирует текст SQL.

### 4.2 Ограничения размера результата и память

orapglink формирует **весь результат в памяти** до отправки первой строки: чтобы
закодировать результат в формат Oracle-wire, нужно знать самое широкое значение
в нём, поэтому потокового пути сегодня нет. Именно поэтому эти ограничения —
единственное, что стоит между случайным `SELECT * FROM huge_table` и убийством
процесса OOM-killer'ом. Оставить значения по умолчанию безопасно; **повышать их
без расчёта ниже — нет.**

| Параметр | По умолчанию | Что ограничивает |
| --- | --- | --- |
| `--max-result-rows` | `50000` | строк в одном результате |
| `--max-result-bytes` | `64 MiB` | оценку памяти, удерживаемой одним результатом |
| `--max-cell-bytes` | `32 MiB` | одно значение (это потолок для LOB) |
| `--max-concurrent-queries` | `8` | результатов, материализуемых **одновременно** |

Первые три — **на один запрос**. Процесс в целом ограничивает только четвёртый,
и реально важно произведение:

```text
худший случай по памяти ≈ --max-concurrent-queries × --max-result-bytes
                        = 8 × 64 MiB ≈ 512 MiB      (значения по умолчанию)
```

orapglink печатает это при старте, так что гадать не нужно:

```text
level=INFO msg="resource envelope" max_result_rows=50000 max_result_bytes=67108864
       max_concurrent_queries=8 worst_case_inflight_bytes=536870912
```

Если эта строка пришла с уровнем `WARN`, настроенный бюджет больше, чем удержит
небольшой контейнер, — понизьте `--max-result-bytes` или
`--max-concurrent-queries`. Закладывайте запас сверху этого числа (буферы
драйвера PostgreSQL, копия для wire и строки, сохранённые для последующих
`FETCH`, лежат поверх него); значения по умолчанию рассчитаны примерно на
процесс в 1 GiB.

`--max-result-bytes` учитывает служебные расходы на структуру результата, а не
только сами символы. Широкая строка дорога ещё до того, как в ней появятся
данные: строка из 130 колонок стоит около 6 KB одного лишь учёта — поэтому
таблица со 130 колонками упирается в лимит байтов заметно раньше, чем в лимит
строк.

При достижении лимита запрос останавливается штатно, а **сессия выживает**:

- слишком большой результат → `ORA-04030: out of process memory when trying to
  allocate bytes for the result (result exceeded this proxy's configured size
  limit …)`
- слишком долгий запрос (превышен `--query-timeout`) → `ORA-00040: active time
  limit exceeded - call aborted`
- сервер перегружен (свободного слота не нашлось за `--query-timeout`) →
  `ORA-07454: queue timeout exceeded`

Все три означают «запрашивайте меньше за раз» — добавьте условие `WHERE` или
ограничение по `ROWNUM`. Ни одно из них не оставляет прокси в плохом состоянии.

Эти коды важнее, чем кажется. Первые два раньше отдавались как `ORA-01013: user
requested cancel of current operation`, а Oracle, обращающаяся через
`DATABASE LINK`, читает это как *пользователь отменил операцию* — то есть как
временное состояние — и переотправляет запрос. Бесконечно. На практике клиент
просто зависал, ошибки не видел вообще, а прокси тысячи раз перевыполнял
заведомо обречённый запрос. `ORA-04030`/`ORA-00040` — финальные, поэтому запрос
останавливается с первой попытки, и ошибка доходит до вас.

## 5. Первый запрос

### Через python-oracledb (режим thin)

Клиентское ПО Oracle не задействовано — thin является режимом по умолчанию самой
библиотеки.

```sh
pip install oracledb
```

```python
import oracledb

conn = oracledb.connect(
    user="APP",                     # любое имя; оно не проверяется
    password="change-me",           # ORAPGLINK_ORACLE_PASSWORD
    dsn="127.0.0.1:1521/PUBLIC",    # service name = ORAPGLINK_LOGICAL_SCHEMA
)
with conn.cursor() as cur:
    cur.execute("SELECT 1 FROM dual")
    print(cur.fetchone())                       # (1,)

    cur.execute("SELECT SYSDATE FROM dual")
    print(cur.fetchone())                       # (datetime.datetime(...),)

    cur.execute("SELECT table_name FROM user_tables ORDER BY table_name")
    print([r[0] for r in cur.fetchall()])       # ['DEMO_CUSTOMERS', ...]

    cur.execute("SELECT id, name, signed_up FROM demo_customers ORDER BY id")
    for row in cur.fetchall():
        print(row)
```

Вот и весь цикл: Oracle-драйвер, Oracle SQL, типы данных Oracle — и PostgreSQL
внизу.

Здесь же видна single-tenant модель: `user="APP"` подключается, но подключится и
`user="что-угодно"`. Имя пользователя не является учётной записью PostgreSQL и
не проверяется; все сессии читают через один настроенный backend DSN. Правильным
должен быть **service name** — он обязан совпадать с
`ORAPGLINK_LOGICAL_SCHEMA`.

### Через DBeaver

| Поле | Значение |
|---|---|
| Driver | Oracle (Thin driver, тип подключения «Basic») |
| Host | `127.0.0.1` |
| Port | `1521` |
| Service name | ваш `ORAPGLINK_LOGICAL_SCHEMA`, например `PUBLIC` |
| Username | любое, например `APP` |
| Password | ваш `ORAPGLINK_ORACLE_PASSWORD` |

Обозреватель объектов покажет схемы, таблицы, колонки и данные таблиц. Более
глубокие панели метаданных (ограничения, индексы, триггеры) ограничены — см.
[KNOWN_LIMITATIONS.md §11](KNOWN_LIMITATIONS.md). В SQL-редакторе можно
предварить запрос маркером `/*pg*/`, чтобы отправить нативный PostgreSQL напрямую,
минуя транслятор Oracle→PostgreSQL:

```sql
/*pg*/ SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY 2 DESC LIMIT 10;
```

Режим по-прежнему только для чтения: passthrough-запросы выполняются в той же
`READ ONLY` транзакции, с теми же лимитами и тайм-аутом.

## 6. Чего ожидать от SQL

orapglink транслирует документированное подмножество Oracle SQL в SQL
PostgreSQL. Контрактом является `TRANSLATOR_SUPPORT.md` (он есть в архиве): по
каждой возможности там указано, заявляется ли семантическая эквивалентность,
является ли расхождение документированным приближением, или конструкция
отклоняется полностью.

Отказ выглядит как обычная ошибка Oracle — чаще всего `ORA-03001` — и **сессия
после него продолжает работать**; можно продолжать в том же соединении. Так
задумано: отказаться безопаснее, чем вернуть правдоподобно выглядящий неверный
ответ.

## 7. Необязательно: `DATABASE LINK` из реальной Oracle Database

Это тот сценарий, ради которого проект и существует, и для него нужна уже
имеющаяся у вас реальная Oracle Database. Всё описанное выше работает без неё.

На стороне Oracle:

```sql
CREATE DATABASE LINK pglink
  CONNECT TO appuser IDENTIFIED BY "<ORAPGLINK_ORACLE_PASSWORD>"
  USING '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=<хост-orapglink>)(PORT=1521))
          (CONNECT_DATA=(SERVICE_NAME=PUBLIC)))';

SELECT * FROM demo_customers@pglink WHERE ROWNUM <= 10;
```

- `SERVICE_NAME` должен совпадать с вашим `ORAPGLINK_LOGICAL_SCHEMA`.
- В `CONNECT TO <user>` можно указать любое имя; значение имеет только пароль.
- Oracle-база должна доставать до хоста orapglink по порту 1521, а значит
  `ORAPGLINK_ORACLE_LISTEN` не может остаться на `127.0.0.1`.

> **Это соединение не шифруется.** Listener orapglink не поддерживает ни
> native encryption Oracle, ни TCPS, поэтому пароль линка и все возвращаемые
> строки идут по сети в открытом виде. Используйте только в доверенной сети или
> через VPN, либо поставьте перед listener'ом TLS-туннель. Не выставляйте порт
> 1521 в Интернет.

Именно через `DATABASE LINK` покрытие типов уже, чем у thin-клиентов, и
несколько форм отклоняются с `ORA-03001`, а не угадываются — см.
[KNOWN_LIMITATIONS.md §10](KNOWN_LIMITATIONS.md) и
[Testing and verification](doc/testing.md).

## 8. Диагностика

| Симптом | Причина | Что сделать |
|---|---|---|
| `ERROR: database "…" does not exist` при запуске `provision_roles.sql` | вы подставили `<DATABASE_NAME>`, которую ни разу не создавали | создайте её (шаг 3.1) или используйте существующее имя — одно и то же значение идёт во все три места `<DATABASE_NAME>` (шаг 3.3) |
| `zsh: no matches found: postgresql://…?sslmode=disable` | незакавыченный `?` в `config.env` воспринят как glob по именам файлов | оберните значение в одинарные кавычки; см. заметку про синтаксис `config.env` в шаге 4 |
| `no such file or directory: ./orapglink` | релизного бинарника нет или вы находитесь не в том каталоге | скачайте и распакуйте релизный архив для своей платформы, затем запускайте команду из этого каталога |
| чтение работает, но runtime-роль **не видит** ни одной вашей таблицы (`USER_TABLES` пуст) | гранты `GRANT`/`ALTER DEFAULT PRIVILEGES` на `public` были выполнены в подключении к не той базе (например, `postgres` вместо целевой) | повторите эти три гранта в подключении к вашей целевой `$DBNAME` — см. заметку «в какую базу» в шаге 3.3 |
| ORA-ошибка заканчивается на `(translated SQL line N, column M)` | эта координата указывает в **переведённый** PostgreSQL-SQL, а не в ваш оригинал Oracle | вставьте запрос в playground трансляции (шаг 4.1) — он покажет эту строку с кареткой под местом |
| `orafce verification failed` при старте | расширение отсутствует или runtime-роль не может им пользоваться | `CREATE EXTENSION orafce;`, затем `GRANT USAGE ON SCHEMA oracle` и `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracle` роли `orapglink_runtime` (шаги 3.2 / 3.3а) |
| `connection refused` со стороны клиента | proxy слушает не там, куда обращается клиент | проверьте строку лога `Oracle-wire (TNS) listening addr=…`, значение `ORAPGLINK_ORACLE_LISTEN` и firewall. Удалённому клиенту нужен bind не на loopback |
| `password authentication failed for user "orapglink_runtime"` | неверный runtime DSN к PostgreSQL | проверьте роль, пароль, базу и `sslmode` в `ORAPGLINK_POSTGRES_DSN` — тот же DSN должен работать в `psql` |
| `ORA-01017: invalid username/password` у клиента | пароль клиента не равен `ORAPGLINK_ORACLE_PASSWORD` | исправьте пароль. Имя пользователя действительно не важно |
| `ORA-12514` или ошибки service name | service name клиента не равен `ORAPGLINK_LOGICAL_SCHEMA` | приведите их в соответствие |
| `ORA-03001: unimplemented feature` | запрос или wire-форма безопасно отклонены | посмотрите `TRANSLATOR_SUPPORT.md` и публичную матрицу проверок. Перепишите запрос или используйте passthrough `/*pg*/`. Сессия остаётся рабочей |
| `relation "oradict.dual" does not exist` или нет словарных представлений | `sql/oracle_compat_views.sql` не установлен или установлен в другую базу | повторите шаг 3.4 для той же базы, на которую указывает runtime DSN |
| `USER_TABLES` возвращает ноль строк, а `ALL_TABLES` — нет | литерал `'APP'` в словарной миграции не совпадает с `ORAPGLINK_LOGICAL_SCHEMA` | приведите их в соответствие (имя PostgreSQL-схемы в верхнем регистре) и повторите шаг 3.4 |
| таблица не видна orapglink, хотя есть в `psql` | она создана после провижининга другой ролью | `GRANT SELECT ON <таблица> TO orapglink_runtime;` (шаг 3.6) |
| имя пользователя в клиенте отличается от роли PostgreSQL | это single-tenant модель | так и задумано — все сессии используют один настроенный backend DSN (KNOWN_LIMITATIONS.md §2) |
| `ORA-16000` при записи | proxy работает только на чтение | запись выполняйте на стороне PostgreSQL его собственными средствами |
| запрос отваливается по тайм-ауту или возвращает меньше строк, чем ожидалось | сработали лимиты результата и тайм-аут запроса | осознанно увеличьте `--query-timeout`, `--max-result-rows`, `--max-result-bytes` — они существуют, чтобы защитить базу |

Для подробностей перезапустите с `--log-level debug`. Для эксплуатационного
наблюдения задайте `ORAPGLINK_METRICS_LISTEN=127.0.0.1:9109` и читайте
`/metrics`, `/healthz`, `/readyz` — учитывая, что у этого эндпоинта нет
аутентификации, держите его на loopback.

## Куда дальше

- **[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)** — что не работает и как это
  безопасно обойти.
- **`TRANSLATOR_SUPPORT.md`** — контракт трансляции Oracle→PostgreSQL по каждой
  возможности.
- **[Testing and verification](doc/testing.md)** — покрытие релиза по клиентам
  и матрица из 722 проверок.
- **`./orapglink -h`** — все флаги: лимиты ресурсов, тайм-ауты, обновление
  каталога, сворачивание идентификаторов.
- **[README.md](README.md)** — что это за проект и полный указатель документации.
