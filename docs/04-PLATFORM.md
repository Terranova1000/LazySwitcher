# 04 — macOS: API, разрешения и грабли

Целевая система: macOS 14.0+, разработка на macOS 15 Sequoia, Apple Silicon.
Всё, что здесь написано, проверено по документации Apple, заголовкам SDK, форумам
разработчиков и исходникам работающих проектов. Места, где я не уверен, помечены
явно — их надо проверить эмпирически.

---

## 1. Перехват клавиатуры

### 1.1 Создание tap'а

```swift
let mask = (1 << CGEventType.keyDown.rawValue)
         | (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(mask),
    callback: tapCallback,
    userInfo: Unmanaged.passUnretained(self).toOpaque()
) else { /* нет разрешения */ }
```

- `.cgSessionEventTap` — уровень сессии входа, работает без root.
  `.cghidEventTap` требует root и нам не нужен.
- `.headInsertEventTap` — встаём раньше уже установленных фильтров.
- `.defaultTap` — можем изменять и глотать события (нужно, чтобы проглотить хоткей).

**Ловушка из заголовка `CGEvent.h`:** если у процесса нет прав, соответствующие биты
маски **молча вычищаются**, и если после этого маска не пуста — вы получите живой tap,
который никогда не увидит ни одной клавиши. Поэтому запрашиваем **только клавиатурные**
события: тогда отказ будет громким (`nil`), а не тихим.

### 1.2 Какое разрешение нужно

| Режим | Может менять события | Разрешение |
|---|---|---|
| `.defaultTap` | да | **Универсальный доступ** (Accessibility) |
| `.listenOnly` | нет | Мониторинг ввода (Input Monitoring) |

Accessibility — надмножество: с ним отдельный запрос Мониторинга ввода не появится.
Нам нужен именно он, потому что мы (а) глотаем хоткеи **с обычными клавишами** — ⌃⌥L
и ⌃⌥C, иначе `L` и `C` уйдут в приложение, (б) обращаемся к AX чужих процессов,
(в) вызываем `CGEvent.post`.

Уточнение к (а): главный хоткей — двойной Shift — **не глотается никогда** и глотаться
не может, нажатия Shift уже произошли. То есть `.defaultTap` держится исключительно
ради ⌃⌥L / ⌃⌥C. Это стоит помнить: за `.defaultTap` мы платим риском из следующего
абзаца, а для этих двух хоткеев есть отступной путь — Carbon `RegisterEventHotKey`
(§1.6), которому не нужны разрешения вообще. Пункт (б) всё равно требует
Accessibility, поэтому вывод не меняется, но если `.defaultTap` начнёт создавать
проблемы, отступать есть куда.

**`AXIsProcessTrusted()` врать умеет** — он продолжает возвращать `true` после отзыва
доступа, а уведомление `com.apple.accessibility.api` не приходит, если пользователь
именно удалил приложение из списка, а не снял галочку.

Основная проверка — специально предназначенные для этого функции (macOS 10.15+):

```swift
CGPreflightListenEventAccess()   // можем ли читать события
CGPreflightPostEventAccess()     // можем ли отправлять
CGRequestListenEventAccess()     // запросить, с системным диалогом
CGRequestPostEventAccess()
```

Дополнительная перекрёстная проверка (не как основная — частое пересоздание tap'ов
само по себе ненадёжно) — создать пробный tap и сразу уничтожить:

```swift
func canFilterEvents() -> Bool {
    guard let p = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: { _,_,_,_ in nil }, userInfo: nil) else { return false }
    CFMachPortInvalidate(p)
    return true
}
```

**Опасность.** Если разрешение отзовут, пока `.defaultTap` жив, ввод может
заблокироваться системно до перезагрузки. Поэтому проверка идёт по таймеру раз в 5 с,
и при провале tap уничтожается немедленно.

Открыть нужный раздел настроек:
```swift
NSWorkspace.shared.open(URL(string:
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
```

### 1.3 Run loop

```swift
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
```

`.commonModes` обязательно. С `.defaultMode` tap глохнет, пока пользователь держит
открытым меню или тянет край окна.

### 1.4 `kCGEventTapDisabledByTimeout` — ошибка номер один

Система отключает tap, если колбэк слишком долго думает. Приходит служебное событие,
и без его обработки приложение просто перестаёт работать — молча.

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    CGEvent.tapEnable(tap: me.tap, enable: true)   // включить заново, НЕ пересоздавать
    return nil
}
```

Плюс сторожевой таймер каждые 5 с: `CGEvent.tapIsEnabled(tap:)`, и если false —
включить. Плюс подписка на `NSWorkspace.didWakeNotification`,
`sessionDidBecomeActiveNotification`, `sessionDidResignActiveNotification` с
перепроверкой — именно этим лечили ту же болезнь в терминале Ghostty, где глобальные
хоткеи умирали после сна.

Формулировка, которую стоит запомнить: **ненулевой tap — не значит живой tap.**

### 1.5 Что нельзя делать в колбэке

`.defaultTap` находится синхронно на пути события. Каждая микросекунда в колбэке —
это добавленная задержка ввода для всей системы, а превышение порога отключает tap.

Запрещено: `AXUIElementCopyAttributeValue` (это синхронный XPC в чужой процесс),
`NSPasteboard`, аллокации, блокировки, разделяемые с main thread, любые файловые
операции.

### 1.6 Почему не `NSEvent.addGlobalMonitorForEvents`

Проще, но не подходит: нельзя изменить или проглотить событие; не видит события
собственного приложения; всё равно требует Accessibility; в песочнице официально не
поддерживается; в Secure Input так же слеп. Годится только как запасной наблюдатель.

Для простого глобального хоткея без перехвата есть Carbon `RegisterEventHotKey` —
ему **не нужны никакие разрешения вообще**. Это хороший запасной путь для действий
над выделенным текстом.

---

## 2. Secure Input — главный защитный слой

### 2.1 Что это

```swift
import Carbon
IsSecureEventInputEnabled() -> Bool
```

Начиная с 10.4, режим глобальный: когда **любой** процесс его включает, клавиатурные
события перестают приходить **всем** перехватчикам в системе — и tap'ам, и захвату
HID, и старому `GetKeys()`. Неважно, в фокусе этот процесс или в фоне.

**Это значит, что прочитать пароль мы физически не можем.** Не «не хотим» — не можем.
Это стоит написать в описании приложения, потому что для пользователя это главный
вопрос доверия.

Практически: tap остаётся «включённым» (`tapIsEnabled` возвращает true), просто
`keyDown` не приходит. По состоянию tap'а это не обнаружить — только опросом
`IsSecureEventInputEnabled()`.

### 2.2 Асимметрия, из-за которой можно испортить пароль

**`flagsChanged` продолжают приходить, когда `keyDown` уже не приходят.** Это
задокументированная в баг-трекере Hammerspoon проблема: у пользователей на экране
блокировки срабатывали ремапы модификаторов и вставляли посторонние символы в пароль.

Для нас это прямая угроза: **двойной Shift работает на `flagsChanged`.** Без проверки
`IsSecureEventInputEnabled()` он сработает посреди ввода пароля и запустит замену
текста в поле пароля.

Правило: **любая реакция на `flagsChanged` обязана быть под проверкой Secure Input.**

### 2.3 Кто его включает

Нативные `NSSecureTextField` — автоматически и корректно. Хронические нарушители,
оставляющие режим включённым надолго: Terminal.app (там это ручная настройка
«Защищённый ввод»), 1Password, LastPass, Bitwarden, KeePassXC, Chrome (иногда не
выключает после поля пароля), Firefox, Slack, Parallels, Authy, экран блокировки.

Режим может залипнуть на часы. Это не редкий краевой случай, а нормальная ситуация.

### 2.4 Как себя вести

1. Опрашивать раз в 1 с, плюс на `didActivateApplication`, плюс на смену фокуса.
2. При включении: немедленно затереть буфер, остановить всё, сменить иконку на
   «заблокировано».
3. Никогда не вызывать `EnableSecureEventInput()` самим.
4. В меню показать причину. PID виновника достаётся из IORegistry
   (`IOService:/IOResources/IOConsoleUsers` → `CGSSessionSecureInputPID`), **но
   у macOS есть известный баг: для фонового приложения указывается не тот процесс.**
   Поэтому формулировка мягкая: «похоже, ввод перехватило…».

Проверочный стенд: `python3 -c 'import getpass; getpass.getpass()'` в терминале.

---

## 3. Определение поля ввода

### 3.1 Запрос

```swift
let pid = NSWorkspace.shared.frontmostApplication!.processIdentifier
let appEl = AXUIElementCreateApplication(pid)
var focused: CFTypeRef?
AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused)
// role == "AXTextField", subrole == "AXSecureTextField"
```

Обратите внимание: **роли `AXSecureTextField` не существует.** Это всегда роль
`AXTextField` плюс подроль `AXSecureTextField`.

### 3.2 Работает ли это для паролей на сайтах — да

Проверено по исходникам браузеров:

- **WebKit** (`AccessibilityObjectMac.mm`): `if (isSecureField()) return
  NSAccessibilitySecureTextFieldSubrole;`. Плюс для таких полей отдаётся урезанный
  набор атрибутов, а `AXVisibleCharacterRange` возвращает nil — значение просто не
  выставляется наружу.
- **Chromium** (`ax_platform_node_cocoa.mm`): роль `kTextField` со статусом
  `kProtected` → та же подроль. Это покрывает Chrome, Edge, Brave, Arc и все
  Electron-приложения.
- Firefox ведёт себя так же.

То есть `<input type="password">` определяется корректно во всех браузерах.

### 3.3 Проблема Chromium и Electron

Дерево доступности в Chromium **выключено по умолчанию** и включается по требованию.
Пока оно не включилось, `kAXFocusedUIElementAttribute` вернёт грубый `AXWebArea` или
`AXGroup`, а не текстовое поле. Обращение к атрибутам обычно включает режим, но не
мгновенно и не гарантированно — первый запрос после запуска Chrome часто бесполезен.

У Electron есть явный переключатель `AXManualAccessibility`, но в части версий он
не работает и возвращает `-25205`. Приватный `AXEnhancedUserInterface` имеет побочные
эффекты (окна начинают прыгать) — **не использовать**.

Вывод: полагаться только на AX нельзя, нужны слои ниже.

### 3.4 Стоимость запроса

`AXUIElementCopyAttributeValue` — синхронный XPC в главный поток чужого приложения.
Зависший Chrome подвесит наш запрос. Обязательно:

```swift
AXUIElementSetMessagingTimeout(element, 0.2)
AXUIElementCopyMultipleAttributeValues(el, [kAXRoleAttribute, kAXSubroleAttribute] as CFArray,
                                       .stopOnError, &values)
```

И никогда — из потока клавиш.

### 3.5 Правильный способ: наблюдатель, а не опрос

```swift
AXObserverCreate(pid, callback, &observer)
AXObserverAddNotification(observer!, appEl,
    kAXFocusedUIElementChangedNotification as CFString, refcon)
CFRunLoopAddSource(CFRunLoopGetCurrent(),
    AXObserverGetRunLoopSource(observer!), .commonModes)   // .commonModes, см. §1.3
```

Плюс `kAXFocusedWindowChangedNotification`. Наблюдатель создаётся **на каждый
процесс отдельно** и уничтожается при выходе приложения — отслеживаем через
`NSWorkspace.shared.notificationCenter`, `didActivateApplicationNotification`.

Результат кладём в кэш. Поток клавиш читает кэш — это обычное чтение из памяти.

### 3.6 Три слоя защиты паролей

1. **Secure Input** — ловит нативные поля, терминал, экран блокировки. Абсолютная
   защита: событий физически нет.
2. **Подроль `AXSecureTextField`** — ловит пароли на сайтах и в приложениях, которые
   не включают Secure Input.
3. **Список приложений** — 1Password (`com.1password.1password`,
   `com.agilebits.onepassword7`), Bitwarden, KeePassXC, Dashlane, LastPass, Связка
   ключей (`com.apple.keychainaccess`), Terminal, iTerm2, Secretive. Неудаляемые.

Плюс четвёртый, эвристический: слово без пробелов, длиннее 12 символов, со смешанным
регистром, цифрами и знаками — не трогаем даже в обычном поле. Это защита от
приложений, которые рисуют поле пароля сами.

**И главное правило: если AX молчит или вернул элемент без роли — не делаем ничего.**

### 3.7 Коды ошибок, которые надо различать в логах

| Код | Что значит |
|---|---|
| `-25211` `kAXErrorAPIDisabled` | Доступ не выдан **нашему процессу**. При рассинхроне подписи приходит именно он — при зелёной галочке в настройках |
| `-25205` `kAXErrorAttributeUnsupported` | Норма для `AXManualAccessibility` в Electron |
| `-25204` `kAXErrorCannotComplete` | Приложение не отвечает или не поддерживает AX; отступаем |

---

## 4. Замена текста

### 4.1 Основной способ: Backspace + Unicode

```swift
let src = CGEventSource(stateID: .privateState)!
src.userData = 0x4C5A_5357                     // "LZSW" — наша метка
src.localEventsSuppressionInterval = 0         // иначе глушим реальный ввод на 0.25 с

func sendBackspaces(_ n: Int) {
    for _ in 0..<n {
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true)!
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false)!
        down.flags = []; up.flags = []          // обязательно
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        usleep(3000)
    }
}

// chunked(into:) в стандартной библиотеке нет — пишем свой в Support/,
// и режем по границам символов, а не по фиксированному числу UTF-16 единиц,
// иначе можно разорвать суррогатную пару
func typeUnicode(_ s: String) {
    for chunk in s.utf16Chunks(maxUnits: 20) {
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        down.flags = []; up.flags = []
        chunk.withUnsafeBufferPointer {
            down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        usleep(4000)
    }
}
```

Оговорка из заголовка `CGEvent.h`: фреймворки приложения **могут проигнорировать**
переданную строку и сами перевести код клавиши. На практике AppKit, Chromium и
Electron строку уважают; некоторые Java-приложения, игры и терминалы с собственным
протоколом клавиатуры — нет.

Паузы 2–4 мс — эмпирический минимум; espanso по той же причине держит настраиваемые
задержки со значением по умолчанию 10 мс. Сделать настраиваемыми на приложение.

### 4.2 Способ для нативных полей: Accessibility

```swift
var range = CFRange(location: wordStart, length: wordLen)
AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &range)!)
AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, corrected as CFTypeRef)
```

Одна операция, мгновенно, сохраняет undo приложения. Но:

| Класс приложений | Работает |
|---|---|
| Нативные `NSTextField` / `NSTextView` | да |
| Веб-содержимое в любом браузере | **нет — возвращает успех и ничего не делает** |
| Electron (Slack, VS Code, Discord) | в основном нет |
| Терминалы | нет |

«Успех, но ничего не произошло» — самый противный вид отказа. Поэтому после AX-замены
надо проверять результат, а браузеры сразу вести по второму способу.

**`kAXValueAttribute` целиком не переписывать никогда.** Это уничтожает undo,
сбрасывает каретку в начало, обходит валидацию поля.

### 4.3 Буфер обмена — только по явному включению

Работает почти везде, включая браузеры. Но: засоряет историю Paste/Maccy/Raycast,
улетает на iPhone через Universal Clipboard, требует восстановления с задержкой
~300 мс (раньше — приложение не успевает вставить, позже — теряется то, что
пользователь скопировал сам). Обязательна проверка `changeCount` перед
восстановлением. Плюс в терминалах ⌘C может послать SIGINT.

Если включён — сохранять **все** типы данных с доски, не только строку.

### 4.4 Порядок выбора стратегии

```
1. Нативное поле, доступное для записи через AX  → AX
2. Всё остальное                                  → Backspace + Unicode
3. Слово длиннее ~40 символов ИЛИ для этого приложения
   способ 2 уже подводил                          → буфер обмена (если разрешён)
4. Определить не удалось                          → ничего не делаем
```

### 4.5 Не съесть собственные события

Без этого — бесконечный цикл.

```swift
// первой же строкой колбэка
if event.getIntegerValueField(.eventSourceUserData) == 0x4C5A_5357 {
    return Unmanaged.passUnretained(event)
}
```

Для надёжности ещё сравниваем `.eventSourceUnixProcessID` с `getpid()` и держим флаг
`isInjecting` с явным сроком годности.

**Выбор `CGEventSourceStateID` важен:** `.privateState` — независимое состояние, наш
синтетический Shift не смешивается с реальным. `.combinedSessionState` смешивается, и
залипший синтетический модификатор испортит пользователю ввод.

### 4.6 Прочие грабли

- **Флаги модификаторов.** Явно обнулять на каждом синтетическом событии, иначе при
  зажатом пользователем Shift всё поедет.
- **Автоповтор.** Поле `kCGKeyboardEventAutorepeat` ненулевое при автоповторе.
  Игнорировать: зажатый Backspace иначе устроит потоп.
- **Автодополнение** в Safari и Chrome: наш Backspace может отменить подсказку вместо
  удаления символа, и счётчик разъедется. В браузерах предпочитать другие способы и
  проверять результат.
- **Undo.** Backspace + ввод дают N+1 запись в истории отмен в одних редакторах и одну
  в других. Портируемого способа сделать ⌘Z атомарным нет — поэтому у нас свой откат
  с окном 5 секунд.
- **Гонка по времени.** Многие приложения обрабатывают текст асинхронно; между
  событием-триггером и первым Backspace нужна пауза 10–30 мс.
- **macOS 26 Tahoe (проверить).** Есть сообщение, что WindowServer стал жёстче
  фильтровать синтетические события через `CGXSenderCanSynthesizeEvents()`, причём
  **обычные нажатия проходят, а комбинации с модификаторами — нет**. Речь была о
  неподписанном демоне. Для нас это значит: основной путь (Backspace + Unicode) —
  наименее уязвим, а способ через ⌘V — наиболее. Проверить перед релизом.

---

## 5. Раскладки

### 5.1 Перечисление и переключение

```swift
let filter: [CFString: Any] = [
    kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!
    // kTISPropertyInputSourceIsEnableCapable здесь НЕ нужен: он означает
    // «можно включить», а не «включена». Список включённых даёт includeAllInstalled: false
]
let list = TISCreateInputSourceList(filter as CFDictionary, false)?
             .takeRetainedValue() as? [TISInputSource]

let current = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
TISSelectInputSource(target)
```

`TISGetInputSourceProperty` возвращает нетипизированный указатель — обязательно через
`Unmanaged<AnyObject>.fromOpaque(_).takeUnretainedValue()`. Это функция типа *Get*,
освобождать результат не нужно.

Второй аргумент `TISCreateInputSourceList` передавать `false` — с `true` заметно
растёт потребление памяти.

**Три разных «текущих»:**
- `TISCopyCurrentKeyboardInputSource()` — что выбрано (может быть метод ввода)
- `TISCopyCurrentKeyboardLayoutInputSource()` — **раскладка, которая реально
  используется**, включая ту, что лежит под методом ввода. ← нужна нам
- `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()` — последняя ASCII-совместимая

Подписка на смену — через `CFNotificationCenterGetDistributedCenter` и
`kTISNotifySelectedKeyboardInputSourceChanged`.

### 5.2 Таблица символов из системы

Главная идея, из-за которой в коде нет ни одной захардкоженной буквы:
`kTISPropertyUnicodeKeyLayoutData` доступно **у любой раскладки, не только у активной**.
То есть можно получить данные русской раскладки, пока активна английская, и узнать,
какой символ дала бы эта клавиша там — без всякого переключения.

```swift
func char(forKeyCode kc: UInt16, shift: Bool, layout: Data) -> String? {
    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0                          // Int, не UniCharCount — см. 00-DECISIONS.md, Н4а
    let modifierKeyState = ((shift ? UInt32(shiftKey) : 0) >> 8) & 0xFF   // сдвиг на 8 обязателен

    return layout.withUnsafeBytes { raw in
        let kbd = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        // options = 0: мёртвые клавиши ОБРАБАТЫВАЮТСЯ (см. предупреждение ниже)
        var st = UCKeyTranslate(kbd, kc, UInt16(kUCKeyActionDown), modifierKeyState,
                                UInt32(LMGetKbdType()), OptionBits(0),
                                &deadKeyState, chars.count, &length, &chars)
        // мёртвая клавиша: первый вызов её проглатывает и не даёт символов, нужен второй
        if st == noErr, length == 0, deadKeyState != 0 {
            st = UCKeyTranslate(kbd, kc, UInt16(kUCKeyActionDown), modifierKeyState,
                                UInt32(LMGetKbdType()), OptionBits(0),
                                &deadKeyState, UniCharCount(chars.count), &length, &chars)
        }
        guard st == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: Int(length))
    }
}
```

> ⚠️ **Ловушка с константой.** `kUCKeyTranslateNoDeadKeysBit` — это **номер бита, равный 0**,
> а не маска. Маска называется `kUCKeyTranslateNoDeadKeysMask` и равна 1. Код, который
> передаёт `…Bit` (так написано в `node-native-keymap` внутри VS Code, и оттуда это
> разошлось по интернету), на самом деле передаёт ноль, то есть **не отключает** мёртвые
> клавиши — и работает только благодаря этому. Мы передаём `OptionBits(0)` явно и
> обрабатываем мёртвые клавиши вторым вызовом. Если кто-то «исправит» константу на
> `…Mask`, второй вызов станет мёртвым кодом, а мёртвые клавиши перестанут работать.

Определить, ISO ли физически клавиатура (важно для клавиши между левым Shift и Z):
```swift
KBGetLayoutType(Int16(LMGetKbdType())) == OSType(kKeyboardISO)
```
Обратите внимание на приведения типов: `LMGetKbdType()` возвращает `UInt8`,
`KBGetLayoutType` принимает `SInt16`, а `kKeyboardISO` — это четырёхсимвольный код `OSType`.

### 5.3 Когда данных нет

Из заголовка: значение равно NULL для источников, которые не являются раскладками
(иероглифические методы ввода). `node-native-keymap` в этом случае откатывается на
`TISCopyCurrentKeyboardLayoutInputSource()`. Повторяем это, а если и там NULL —
отключаемся, а не гадаем.

### 5.4 Хранить коды, а не символы

В буфере лежат `(keyCode, flags)`. Конверсия — один поиск в таблице целевой раскладки,
без обратного отображения и без неоднозначности символов, встречающихся на нескольких
клавишах. Побочная выгода: правильно работают символы с Shift и, в будущем,
справа-налево письменности.

Код клавиши из события: `event.getIntegerValueField(.keyboardEventKeycode)`.

---

## 6. Подпись и распространение без платного аккаунта

### 6.1 Чего у нас нет

Бесплатный Apple ID даёт Xcode, запуск на своих устройствах и Personal Team.
Он **не даёт** Developer ID для Mac и **не даёт нотаризации** — это только платно.
Значит, приложение навсегда останется «незаверенным» для Gatekeeper. Планируем
вокруг этого, а не боремся с этим.

### 6.2 Настоящая проблема — не Gatekeeper, а TCC

Gatekeeper — разовое неудобство при установке. TCC — повторяется при **каждом**
обновлении, и вот почему.

macOS запоминает выданное разрешение вместе с **designated requirement** подписи.
У ad-hoc подписи стабильного DR нет — она привязана к хешу содержимого. Пересобрали →
хеш другой → система считает, что это другая программа.

Дальше самое неприятное: значение «разрешено» в базе **остаётся**. То есть галочка в
Системных настройках горит зелёным, а на деле:

- `AXUIElementCopyAttributeValue` → `-25211`
- `CGEvent.tapCreate` → молча `nil`
- `CGEvent.post` → события молча теряются

И переразрешить из интерфейса нельзя: система показывает диалог, где есть «Открыть
настройки» и «Запретить», но нет «Разрешить». Единственный выход — `tccutil reset`
в терминале.

Именно поэтому в CLAUDE.md стоит запрет на ad-hoc подпись.

### 6.3 Решение: самоподписанный сертификат

Делается один раз, бесплатно, без всякого аккаунта Apple:

```bash
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout dev.key -out dev.crt -subj "/CN=Lazy Switcher Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

# -legacy обязателен, иначе Связка ключей не примет
openssl pkcs12 -export -legacy -in dev.crt -inkey dev.key -out dev.p12 -password pass:...

security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P ... -T /usr/bin/codesign
# затем в Связке ключей: найти сертификат → Доверять → Подписывание кода: Всегда доверять

codesign --force --options runtime --timestamp=none --sign "Lazy Switcher Signing" "Lazy Switcher.app"
codesign -d -r- "Lazy Switcher.app"      # посмотреть получившийся DR
```

Designated requirement привяжется к хешу сертификата, а он стабилен, пока цел `.p12`.

**Потеря `dev.p12` = всем пользователям заново выдавать разрешения.** Хранить в
надёжном месте, в репозиторий не класть.

Подписывать снизу вверх (вложенные фреймворки и хелперы раньше самого бандла).
**Не использовать `--deep` при подписи** — он работает плохо и ломает подпись.
При *проверке* (`codesign --verify --deep --strict`) флаг, наоборот, уместен и нужен.

> ⚠️ Требует эмпирической проверки. Механизм описан в форумах Apple и логически следует
> из модели DR, но прямого утверждения Apple о том, что самоподписанный сертификат
> сохраняет разрешения **на машине пользователя между обновлениями**, я не нашёл.
> Тест на этапе M0: поставить v1 на чистую систему, выдать доступ, поставить v2 с той
> же подписью, проверить, что доступ жив. От результата зависит стратегия обновлений.

Запасной вариант — бесплатный сертификат Personal Team из Xcode. Ограничения (7 дней
на App ID и профили) касаются в основном iOS; для macOS-приложения без ограниченных
entitlements профиль обычно не нужен, и тогда важен только сертификат со сроком ~год.
Это тоже не подтверждено — проверить, если самоподписанный не сработает.

### 6.4 Что увидит пользователь на macOS 15

- Незаверенное приложение из интернета: «не удаётся проверить, что оно не содержит
  вредоносного ПО».
- **«Правый клик → Открыть» больше не работает** — Apple убрала этот обход начиная с
  Sequoia. Путь теперь: попытаться открыть → Системные настройки → Конфиденциальность
  и безопасность → пролистать вниз → «Всё равно открыть» → подтвердить → ввести пароль.
- «Приложение повреждено и не может быть открыто» означает **сломанную подпись**, а не
  отсутствие нотаризации. Причина обычно в `--deep` или в изменении бандла после
  подписи.
- Неподписанный код на Apple Silicon не запускается вообще. Подпись обязательна.

Команда, которую стоит дать пользователю в README:
```bash
xattr -dr com.apple.quarantine "/Applications/Lazy Switcher.app"
```
После неё приложение открывается вообще без диалогов.

**Не советовать `sudo spctl --global-disable`** — это ослабляет всю систему, и macOS
всё равно периодически включает защиту обратно.

### 6.5 DMG, а не ZIP

Приложение, запущенное из `~/Downloads` после распаковки ZIP, попадает под App
Translocation: система монтирует его копию в случайную папку только для чтения.
Настройки перестают сохраняться, самообновление ломается, и понять причину невозможно.

**Важная оговорка:** сам по себе DMG от Translocation не спасает — запуск прямо из
смонтированного образа приводит ровно к тому же. Её снимает **перенос бандла через
Finder** (или очистка атрибута карантина). Ярлык «Программы» в окне образа существует
именно затем, чтобы пользователь этот перенос совершил. То есть DMG не решает проблему
технически, а навязывает правильный ритуал — и этого достаточно.

---

## 7. Форма приложения

### 7.1 Агент в строке меню

```xml
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAccessibilityUsageDescription</key>
<string>Нужно, чтобы замечать текст, набранный не в той раскладке, и исправлять его.</string>
```

```swift
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.image = NSImage(named: "MenuBarIcon")   // template image
```

Держать **сильную ссылку** на `NSStatusItem` — иначе иконка молча исчезнет.

SwiftUI `MenuBarExtra` не используем: у него есть давняя утечка, когда SwiftUI-вью в
`NSMenuItem` не освобождается. Для приложения, живущего неделями, это важно.

### 7.2 Автозапуск

```swift
import ServiceManagement
try? SMAppService.mainApp.register()
SMAppService.mainApp.status    // .enabled / .requiresApproval / .notRegistered / .notFound
```

Состояние читать **у системы**, не из своих настроек: пользователь может убрать
приложение из «Объектов входа» в любой момент. Перечитывать при активации приложения.
`.requiresApproval` показывать явно — значит, нужно подтверждение в настройках системы.

`SMLoginItemSetEnabled` устарел с 13.0, ручные plist в `~/Library/LaunchAgents` —
legacy. Для одиночного бандла правильный вызов — `SMAppService.mainApp`.

Для надёжной регистрации приложение должно лежать в `/Applications` — что совпадает с
требованием стабильности пути для TCC.

### 7.3 Песочница — нельзя

| Что нужно | В песочнице |
|---|---|
| `.defaultTap` (менять события) | **нет** — требует Accessibility |
| `AXIsProcessTrustedWithOptions` | **нет** |
| AX-запросы к чужим процессам (`AXUIElementCreateApplication`) | **нет** |
| `CGEvent.post()` | да, если выдан грант PostEvent |
| `.listenOnly` + Мониторинг ввода | да |

Уточнение, которое часто перевирают: `CGEvent.post` **совместим** с песочницей — ему
нужен грант PostEvent, а он в Системных настройках показывается в разделе
«Универсальный доступ», отсюда и путаница. Несовместима именно **привилегия
Accessibility**, то есть `.defaultTap` и обращения к AX чужих процессов. Нам нужны и
то и другое, поэтому вывод не меняется: **песочницы у нас нет.** Ключа
`com.apple.security.app-sandbox` в проекте нет.
Hardened Runtime включаем — он ничего не стоит и пригодится, если когда-нибудь
появится платный аккаунт.

**Никакой entitlement не выдаёт Accessibility.** Это пользовательское согласие, а не
право приложения. Встречающийся в блогах `com.apple.security.accessibility` для нашего
случая ничего не значит.

### 7.4 Расход ресурсов — ориентиры

- Голый агент с иконкой: ~15–25 МБ «Памяти» в Мониторинге системы (в основном общие
  страницы фреймворков).
- Окно настроек на AppKit: +5–10 МБ, освобождается при закрытии.
- Event tap и AX-наблюдатели: меньше 1 МБ.
- Модели через `mmap`: страницы файловые, выгружаемые, в покое почти ничего.

Цель — меньше 40 МБ. Выше 80 МБ для агента в строке меню — это уже жалобы.

---

## 8. Что проверить эмпирически

| # | Что | Когда |
|---|---|---|
| 1 | Переживают ли разрешения обновление при самоподписи | M0 |
| 2 | Порог отключения tap'а по таймауту (Apple не документирует) | измерить |
| 3 | Работает ли синтетика ⌘V на macOS 15 и 26 | M4 |
| 4 | Действительно ли обращение к AX включает дерево доступности в Chrome | M3 |
| 5 | Поведение `keyboardSetUnicodeString` в конкретных приложениях | M4, таблица |
| 6 | Реальный расход памяти после суток работы | M6 |
