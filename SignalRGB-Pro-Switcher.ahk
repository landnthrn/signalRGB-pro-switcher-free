#Requires AutoHotkey v2.0
#SingleInstance Force

; =====================================================================
; SignalRGB Pro Switcher Free
; AutoHotkey v2
;
; Default go-to-next hotkeys:
;   Ctrl + Alt + P = Go to next preset
;   Ctrl + Alt + E = Go to next effect
;   Ctrl + Alt + L = Go to next layout
;   Ctrl + Alt + S = Show current status
; Default picker hotkeys:
;   Ctrl + Alt + Shift + P = Choose a preset
;   Ctrl + Alt + Shift + E = Choose an effect
;   Ctrl + Alt + Shift + L = Choose a layout
;   Ctrl + Alt + Shift + M = Open picker menu
;
; Companion files:
;   config.ini
;   data\inventory.ini
;   scripts\config-editor.ps1
;   scripts\config-editor.xaml
;   scripts\inventory-creator-updater.ps1
; =====================================================================


; =====================================================================
; GLOBAL CONSTANTS
; =====================================================================

global APP_NAME := "SignalRGB Pro Switcher Free"
global STARTUP_SHORTCUT_NAME := "SignalRGB-Pro-Switcher-Free.lnk"

global CONFIG_PATH :=
    A_ScriptDir "\config.ini"

global INVENTORY_PATH :=
    A_ScriptDir "\data\inventory.ini"

global UPDATER_PATH :=
    A_ScriptDir "\scripts\inventory-creator-updater.ps1"

global CONFIG_EDITOR_PATH :=
    A_ScriptDir "\scripts\config-editor.ps1"

global LOG_PATH :=
    A_ScriptDir "\log.txt"

global REG_ROOT :=
    "HKEY_CURRENT_USER\SOFTWARE\WhirlwindFX\SignalRgb"

global EFFECTS_KEY :=
    REG_ROOT "\effects"

global SELECTED_EFFECT_KEY :=
    EFFECTS_KEY "\selected"

global STATES_KEY :=
    REG_ROOT "\states"

global LAYOUTS_KEY :=
    REG_ROOT "\layouts"


; =====================================================================
; GLOBAL RUNTIME STATE
; =====================================================================

global gConfig := Map()
global gRegisteredHotkeys := []

global gBusy := false
global gLastSeenEffectId := ""

global gInventoryCheckBusy := false
global gUpdaterFailureNotified := false
global gInventoryLiveDataUnavailableLogged := false
global gCyclingRandomEffects := []
global gCyclingRandomPresets := Map()
global gLastEffectCycleTick := 0
global gLastPresetCycleTick := 0

global gNotifyGui := 0
global gNotifyText := 0
global gNotifyClickHotkeysActive := false
global NOTIFY_CLICK_DISMISS_HOTKEYS := [
    "~*LButton",
    "~*RButton",
    "~*MButton",
    "~*XButton1",
    "~*XButton2"
]

global gUxThemeModule := 0
global gSetPreferredAppMode := 0
global gAllowDarkModeForApp := 0
global gAllowDarkModeForWindow := 0
global gFlushMenuThemes := 0
global gRefreshImmersiveColorPolicyState := 0
global gThemeWinEventCallback := 0
global gThemeWinEventHook := 0
global gCurrentAppThemeIsDark := ""
global WINDOWS_THEME_PERSONALIZE_KEY :=
    "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"


; =====================================================================
; STARTUP
; =====================================================================

Initialize()
return


; =====================================================================
; INITIALIZATION
; =====================================================================

Initialize() {
    global gConfig
    global gLastSeenEffectId
    global CONFIG_PATH
    global INVENTORY_PATH

    InitializeWindowsAppTheme()

    BootstrapConfiguration()

    gConfig := LoadConfig()

    EnsureInventoryCurrent(
        false
    )

    ; Reload once after the updater has had a chance to create or update
    ; config.ini and data\inventory.ini.
    gConfig := LoadConfig()

    BuildTrayMenu()
    RegisterConfiguredHotkeys()

    if !gConfig["Behavior"]["RememberLastActiveEffectPreset"] {
        ApplyStartupConfiguredSelection()
    }

    currentEffect := GetSelectedEffect()
    gLastSeenEffectId := currentEffect["Id"]

    SetTimer(
        WatchActiveEffect,
        500
    )

    ConfigureInventoryUpdateTimer()
    ConfigureAutomaticCyclingTimers()

    if gConfig["Behavior"]["ApplyPoliciesOnStartup"]
        && currentEffect["Id"] != ""
        && currentEffect["Name"] != "" {
        try {
            Sleep(300)

            ApplyEffectActivationPolicy(
                currentEffect["Id"],
                currentEffect["Name"]
            )
        } catch as err {
            WriteLog(
                "Startup policy error: " .
                FormatErrorDetails(err)
            )
        }
    }

    if !FileExist(INVENTORY_PATH) {
        Notify(
            "data\inventory.ini could not be created or found.`n" .
            "Run the creator/updater in the app."
        )
    }

    if !FileExist(CONFIG_PATH) {
        Notify(
            "config.ini could not be created or found.`n" .
            "Run the creator/updater in the app."
        )
    }

    SyncLaunchOnStartupShortcut()

    WriteLog(
        "Script initialized."
    )
}


; =====================================================================
; STARTUP SHORTCUT
; =====================================================================

QuoteProcessArgument(value) {
    if !RegExMatch(value, '[ \t"]')
        return value

    return '"' StrReplace(value, '"', '\"') '"'
}

NormalizePathText(path) {
    path := Trim(path, " `t`"")
    path := StrReplace(path, "/", "\")

    while StrLen(path) > 3 && SubStr(path, -1) = "\"
        path := SubStr(path, 1, StrLen(path) - 1)

    return StrLower(path)
}

GetShortcutReferencedScriptPath(shortcut) {
    targetPath := shortcut.TargetPath
    arguments := Trim(shortcut.Arguments)

    if RegExMatch(targetPath, "i)\.ahk$")
        return targetPath

    if RegExMatch(arguments, '^"([^"]+)"', &match)
        return match[1]

    if RegExMatch(arguments, "^(\S+)", &match)
        return match[1]

    return targetPath
}

WriteStartupShortcut(shortcutPath) {
    shortcut := ComObject("WScript.Shell").CreateShortcut(shortcutPath)
    shortcut.TargetPath := A_AhkPath
    shortcut.Arguments := QuoteProcessArgument(A_ScriptFullPath)
    shortcut.WorkingDirectory := A_ScriptDir
    shortcut.Description := "Launch SignalRGB Pro Switcher Free"
    shortcut.IconLocation := A_AhkPath
    shortcut.Save()
}

SyncLaunchOnStartupShortcut() {
    global gConfig
    global STARTUP_SHORTCUT_NAME

    try {
        if !DirExist(A_Startup)
            DirCreate A_Startup

        shortcutPath := A_Startup "\" STARTUP_SHORTCUT_NAME
        enabled := gConfig["Behavior"]["LaunchOnStartup"]

        if !enabled {
            if FileExist(shortcutPath)
                FileDelete shortcutPath

            return
        }

        if FileExist(shortcutPath) {
            existingShortcut := ComObject("WScript.Shell").CreateShortcut(shortcutPath)
            referencedScript := GetShortcutReferencedScriptPath(existingShortcut)

            if NormalizePathText(referencedScript) = NormalizePathText(A_ScriptFullPath)
                && NormalizePathText(existingShortcut.WorkingDirectory) = NormalizePathText(A_ScriptDir) {
                return
            }
        }

        WriteStartupShortcut(shortcutPath)
    } catch as err {
        WriteLog(
            "Startup shortcut error: " .
            FormatErrorDetails(err)
        )
    }
}


; =====================================================================
; DEFAULT CONFIGURATION
; =====================================================================

CreateDefaultConfig() {
    config := Map()

    config["Assets"] := Map(
        "AutoUpdateInventory", false,
        "InventoryFile", "data\inventory.ini",
        "UpdaterScript", "scripts\inventory-creator-updater.ps1"
    )

    config["Integration"] :=
        config["Assets"]

    config["Hotkeys"] := Map(
        "OpenPickerMenu", "^!+m",
        "PickPreset", "^!+p",
        "PickEffect", "^!+e",
        "PickLayout", "^!+l",
        "GoToNextPreset", "^!p",
        "GoToNextEffect", "^!e",
        "GoToNextLayout", "^!l",
        "ShowStatus", "^!s"
    )

    config["Behavior"] := Map(
        "ShowHotkeyNotifications", true,
        "Logging", false,
        "WatchExternalEffectChanges", true,
        "AutoUpdateInventoryInterval", 150,
        "ExcludeFromPickers", false,
        "ExcludeFromNextHotkeys", true,
        "ExcludeFromCycling", true,

        ; LastUsed:
        ;   Retain the effect's most recently used preset.
        ;
        ; Preferred:
        ;   Apply the first live preset under [PresetOrder.<Effect Name>].
        "PresetOnEffectActivation", "LastUsed",

        ; Current:
        ;   Effects without an assignment retain the current layout.
        ;
        ; DefaultLayout:
        ;   Effects without an assignment use DefaultLayout.
        "UnassignedEffectLayoutMode", "Current",

        "DefaultLayout", "",
        "LaunchOnStartup", false,
        "ApplyPoliciesOnStartup", true,
        "RememberLastActiveEffectPreset", true
    )

    config["Cycling"] := Map(
        "EffectCyclingEnabled", false,
        "EffectCyclingMode", "Order",
        "EffectCyclingInterval", 900,
        "CycleEffectOnceAllPresetsElapsed", false,
        "PresetCyclingEnabled", false,
        "PresetCyclingMode", "Order",
        "PresetCyclingInterval", 900
    )

    ; Generated Effect ID = effect name catalog loaded from data\inventory.ini.
    config["Effects"] := Map()

    ; Explicit configured order overrides natural A-Z order.
    config["EffectOrder"] := []

    ; Effect IDs or names excluded from pickers, go-to-next hotkeys, and cycling.
    config["IgnoredEffects"] := Map()

    ; Effect ID plus preset names excluded from pickers, go-to-next hotkeys, and cycling.
    config["IgnoredPresets"] := Map()

    ; Per-effect explicit preset order cache.
    config["PresetOrderCache"] := Map()

    ; Effect ID or effect name = assigned layout.
    config["EffectLayouts"] := Map()

    ; Explicit configured order overrides natural A-Z order.
    config["LayoutOrder"] := []

    ; Layouts excluded from go-to-next hotkeys and pickers.
    config["IgnoredLayouts"] := Map()

    config["FavoriteEffects"] := Map()
    config["FavoritePresets"] := Map()
    config["FavoriteLayouts"] := Map()

    return config
}


; =====================================================================
; CONFIGURATION LOADING
; =====================================================================

LoadConfig() {
    global CONFIG_PATH

    config := CreateDefaultConfig()

    config["Assets"]["AutoUpdateInventory"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "AutoUpdateInventory",
                ReadIniValue(
                    "Integration",
                    "AutoUpdateInventory",
                    config["Assets"]["AutoUpdateInventory"]
                        ? "true"
                        : "false"
                )
            ),
            config["Assets"]["AutoUpdateInventory"]
        )

    config["Assets"]["InventoryFile"] :=
        ReadIniValue(
            "Assets",
            "InventoryFile",
            ReadIniValue(
                "Integration",
                "InventoryFile",
                config["Assets"]["InventoryFile"]
            )
        )

    config["Assets"]["UpdaterScript"] :=
        ReadIniValue(
            "Assets",
            "UpdaterScript",
            ReadIniValue(
                "Integration",
                "UpdaterScript",
                config["Assets"]["UpdaterScript"]
            )
        )

    config["Integration"] :=
        config["Assets"]

    ResolveConfiguredCompanionPaths(
        config
    )

    config["Hotkeys"]["OpenPickerMenu"] :=
        ReadIniValue(
            "Hotkeys",
            "OpenPickerMenu",
            config["Hotkeys"]["OpenPickerMenu"]
        )

    config["Hotkeys"]["PickPreset"] :=
        ReadIniValue(
            "Hotkeys",
            "PickPreset",
            config["Hotkeys"]["PickPreset"]
        )

    config["Hotkeys"]["PickEffect"] :=
        ReadIniValue(
            "Hotkeys",
            "PickEffect",
            config["Hotkeys"]["PickEffect"]
        )

    config["Hotkeys"]["PickLayout"] :=
        ReadIniValue(
            "Hotkeys",
            "PickLayout",
            config["Hotkeys"]["PickLayout"]
        )

    config["Hotkeys"]["GoToNextPreset"] :=
        ReadIniValue(
            "Hotkeys",
            "GoToNextPreset",
            config["Hotkeys"]["GoToNextPreset"]
        )

    config["Hotkeys"]["GoToNextEffect"] :=
        ReadIniValue(
            "Hotkeys",
            "GoToNextEffect",
            config["Hotkeys"]["GoToNextEffect"]
        )

    config["Hotkeys"]["GoToNextLayout"] :=
        ReadIniValue(
            "Hotkeys",
            "GoToNextLayout",
            config["Hotkeys"]["GoToNextLayout"]
        )

    config["Hotkeys"]["ShowStatus"] :=
        ReadIniValue(
            "Hotkeys",
            "ShowStatus",
            config["Hotkeys"]["ShowStatus"]
        )

    config["Behavior"]["ShowHotkeyNotifications"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "ShowHotkeyNotifications",
                config["Behavior"]["ShowHotkeyNotifications"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["ShowHotkeyNotifications"]
        )

    config["Behavior"]["Logging"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "Logging",
                config["Behavior"]["Logging"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["Logging"]
        )

    config["Behavior"]["WatchExternalEffectChanges"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "WatchExternalEffectChanges",
                config["Behavior"]["WatchExternalEffectChanges"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["WatchExternalEffectChanges"]
        )

    config["Behavior"]["AutoUpdateInventoryInterval"] :=
        ParseDurationSeconds(
            ReadIniValue(
                "Behavior",
                "AutoUpdateInventoryInterval",
                "0h 2m 30s"
            ),
            config["Behavior"]["AutoUpdateInventoryInterval"],
            86400
        )

    config["Behavior"]["ExcludeFromPickers"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "ExcludeFromPickers",
                config["Behavior"]["ExcludeFromPickers"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["ExcludeFromPickers"]
        )

    config["Behavior"]["ExcludeFromNextHotkeys"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "ExcludeFromNextHotkeys",
                config["Behavior"]["ExcludeFromNextHotkeys"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["ExcludeFromNextHotkeys"]
        )

    config["Behavior"]["ExcludeFromCycling"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "ExcludeFromCycling",
                config["Behavior"]["ExcludeFromCycling"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["ExcludeFromCycling"]
        )

    config["Behavior"]["PresetOnEffectActivation"] :=
        ReadIniValue(
            "Behavior",
            "PresetOnEffectActivation",
            config["Behavior"]["PresetOnEffectActivation"]
        )

    config["Behavior"]["UnassignedEffectLayoutMode"] :=
        ReadIniValue(
            "Behavior",
            "UnassignedEffectLayoutMode",
            config["Behavior"]["UnassignedEffectLayoutMode"]
        )

    config["Behavior"]["DefaultLayout"] :=
        ReadIniValue(
            "Behavior",
            "DefaultLayout",
            config["Behavior"]["DefaultLayout"]
        )

    config["Behavior"]["LaunchOnStartup"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "LaunchOnStartup",
                config["Behavior"]["LaunchOnStartup"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["LaunchOnStartup"]
        )

    config["Behavior"]["ApplyPoliciesOnStartup"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "ApplyPoliciesOnStartup",
                config["Behavior"]["ApplyPoliciesOnStartup"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["ApplyPoliciesOnStartup"]
        )

    config["Behavior"]["RememberLastActiveEffectPreset"] :=
        ParseBoolean(
            ReadIniValue(
                "Behavior",
                "RememberLastActiveEffectPreset",
                config["Behavior"]["RememberLastActiveEffectPreset"]
                    ? "true"
                    : "false"
            ),
            config["Behavior"]["RememberLastActiveEffectPreset"]
        )

    config["Cycling"]["EffectCyclingEnabled"] :=
        ParseBoolean(
            ReadIniValue(
                "Cycling",
                "EffectCyclingEnabled",
                config["Cycling"]["EffectCyclingEnabled"]
                    ? "true"
                    : "false"
            ),
            config["Cycling"]["EffectCyclingEnabled"]
        )

    rawEffectCyclingMode :=
        ReadIniValue(
            "Cycling",
            "EffectCyclingMode",
            config["Cycling"]["EffectCyclingMode"]
        )

    config["Cycling"]["CycleEffectOnceAllPresetsElapsed"] :=
        ParseBoolean(
            ReadIniValue(
                "Cycling",
                "CycleEffectOnceAllPresetsElapsed",
                config["Cycling"]["CycleEffectOnceAllPresetsElapsed"]
                    ? "true"
                    : "false"
            ),
            config["Cycling"]["CycleEffectOnceAllPresetsElapsed"]
        )

    if IsAfterPresetsElapsedMode(
        rawEffectCyclingMode
    ) {
        config["Cycling"]["CycleEffectOnceAllPresetsElapsed"] :=
            true
        rawEffectCyclingMode :=
            "Order"
    }

    config["Cycling"]["EffectCyclingMode"] :=
        NormalizeCyclingMode(
            rawEffectCyclingMode,
            false
        )

    config["Cycling"]["EffectCyclingInterval"] :=
        ParseDurationSeconds(
            ReadIniValue(
                "Cycling",
                "EffectCyclingInterval",
                "0h 15m 0s"
            ),
            config["Cycling"]["EffectCyclingInterval"],
            86400
        )

    config["Cycling"]["PresetCyclingEnabled"] :=
        ParseBoolean(
            ReadIniValue(
                "Cycling",
                "PresetCyclingEnabled",
                config["Cycling"]["PresetCyclingEnabled"]
                    ? "true"
                    : "false"
            ),
            config["Cycling"]["PresetCyclingEnabled"]
        )

    config["Cycling"]["PresetCyclingMode"] :=
        NormalizeCyclingMode(
            ReadIniValue(
                "Cycling",
                "PresetCyclingMode",
                config["Cycling"]["PresetCyclingMode"]
            ),
            false
        )

    config["Cycling"]["PresetCyclingInterval"] :=
        ParseDurationSeconds(
            ReadIniValue(
                "Cycling",
                "PresetCyclingInterval",
                "0h 15m 0s"
            ),
            config["Cycling"]["PresetCyclingInterval"],
            86400
        )

    config["Effects"] :=
        LoadEffectInventory()

    config["EffectOrder"] :=
        ParseIniOrderedSection(
            "EffectOrder"
        )

    config["IgnoredEffects"] :=
        ParseIniEnabledKeySection(
            "IgnoredEffects"
        )

    config["IgnoredPresets"] :=
        ParseIniIgnoredPresetSection(
            "IgnoredPresets"
        )

    config["PresetOrderCache"] := Map()

    config["EffectLayouts"] :=
        ParseIniMapSection(
            "EffectLayouts"
        )

    config["LayoutOrder"] :=
        ParseIniOrderedSection(
            "LayoutOrder"
        )

    config["IgnoredLayouts"] :=
        ParseIniEnabledKeySection(
            "IgnoredLayouts"
        )

    config["FavoriteEffects"] :=
        ParseIniEnabledKeySection(
            "FavoriteEffects"
        )

    config["FavoritePresets"] :=
        ParseIniIgnoredPresetSection(
            "FavoritePresets"
        )

    config["FavoriteLayouts"] :=
        ParseIniEnabledKeySection(
            "FavoriteLayouts"
        )

    return config
}


ReadIniSection(section) {
    global CONFIG_PATH

    if !FileExist(
        CONFIG_PATH
    ) {
        return ""
    }

    try {
        text :=
            FileRead(
                CONFIG_PATH,
                "UTF-8"
            )
    } catch {
        return ""
    }

    result := ""
    currentSection := ""

    Loop Parse, text, "`n", "`r" {
        line :=
            Trim(
                A_LoopField
            )

        if RegExMatch(
            line,
            "^\[(.*)\]$",
            &sectionMatch
        ) {
            currentSection :=
                Trim(
                    sectionMatch[1]
                )

            continue
        }

        if !SameText(
            currentSection,
            section
        ) {
            continue
        }

        if line = "" {
            continue
        }

        firstCharacter :=
            SubStr(
                line,
                1,
                1
            )

        if firstCharacter = ";"
            || firstCharacter = "#" {
            continue
        }

        result .=
            line .
            "`n"
    }

    return RTrim(
        result,
        "`n"
    )
}


ReadIniValueFromSection(
    section,
    key,
    defaultValue := ""
) {
    text :=
        ReadIniSection(
            section
        )

    if text = "" {
        return defaultValue
    }

    Loop Parse, text, "`n", "`r" {
        line :=
            Trim(
                A_LoopField
            )

        separatorPosition :=
            InStr(
                line,
                "="
            )

        if separatorPosition <= 0 {
            continue
        }

        candidateKey :=
            Trim(
                SubStr(
                    line,
                    1,
                    separatorPosition - 1
                )
            )

        if SameText(
            candidateKey,
            key
        ) {
            return Trim(
                SubStr(
                    line,
                    separatorPosition + 1
                )
            )
        }
    }

    return defaultValue
}


ReadIniValue(
    section,
    key,
    defaultValue := ""
) {
    global CONFIG_PATH

    try {
        return IniRead(
            CONFIG_PATH,
            section,
            key,
            defaultValue
        )
    } catch {
        return ReadIniValueFromSection(
            section,
            key,
            defaultValue
        )
    }
}


ResolveConfiguredCompanionPaths(config) {
    global INVENTORY_PATH
    global UPDATER_PATH

    INVENTORY_PATH :=
        ResolveCompanionPath(
            config["Integration"]["InventoryFile"],
            "data\inventory.ini"
        )

    UPDATER_PATH :=
        ResolveCompanionPath(
            config["Integration"]["UpdaterScript"],
            "scripts\inventory-creator-updater.ps1"
        )
}


ResolveCompanionPath(
    configuredPath,
    defaultFileName
) {
    value :=
        Trim(
            configuredPath . ""
        )

    if value = "" {
        value :=
            defaultFileName
    }

    if IsAbsolutePath(
        value
    ) {
        return value
    }

    return A_ScriptDir "\" value
}


IsAbsolutePath(pathValue) {
    value :=
        Trim(
            pathValue . ""
        )

    return RegExMatch(
        value,
        "i)^(?:[A-Z]:\\|\\\\)"
    )
}


ParseIniFile(filePath) {
    sections := Map()

    if !FileExist(
        filePath
    ) {
        return sections
    }

    try {
        text :=
            FileRead(
                filePath,
                "UTF-8"
            )
    } catch {
        return sections
    }

    currentSection := ""

    Loop Parse, text, "`n", "`r" {
        line :=
            Trim(
                A_LoopField
            )

        if line = "" {
            continue
        }

        firstCharacter :=
            SubStr(
                line,
                1,
                1
            )

        if firstCharacter = ";"
            || firstCharacter = "#" {
            continue
        }

        if RegExMatch(
            line,
            "^\[(.*)\]$",
            &sectionMatch
        ) {
            currentSection :=
                Trim(
                    sectionMatch[1]
                )

            if currentSection != ""
                && !sections.Has(
                    currentSection
                ) {
                sections[currentSection] :=
                    Map()
            }

            continue
        }

        if currentSection = "" {
            continue
        }

        separatorPosition :=
            InStr(
                line,
                "="
            )

        if separatorPosition <= 0 {
            continue
        }

        key :=
            Trim(
                SubStr(
                    line,
                    1,
                    separatorPosition - 1
                )
            )

        value :=
            Trim(
                SubStr(
                    line,
                    separatorPosition + 1
                )
            )

        if key != "" {
            sections[currentSection][key] :=
                value
        }
    }

    return sections
}


LoadEffectInventory() {
    global INVENTORY_PATH

    result := Map()

    sections :=
        ParseIniFile(
            INVENTORY_PATH
        )

    if !sections.Has(
        "Effects"
    ) {
        return result
    }

    effects :=
        sections["Effects"]

    statuses :=
        sections.Has(
            "EffectInventoryStatus"
        )
            ? sections["EffectInventoryStatus"]
            : Map()

    for effectId, effectName in effects {
        status :=
            statuses.Has(
                effectId
            )
                ? NormalizeText(
                    statuses[effectId]
                )
                : "present"

        ; Present-Unusable entries do not have a safe effect name for the
        ; signalrgb://effect/apply URI, so they remain inventoried but are
        ; excluded from pickers, go-to-next hotkeys, and cycling until the updater resolves them.
        if status != "present" {
            continue
        }

        if effectName = ""
            || InStr(
                NormalizeText(effectName),
                "[unusable effect "
            ) = 1
            || InStr(
                NormalizeText(effectName),
                "[unresolved effect "
            ) = 1 {
            continue
        }

        result[effectId] :=
            effectName
    }

    return result
}


ParseIniMapSection(section) {
    result := Map()
    text := ReadIniSection(section)

    if text = "" {
        return result
    }

    Loop Parse, text, "`n", "`r" {
        line := Trim(
            A_LoopField
        )

        if line = "" {
            continue
        }

        separatorPosition :=
            InStr(
                line,
                "="
            )

        if separatorPosition <= 0 {
            continue
        }

        key :=
            Trim(
                SubStr(
                    line,
                    1,
                    separatorPosition - 1
                )
            )

        value :=
            Trim(
                SubStr(
                    line,
                    separatorPosition + 1
                )
            )

        if key != "" {
            result[key] := value
        }
    }

    return result
}


ParseIniOrderedSection(section) {
    result := []
    text := ReadIniSection(section)

    if text = "" {
        return result
    }

    Loop Parse, text, "`n", "`r" {
        line := Trim(
            A_LoopField
        )

        if line = "" {
            continue
        }

        separatorPosition :=
            InStr(
                line,
                "="
            )

        if separatorPosition <= 0 {
            continue
        }

        value :=
            Trim(
                SubStr(
                    line,
                    separatorPosition + 1
                )
            )

        if value != "" {
            result.Push(
                value
            )
        }
    }

    return result
}


ParseIniEnabledKeySection(section) {
    result := Map()
    text := ReadIniSection(section)

    if text = "" {
        return result
    }

    Loop Parse, text, "`n", "`r" {
        line := Trim(
            A_LoopField
        )

        if line = "" {
            continue
        }

        separatorPosition :=
            InStr(
                line,
                "="
            )

        if separatorPosition <= 0 {
            key := line
            value := "true"
        } else {
            key :=
                Trim(
                    SubStr(
                        line,
                        1,
                        separatorPosition - 1
                    )
                )

            value :=
                Trim(
                    SubStr(
                        line,
                        separatorPosition + 1
                    )
                )
        }

        if key = "" {
            continue
        }

        if ParseBoolean(
            value,
            true
        ) {
            result[NormalizeText(key)] := true
        }
    }

    return result
}


ParseIniIgnoredPresetSection(section) {
    result := Map()
    text := ReadIniSection(section)

    if text = "" {
        return result
    }

    Loop Parse, text, "`n", "`r" {
        line := Trim(
            A_LoopField
        )

        if line = "" {
            continue
        }

        separatorPosition :=
            InStr(
                line,
                "="
            )

        if separatorPosition > 0 {
            line :=
                Trim(
                    SubStr(
                        line,
                        1,
                        separatorPosition - 1
                    )
                )
        }

        pipePosition :=
            InStr(
                line,
                "|"
            )

        if pipePosition <= 0 {
            continue
        }

        effectId :=
            Trim(
                SubStr(
                    line,
                    1,
                    pipePosition - 1
                )
            )

        presetName :=
            Trim(
                SubStr(
                    line,
                    pipePosition + 1
                )
            )

        AddIgnoredPresetRule(
            result,
            effectId,
            presetName
        )
    }

    return result
}


AddIgnoredPresetRule(
    ignoredPresets,
    effectId,
    presetName
) {
    normalizedEffectId :=
        NormalizeText(
            effectId
        )

    normalizedPresetName :=
        NormalizeText(
            presetName
        )

    if normalizedEffectId = ""
        || normalizedPresetName = "" {
        return
    }

    if !ignoredPresets.Has(
        normalizedEffectId
    ) {
        ignoredPresets[normalizedEffectId] := Map()
    }

    ignoredPresets[normalizedEffectId][normalizedPresetName] := true
}


ParseBoolean(
    value,
    defaultValue := false
) {
    normalized :=
        NormalizeText(
            value
        )

    if normalized = "" {
        return defaultValue
    }

    if normalized = "true"
        || normalized = "yes"
        || normalized = "on"
        || normalized = "1" {
        return true
    }

    if normalized = "false"
        || normalized = "no"
        || normalized = "off"
        || normalized = "0" {
        return false
    }

    return defaultValue
}


ParsePositiveInteger(
    value,
    defaultValue := 1,
    minimumValue := 1,
    maximumValue := 2147483647
) {
    text :=
        Trim(
            value . ""
        )

    if !RegExMatch(
        text,
        "^\d+$"
    ) {
        return defaultValue
    }

    try {
        result :=
            Integer(
                text
            )
    } catch {
        return defaultValue
    }

    if result < minimumValue {
        return minimumValue
    }

    if result > maximumValue {
        return maximumValue
    }

    return result
}


ParseDurationSeconds(
    value,
    defaultValue := 30,
    maximumValue := 86400
) {
    text :=
        NormalizeText(
            value
        )

    if text = "" {
        return defaultValue
    }

    if RegExMatch(
        text,
        "^\d+$"
    ) {
        return ParsePositiveInteger(
            text,
            defaultValue,
            0,
            maximumValue
        )
    }

    if !RegExMatch(
        text,
        "^(?:(\d+)h)?\s*(?:(\d+)m)?\s*(?:(\d+)s)?$",
        &match
    ) {
        return defaultValue
    }

    if match[1] = ""
        && match[2] = ""
        && match[3] = "" {
        return defaultValue
    }

    hours :=
        match[1] = ""
            ? 0
            : Integer(match[1])

    minutes :=
        match[2] = ""
            ? 0
            : Integer(match[2])

    seconds :=
        match[3] = ""
            ? 0
            : Integer(match[3])

    totalSeconds :=
        (hours * 3600) +
        (minutes * 60) +
        seconds

    if totalSeconds > maximumValue {
        return maximumValue
    }

    return totalSeconds
}


NormalizeCyclingMode(
    value,
    allowAfterPresets := false
) {
    normalized :=
        NormalizeText(
            value
        )

    if normalized = "random" {
        return "Random"
    }

    if allowAfterPresets
        && IsAfterPresetsElapsedMode(
            value
        ) {
        return "AfterPresetsElapsed"
    }

    return "Order"
}


IsAfterPresetsElapsedMode(value) {
    normalized :=
        NormalizeText(
            value
        )

    return normalized = "afterpresetselapsed"
        || normalized = "afterpresets"
        || normalized = "afterpreset"
}


NormalizeText(value) {
    return StrLower(
        Trim(
            value . ""
        )
    )
}


SameText(
    first,
    second
) {
    return NormalizeText(first)
        = NormalizeText(second)
}


; =====================================================================
; AUTOMATIC CONFIGURATION AND INVENTORY MANAGEMENT
; =====================================================================

BootstrapConfiguration() {
    global CONFIG_PATH

    if FileExist(
        CONFIG_PATH
    ) {
        return
    }

    updaterPath :=
        FindInventoryUpdaterPath()

    if updaterPath = "" {
        return
    }

    RunInventoryUpdaterByPath(
        updaterPath
    )
}


EnsureInventoryCurrent(
    showUpdateNotification := false
) {
    global gConfig
    global gInventoryCheckBusy
    global INVENTORY_PATH

    if gInventoryCheckBusy {
        return false
    }

    shouldUpdate :=
        !FileExist(
            INVENTORY_PATH
        )

    if !shouldUpdate
        && gConfig["Integration"]["AutoUpdateInventory"] {
        shouldUpdate :=
            InventoryNeedsUpdate()
    }

    if !shouldUpdate {
        return false
    }

    gInventoryCheckBusy := true

    try {
        if !RunInventoryUpdater(
            "The automatic SignalRGB inventory update failed."
        ) {
            return false
        }

        gConfig["Effects"] :=
            LoadEffectInventory()

        gConfig["PresetOrderCache"] :=
            Map()

        WriteLog(
            "SignalRGB inventory updated automatically."
        )

        return true
    } catch as err {
        WriteLog(
            "Automatic inventory update error: " .
            FormatErrorDetails(err)
        )

        return false
    } finally {
        gInventoryCheckBusy := false
    }
}


CheckInventoryForChanges() {
    global gBusy
    global gInventoryCheckBusy
    global gConfig

    if gBusy
        || gInventoryCheckBusy {
        return
    }

    if !gConfig["Integration"]["AutoUpdateInventory"] {
        return
    }

    if !ProcessExist(
        "SignalRgb.exe"
    ) {
        return
    }

    EnsureInventoryCurrent(
        false
    )
}


InventoryNeedsUpdate() {
    global INVENTORY_PATH
    global gInventoryLiveDataUnavailableLogged

    if !FileExist(
        INVENTORY_PATH
    ) {
        return true
    }

    sections :=
        ParseIniFile(
            INVENTORY_PATH
        )

    if sections.Count = 0 {
        return true
    }

    liveEffectIds :=
        GetLiveEffectIdSet()

    livePresetIdentities :=
        GetLivePresetIdentitySet()

    liveLayoutNames :=
        GetLiveLayoutNameSet()

    if liveEffectIds.Count = 0
        && livePresetIdentities.Count = 0
        && liveLayoutNames.Count = 0 {
        if !gInventoryLiveDataUnavailableLogged {
            WriteLog(
                "Inventory freshness check skipped because live SignalRGB inventory data was unavailable."
            )

            gInventoryLiveDataUnavailableLogged := true
        }

        return false
    }

    gInventoryLiveDataUnavailableLogged := false

    inventoryEffectIds :=
        GetInventoryPresentEffectIdSet(
            sections
        )

    if liveEffectIds.Count > 0
        && !MapSetsEqual(
            liveEffectIds,
            inventoryEffectIds
        ) {
        return true
    }

    inventoryPresetIdentities :=
        GetInventoryPresentPresetIdentitySet(
            sections
        )

    if livePresetIdentities.Count > 0
        && !MapSetsEqual(
            livePresetIdentities,
            inventoryPresetIdentities
        ) {
        return true
    }

    inventoryLayoutNames :=
        GetInventoryPresentLayoutNameSet(
            sections
        )

    if liveLayoutNames.Count > 0
        && !MapSetsEqual(
            liveLayoutNames,
            inventoryLayoutNames
        ) {
        return true
    }

    ; An unresolved inventory effect becomes resolvable as soon as that
    ; effect is selected because SignalRGB exposes its current name.
    selectedEffect :=
        GetSelectedEffect()

    if selectedEffect["Id"] != ""
        && selectedEffect["Name"] != ""
        && sections.Has(
            "Effects"
        )
        && sections["Effects"].Has(
            selectedEffect["Id"]
        ) {
        status :=
            "present"

        if sections.Has(
            "EffectInventoryStatus"
        )
            && sections["EffectInventoryStatus"].Has(
                selectedEffect["Id"]
            ) {
            status :=
                NormalizeText(
                    sections["EffectInventoryStatus"][
                        selectedEffect["Id"]
                    ]
                )
        }

        if status = "present-unresolved"
            || status = "present-unusable" {
            return true
        }

        inventoryName :=
            sections["Effects"][
                selectedEffect["Id"]
            ]

        if status = "present"
            && !SameText(
                inventoryName,
                selectedEffect["Name"]
            ) {
            return true
        }
    }

    return false
}


GetLiveEffectIdSet() {
    global EFFECTS_KEY
    global STATES_KEY

    result := Map()

    try {
        Loop Reg, EFFECTS_KEY, "K" {
            effectId :=
                A_LoopRegName

            if effectId = ""
                || SameText(
                    effectId,
                    "selected"
                ) {
                continue
            }

            result[NormalizeText(effectId)] :=
                true
        }
    }

    try {
        Loop Reg, STATES_KEY, "K" {
            effectId :=
                A_LoopRegName

            if effectId = "" {
                continue
            }

            result[NormalizeText(effectId)] :=
                true
        }
    }

    return result
}


GetInventoryPresentEffectIdSet(
    sections
) {
    result := Map()

    if !sections.Has(
        "Effects"
    ) {
        return result
    }

    statuses :=
        sections.Has(
            "EffectInventoryStatus"
        )
            ? sections["EffectInventoryStatus"]
            : Map()

    for effectId, _ in sections["Effects"] {
        status :=
            statuses.Has(
                effectId
            )
                ? NormalizeText(
                    statuses[effectId]
                )
                : "present"

        if InStr(
            status,
            "present"
        ) = 1 {
            result[NormalizeText(effectId)] :=
                true
        }
    }

    return result
}


GetLivePresetIdentitySet() {
    global STATES_KEY

    result := Map()

    try {
        Loop Reg, STATES_KEY, "K" {
            effectId :=
                A_LoopRegName

            if effectId = "" {
                continue
            }

            stateKey :=
                STATES_KEY "\" effectId

            try {
                Loop Reg, stateKey, "V" {
                    presetName :=
                        A_LoopRegName

                    if presetName = ""
                        || IsTemporaryPresetAlias(
                            presetName
                        ) {
                        continue
                    }

                    result[
                        MakePresetIdentity(
                            effectId,
                            presetName
                        )
                    ] := true
                }
            }
        }
    }

    return result
}


GetInventoryPresentPresetIdentitySet(
    sections
) {
    result := Map()

    for sectionName, presetMap in sections {
        if InStr(
            sectionName,
            "Presets."
        ) != 1 {
            continue
        }

        effectId :=
            SubStr(
                sectionName,
                9
            )

        statusSectionName :=
            "PresetInventoryStatus." .
            effectId

        statuses :=
            sections.Has(
                statusSectionName
            )
                ? sections[statusSectionName]
                : Map()

        for presetKey, presetName in presetMap {
            status :=
                statuses.Has(
                    presetKey
                )
                    ? NormalizeText(
                        statuses[presetKey]
                    )
                    : "present"

            if status != "present" {
                continue
            }

            result[
                MakePresetIdentity(
                    effectId,
                    presetName
                )
            ] := true
        }
    }

    return result
}


MakePresetIdentity(
    effectId,
    presetName
) {
    return NormalizeText(effectId) .
        Chr(30) .
        NormalizeText(presetName)
}


IsTemporaryPresetAlias(
    presetName
) {
    normalized :=
        NormalizeText(
            presetName
        )

    return normalized = "a"
        || normalized = "b"
        || normalized = "c"
        || normalized = "rgb-free-pro-macros"
}


GetLiveLayoutNameSet() {
    result := Map()

    for _, layoutName in GetLiveLayoutNames() {
        result[NormalizeText(layoutName)] :=
            true
    }

    return result
}


GetInventoryPresentLayoutNameSet(
    sections
) {
    result := Map()

    if !sections.Has(
        "Layouts"
    ) {
        return result
    }

    statuses :=
        sections.Has(
            "LayoutInventoryStatus"
        )
            ? sections["LayoutInventoryStatus"]
            : Map()

    for layoutKey, layoutName in sections["Layouts"] {
        status :=
            statuses.Has(
                layoutKey
            )
                ? NormalizeText(
                    statuses[layoutKey]
                )
                : "present"

        if status = "present" {
            result[NormalizeText(layoutName)] :=
                true
        }
    }

    return result
}


MapSetsEqual(
    firstSet,
    secondSet
) {
    if firstSet.Count
        != secondSet.Count {
        return false
    }

    for item, _ in firstSet {
        if !secondSet.Has(
            item
        ) {
            return false
        }
    }

    return true
}


RunInventoryUpdater(
    failureMessage := "The SignalRGB inventory update failed."
) {
    global gUpdaterFailureNotified

    updaterPath :=
        FindInventoryUpdaterPath()

    if updaterPath = "" {
        if !gUpdaterFailureNotified {
            Notify(
                "scripts\inventory-creator-updater.ps1 was not found."
            )

            gUpdaterFailureNotified :=
                true
        }

        WriteLog(
            "Inventory updater script was not found."
        )

        return false
    }

    succeeded :=
        RunInventoryUpdaterByPath(
            updaterPath
        )

    if succeeded {
        gUpdaterFailureNotified :=
            false
    } else if !gUpdaterFailureNotified {
        Notify(
            failureMessage
        )

        gUpdaterFailureNotified :=
            true
    }

    return succeeded
}


FindInventoryUpdaterPath() {
    global gConfig
    global UPDATER_PATH

    candidates := []

    if IsObject(
        gConfig
    )
        && gConfig.Has(
            "Integration"
        ) {
        configuredUpdater :=
            gConfig["Integration"]["UpdaterScript"]

        if Trim(
            configuredUpdater . ""
        ) != "" {
            candidates.Push(
                ResolveCompanionPath(
                    configuredUpdater,
                    "scripts\inventory-creator-updater.ps1"
                )
            )
        }
    }

    candidates.Push(
        UPDATER_PATH
    )

    candidates.Push(
        A_ScriptDir "\scripts\inventory-creator-updater.ps1"
    )

    checked := Map()

    for _, candidate in candidates {
        normalized :=
            NormalizeText(
                candidate
            )

        if normalized = ""
            || checked.Has(
                normalized
            ) {
            continue
        }

        checked[normalized] :=
            true

        if FileExist(
            candidate
        ) {
            return candidate
        }
    }

    return ""
}


RunInventoryUpdaterByPath(
    updaterPath
) {
    global CONFIG_PATH
    global INVENTORY_PATH

    if updaterPath = ""
        || !FileExist(
            updaterPath
        ) {
        return false
    }

    quote :=
        Chr(34)

    powershellPath :=
        A_WinDir .
        "\System32\WindowsPowerShell\v1.0\powershell.exe"

    commandLine :=
        quote .
        powershellPath .
        quote .
        " -NoProfile" .
        " -ExecutionPolicy Bypass" .
        " -File " .
        quote .
        updaterPath .
        quote .
        " -OutputFolder " .
        quote .
        A_ScriptDir .
        quote .
        " -NonInteractive" .
        " -Quiet"

    try {
        exitCode := RunWait(
            commandLine,
            A_ScriptDir,
            "Hide"
        )
    } catch as err {
        WriteLog(
            "Inventory updater launch error: " .
            FormatErrorDetails(err)
        )

        return false
    }

    if exitCode != 0 {
        WriteLog(
            "Inventory updater exited with code " .
            exitCode .
            "."
        )

        return false
    }

    return FileExist(
        CONFIG_PATH
    ) && FileExist(
        INVENTORY_PATH
    )
}


; =====================================================================
; CONFIG RELOADING
; =====================================================================

ReloadConfiguration(*) {
    global gConfig

    UnregisterConfiguredHotkeys()

    gConfig := LoadConfig()

    EnsureInventoryCurrent(
        false
    )

    gConfig := LoadConfig()

    RegisterConfiguredHotkeys()
    ConfigureInventoryUpdateTimer()
    ConfigureAutomaticCyclingTimers()

    Notify(
        "SignalRGB configuration reloaded."
    )

    WriteLog(
        "Configuration reloaded."
    )
}


UpdateInventoryNow(*) {
    global gConfig

    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        if !RunInventoryUpdater(
            "The SignalRGB inventory update failed."
        ) {
            return
        }

        gConfig :=
            LoadConfig()

        ConfigureInventoryUpdateTimer()
        ConfigureAutomaticCyclingTimers()

        Notify(
            "SignalRGB inventory updated successfully."
        )

        WriteLog(
            "SignalRGB inventory updated manually."
        )
    } catch as err {
        Notify(
            "Inventory update failed.`n" .
            err.Message
        )

        WriteLog(
            "Manual inventory update error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


ConfigureInventoryUpdateTimer() {
    global gConfig

    SetTimer(
        CheckInventoryForChanges,
        0
    )

    if !gConfig["Integration"]["AutoUpdateInventory"] {
        return
    }

    intervalMilliseconds :=
        gConfig["Behavior"]["AutoUpdateInventoryInterval"] *
        1000

    if intervalMilliseconds <= 0 {
        return
    }

    SetTimer(
        CheckInventoryForChanges,
        intervalMilliseconds
    )
}


; =====================================================================
; AUTOMATIC CYCLING
; =====================================================================

ConfigureAutomaticCyclingTimers() {
    global gConfig
    global gCyclingRandomEffects
    global gCyclingRandomPresets
    global gLastEffectCycleTick
    global gLastPresetCycleTick

    SetTimer(
        AutomaticCyclingTimer,
        0
    )

    SetTimer(
        AutomaticEffectCyclingTimer,
        0
    )

    SetTimer(
        AutomaticPresetCyclingTimer,
        0
    )

    gCyclingRandomEffects := []
    gCyclingRandomPresets := Map()
    gLastEffectCycleTick := A_TickCount
    gLastPresetCycleTick := A_TickCount

    if !gConfig["Cycling"]["EffectCyclingEnabled"]
        && !gConfig["Cycling"]["PresetCyclingEnabled"] {
        return
    }

    SetTimer(
        AutomaticCyclingTimer,
        1000
    )
}


IsCycleEffectOnceAllPresetsElapsed() {
    global gConfig

    return gConfig["Cycling"]["EffectCyclingEnabled"]
        && gConfig["Cycling"]["PresetCyclingEnabled"]
        && gConfig["Cycling"]["CycleEffectOnceAllPresetsElapsed"]
}


GetConfiguredEffectCyclingMode() {
    global gConfig

    mode :=
        gConfig["Cycling"]["EffectCyclingMode"]

    if mode = "AfterPresetsElapsed" {
        return "Order"
    }

    return mode
}


AutomaticCyclingTimer() {
    global gConfig
    global gLastEffectCycleTick
    global gLastPresetCycleTick

    if !BeginOperation() {
        return
    }

    try {
        if !ProcessExist(
            "SignalRgb.exe"
        ) {
            return
        }

        effectEnabled :=
            gConfig["Cycling"]["EffectCyclingEnabled"]

        presetEnabled :=
            gConfig["Cycling"]["PresetCyclingEnabled"]

        afterPresets :=
            IsCycleEffectOnceAllPresetsElapsed()

        effectMode :=
            GetConfiguredEffectCyclingMode()

        presetMode :=
            gConfig["Cycling"]["PresetCyclingMode"]

        if afterPresets {
            presetIntervalMilliseconds :=
                gConfig["Cycling"]["PresetCyclingInterval"] *
                1000

            if presetIntervalMilliseconds <= 0 {
                return
            }

            if (
                A_TickCount -
                gLastPresetCycleTick
            ) < presetIntervalMilliseconds {
                return
            }

            result :=
                ApplyNextPresetForAutomaticCycling(
                    presetMode,
                    true
                )

            gLastPresetCycleTick :=
                A_TickCount

            if result["CompletedSet"] {
                ApplyNextEffectForAutomaticCycling(
                    effectMode
                )

                gLastEffectCycleTick :=
                    A_TickCount

                gLastPresetCycleTick :=
                    A_TickCount
            }

            return
        }

        effectIntervalMilliseconds :=
            gConfig["Cycling"]["EffectCyclingInterval"] *
            1000

        presetIntervalMilliseconds :=
            gConfig["Cycling"]["PresetCyclingInterval"] *
            1000

        effectDue :=
            effectEnabled
            && effectIntervalMilliseconds > 0
            && (
                A_TickCount -
                gLastEffectCycleTick
            ) >= effectIntervalMilliseconds

        presetDue :=
            presetEnabled
            && presetIntervalMilliseconds > 0
            && (
                A_TickCount -
                gLastPresetCycleTick
            ) >= presetIntervalMilliseconds

        if effectDue {
            ApplyNextEffectForAutomaticCycling(
                effectMode
            )

            gLastEffectCycleTick :=
                A_TickCount

            gLastPresetCycleTick :=
                A_TickCount

            return
        }

        if presetDue {
            ApplyNextPresetForAutomaticCycling(
                presetMode,
                false
            )

            gLastPresetCycleTick :=
                A_TickCount
        }
    } catch as err {
        WriteLog(
            "Automatic cycling error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


AutomaticEffectCyclingTimer() {
    AutomaticCyclingTimer()
}


AutomaticPresetCyclingTimer() {
    AutomaticCyclingTimer()
}


ApplyNextEffectForAutomaticCycling(
    mode
) {
    global gConfig
    global gLastSeenEffectId

    effects :=
        GetEffectNavigationList(
            "Cycling"
        )

    if effects.Length < 2 {
        return false
    }

    currentEffect :=
        GetSelectedEffect()

    targetEffect := false

    if mode = "Random" {
        targetEffect :=
            GetRandomEffectWithoutRepeat(
                effects,
                currentEffect["Id"],
                currentEffect["Name"]
            )
    } else {
        targetEffect :=
            GetNextEffectRecord(
                effects,
                currentEffect["Id"],
                currentEffect["Name"]
            )
    }

    if !targetEffect {
        return false
    }

    if ApplyEffect(
        targetEffect["Id"],
        targetEffect["Name"]
    ) {
        gLastSeenEffectId :=
            targetEffect["Id"]

        Sleep(300)

        ApplyEffectActivationPolicy(
            targetEffect["Id"],
            targetEffect["Name"],
            !gConfig["Cycling"]["PresetCyclingEnabled"]
        )

        if gConfig["Cycling"]["PresetCyclingEnabled"] {
            ApplyNextPresetForAutomaticCycling(
                gConfig["Cycling"]["PresetCyclingMode"]
            )
        }

        WriteLog(
            "Automatic effect cycling applied: " .
            targetEffect["Name"] .
            " | " .
            targetEffect["Id"]
        )

        return true
    }

    return false
}


ApplyNextPresetForAutomaticCycling(
    mode,
    stopAtEnd := false
) {
    effect :=
        GetSelectedEffect()

    result :=
        Map(
            "Applied",
            false,
            "CompletedSet",
            false
        )

    if effect["Id"] = ""
        || effect["Name"] = "" {
        return result
    }

    presets :=
        GetAvailablePresetNames(
            effect["Id"],
            "Cycling"
        )

    if presets.Length = 0 {
        result["CompletedSet"] := true
        return result
    }

    if presets.Length = 1 {
        result["CompletedSet"] := true
        return result
    }

    currentPreset :=
        GetCurrentPreset(
            effect["Id"]
        )

    if mode = "Random" {
        targetPreset :=
            GetRandomPresetWithoutRepeat(
                effect["Id"],
                presets,
                currentPreset,
                stopAtEnd,
                &completedSet
            )

        result["CompletedSet"] := completedSet
    } else {
        currentIndex :=
            FindArrayItemIndex(
                presets,
                currentPreset
            )

        if currentIndex = presets.Length {
            result["CompletedSet"] := true
            if stopAtEnd {
                return result
            }

            targetPreset := presets[1]
        } else {
            targetPreset :=
                currentIndex = 0
                    ? presets[1]
                    : presets[currentIndex + 1]
        }
    }

    if targetPreset = "" {
        return result
    }

    if ApplyPresetByAlias(
        effect["Id"],
        effect["Name"],
        targetPreset
    ) {
        result["Applied"] := true

        WriteLog(
            "Automatic preset cycling applied: " .
            effect["Name"] .
            " | " .
            targetPreset
        )
    }

    return result
}


ApplyStartupConfiguredSelection() {
    if !ProcessExist(
        "SignalRgb.exe"
    ) {
        return false
    }

    effects :=
        GetEffectNavigationList()

    if effects.Length = 0 {
        return false
    }

    firstEffect :=
        effects[1]

    if !ApplyEffect(
        firstEffect["Id"],
        firstEffect["Name"]
    ) {
        return false
    }

    Sleep(300)

    ApplyEffectActivationPolicy(
        firstEffect["Id"],
        firstEffect["Name"]
    )

    presets :=
        GetAvailablePresetNames(
            firstEffect["Id"]
        )

    if presets.Length > 0 {
        ApplyPresetByAlias(
            firstEffect["Id"],
            firstEffect["Name"],
            presets[1]
        )
    }

    return true
}


GetRandomEffectWithoutRepeat(
    effects,
    currentId,
    currentName
) {
    global gCyclingRandomEffects

    if effects.Length = 0 {
        return false
    }

    if effects.Length = 1 {
        return effects[1]
    }

    currentKey :=
        GetEffectRandomKey(
            currentId,
            currentName
        )

    gCyclingRandomEffects :=
        FilterEffectRandomBag(
            gCyclingRandomEffects,
            effects
        )

    if gCyclingRandomEffects.Length = 0 {
        for _, effect in effects {
            key :=
                GetEffectRandomKey(
                    effect["Id"],
                    effect["Name"]
                )

            if key != currentKey {
                gCyclingRandomEffects.Push(
                    key
                )
            }
        }
    }

    if gCyclingRandomEffects.Length = 0 {
        return GetNextEffectRecord(
            effects,
            currentId,
            currentName
        )
    }

    randomIndex :=
        Random(
            1,
            gCyclingRandomEffects.Length
        )

    targetKey :=
        gCyclingRandomEffects[randomIndex]

    gCyclingRandomEffects.RemoveAt(
        randomIndex
    )

    for _, effect in effects {
        if GetEffectRandomKey(
            effect["Id"],
            effect["Name"]
        ) = targetKey {
            return effect
        }
    }

    return GetNextEffectRecord(
        effects,
        currentId,
        currentName
    )
}


FilterEffectRandomBag(
    bag,
    effects
) {
    validKeys := Map()

    for _, effect in effects {
        validKeys[
            GetEffectRandomKey(
                effect["Id"],
                effect["Name"]
            )
        ] := true
    }

    filtered := []

    for _, key in bag {
        if validKeys.Has(
            key
        ) {
            filtered.Push(
                key
            )
        }
    }

    return filtered
}


GetEffectRandomKey(
    effectId,
    effectName
) {
    if effectId != "" {
        return NormalizeText(
            effectId
        )
    }

    return NormalizeText(
        effectName
    )
}


GetRandomPresetWithoutRepeat(
    effectId,
    presets,
    currentPreset,
    stopAtEnd,
    &completedSet
) {
    global gCyclingRandomPresets

    completedSet := false

    if presets.Length = 0 {
        completedSet := true
        return ""
    }

    effectKey :=
        NormalizeText(
            effectId
        )

    if !gCyclingRandomPresets.Has(
        effectKey
    ) {
        gCyclingRandomPresets[effectKey] := []
    }

    bag :=
        FilterPresetRandomBag(
            gCyclingRandomPresets[effectKey],
            presets
        )

    if bag.Length = 0
        && FindArrayItemIndex(
            presets,
            currentPreset
        ) > 0 {
        completedSet := true
        if stopAtEnd {
            gCyclingRandomPresets[effectKey] := []
            return ""
        }
    }

    if bag.Length = 0 {
        currentNormalized :=
            NormalizeText(
                currentPreset
            )

        for _, presetName in presets {
            if NormalizeText(presetName)
                != currentNormalized {
                bag.Push(
                    presetName
                )
            }
        }
    }

    if bag.Length = 0 {
        completedSet := true
        gCyclingRandomPresets[effectKey] := []
        return ""
    }

    randomIndex :=
        Random(
            1,
            bag.Length
        )

    targetPreset :=
        bag[randomIndex]

    bag.RemoveAt(
        randomIndex
    )

    gCyclingRandomPresets[effectKey] := bag

    return targetPreset
}


FilterPresetRandomBag(
    bag,
    presets
) {
    validPresets := Map()

    for _, presetName in presets {
        validPresets[
            NormalizeText(
                presetName
            )
        ] := true
    }

    filtered := []

    for _, presetName in bag {
        if validPresets.Has(
            NormalizeText(
                presetName
            )
        ) {
            filtered.Push(
                presetName
            )
        }
    }

    return filtered
}


; =====================================================================
; HOTKEY REGISTRATION
; =====================================================================

RegisterConfiguredHotkeys() {
    global gConfig
    global gRegisteredHotkeys

    gRegisteredHotkeys := []

    seenHotkeys := Map()

    entries := [
        [
            "OpenPickerMenu",
            gConfig["Hotkeys"]["OpenPickerMenu"],
            OpenPickerMenuHotkey
        ],
        [
            "PickPreset",
            gConfig["Hotkeys"]["PickPreset"],
            PickPresetHotkey
        ],
        [
            "PickEffect",
            gConfig["Hotkeys"]["PickEffect"],
            PickEffectHotkey
        ],
        [
            "PickLayout",
            gConfig["Hotkeys"]["PickLayout"],
            PickLayoutHotkey
        ],
        [
            "GoToNextPreset",
            gConfig["Hotkeys"]["GoToNextPreset"],
            GoToNextPresetHotkey
        ],
        [
            "GoToNextEffect",
            gConfig["Hotkeys"]["GoToNextEffect"],
            GoToNextEffectHotkey
        ],
        [
            "GoToNextLayout",
            gConfig["Hotkeys"]["GoToNextLayout"],
            GoToNextLayoutHotkey
        ],
        [
            "ShowStatus",
            gConfig["Hotkeys"]["ShowStatus"],
            ShowStatusHotkey
        ]
    ]

    for _, entry in entries {
        actionName := entry[1]
        hotkeyText := Trim(
            entry[2]
        )

        callback := entry[3]

        if hotkeyText = "" {
            continue
        }

        normalizedHotkey :=
            NormalizeText(
                hotkeyText
            )

        if seenHotkeys.Has(
            normalizedHotkey
        ) {
            WriteLog(
                "Duplicate hotkey skipped: " .
                actionName .
                " = " .
                hotkeyText
            )

            continue
        }

        try {
            Hotkey(
                hotkeyText,
                callback,
                "On"
            )

            gRegisteredHotkeys.Push(
                hotkeyText
            )

            seenHotkeys[normalizedHotkey] :=
                true
        } catch as err {
            Notify(
                "Invalid hotkey for " .
                actionName .
                ": " .
                hotkeyText
            )

            WriteLog(
                "Hotkey error: " .
                actionName .
                " | " .
                FormatErrorDetails(err)
            )
        }
    }
}


UnregisterConfiguredHotkeys() {
    global gRegisteredHotkeys

    for _, hotkeyText in gRegisteredHotkeys {
        try {
            Hotkey(
                hotkeyText,
                "Off"
            )
        }
    }

    gRegisteredHotkeys := []
}


; =====================================================================
; TRAY MENU
; =====================================================================

BuildTrayMenu() {
    A_TrayMenu.Delete()

    A_TrayMenu.Add(
        "Next preset",
        GoToNextPresetHotkey
    )

    A_TrayMenu.Add(
        "Next effect",
        GoToNextEffectHotkey
    )

    A_TrayMenu.Add(
        "Next layout",
        GoToNextLayoutHotkey
    )

    A_TrayMenu.Add(
        "Show status",
        ShowStatusHotkey
    )

    A_TrayMenu.Add()

    A_TrayMenu.Add(
        "Pick preset...",
        PickPresetHotkey
    )

    A_TrayMenu.Add(
        "Pick effect...",
        PickEffectHotkey
    )

    A_TrayMenu.Add(
        "Pick layout...",
        PickLayoutHotkey
    )

    A_TrayMenu.Add(
        "Open picker menu...",
        OpenPickerMenuHotkey
    )

    A_TrayMenu.Add()

    A_TrayMenu.Add(
        "Open Config Editor",
        OpenConfiguration
    )

    A_TrayMenu.Add(
        "Open SignalRGB",
        OpenSignalRgb
    )

    A_TrayMenu.Add(
        "Open tool folder",
        OpenScriptFolder
    )

    A_TrayMenu.Add()
    A_TrayMenu.AddStandard()
}


OpenConfiguration(*) {
    global CONFIG_EDITOR_PATH

    if !FileExist(CONFIG_EDITOR_PATH) {
        Notify(
            "scripts\config-editor.ps1 was not found."
        )

        return
    }

    quote := Chr(34)

    commandLine :=
        "powershell.exe " .
        "-NoProfile " .
        "-STA " .
        "-ExecutionPolicy Bypass " .
        "-WindowStyle Hidden " .
        "-File " .
        quote . CONFIG_EDITOR_PATH . quote

    try {
        exitCode := RunWait(
            commandLine,
            A_ScriptDir
        )

        ; The editor returns 20 after at least one successful save.
        if exitCode = 20 {
            ReloadConfiguration()

            return
        }

        if exitCode != 0 {
            Notify(
                "The config editor closed with exit code " .
                exitCode .
                "."
            )
        }
    } catch as err {
        Notify(
            "The config editor could not be opened.`n" .
            err.Message
        )

        WriteLog(
            "Configuration GUI error: " .
            FormatErrorDetails(err)
        )
    }
}


OpenScriptFolder(*) {
    Run(
        A_ScriptDir
    )
}


OpenSignalRgb(*) {
    try {
        Run(
            "signalrgb://view/dashboard"
        )
    } catch as err {
        Notify(
            "SignalRGB could not be opened.`n" .
            err.Message
        )

        WriteLog(
            "Open SignalRGB error: " .
            FormatErrorDetails(err)
        )
    }
}


; =====================================================================
; GO-TO-NEXT HOTKEYS
; =====================================================================

GoToNextPresetHotkey(*) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        effect :=
            GetSelectedEffect()

        if effect["Id"] = ""
            || effect["Name"] = "" {
            throw Error(
                "The active SignalRGB effect could not be read."
            )
        }

        presets :=
            GetAvailablePresetNames(
                effect["Id"]
            )

        if presets.Length = 0 {
            Notify(
                "No usable saved presets were found for " .
                effect["Name"] .
                "."
            )

            return
        }

        if presets.Length = 1 {
            Notify(
                effect["Name"] .
                " only has one usable preset."
            )

            return
        }

        currentPreset :=
            GetCurrentPreset(
                effect["Id"]
            )

        targetPreset :=
            GetNextArrayItem(
                presets,
                currentPreset
            )

        if targetPreset = "" {
            throw Error(
                "The next preset could not be determined."
            )
        }

        if ApplyPresetByAlias(
            effect["Id"],
            effect["Name"],
            targetPreset
        ) {
            presetIndex :=
                FindArrayItemIndex(
                    presets,
                    targetPreset
                )

            Notify(
                "Preset: " .
                targetPreset .
                " (" .
                FormatPosition(
                    presetIndex,
                    presets.Length
                ) .
                ")"
            )

            WriteLog(
                "Preset applied: " .
                effect["Name"] .
                " | " .
                targetPreset
            )
        }
    } catch as err {
        Notify(
            "Preset switch failed.`n" .
            err.Message
        )

        WriteLog(
            "Preset switch error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


GoToNextEffectHotkey(*) {
    global gLastSeenEffectId

    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        effects :=
            GetEffectNavigationList()

        if effects.Length = 0 {
            Notify(
                "Go-to-next effects need a resolved effect catalog in data\inventory.ini."
            )

            return
        }

        if effects.Length = 1 {
            Notify(
                "Only one usable resolved effect exists in data\inventory.ini."
            )

            return
        }

        currentEffect :=
            GetSelectedEffect()

        targetEffect :=
            GetNextEffectRecord(
                effects,
                currentEffect["Id"],
                currentEffect["Name"]
            )

        if !targetEffect {
            throw Error(
                "The next effect could not be determined."
            )
        }

        if ApplyEffect(
            targetEffect["Id"],
            targetEffect["Name"]
        ) {
            gLastSeenEffectId :=
                targetEffect["Id"]

            Sleep(300)

            ApplyEffectActivationPolicy(
                targetEffect["Id"],
                targetEffect["Name"]
            )

            effectIndex :=
                FindEffectRecordIndex(
                    effects,
                    targetEffect["Id"],
                    targetEffect["Name"]
                )

            Notify(
                "Effect: " .
                targetEffect["Name"] .
                " (" .
                FormatPosition(
                    effectIndex,
                    effects.Length
                ) .
                ")"
            )

            WriteLog(
                "Effect applied: " .
                targetEffect["Name"] .
                " | " .
                targetEffect["Id"]
            )
        }
    } catch as err {
        Notify(
            "Effect switch failed.`n" .
            err.Message
        )

        WriteLog(
            "Effect switch error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


GoToNextLayoutHotkey(*) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        layouts :=
            GetLayoutNavigationList()

        if layouts.Length = 0 {
            Notify(
                "No saved SignalRGB layouts were found."
            )

            return
        }

        if layouts.Length = 1 {
            Notify(
                "Only one usable SignalRGB layout was found."
            )

            return
        }

        currentLayout :=
            GetCurrentLayout()

        targetLayout :=
            GetNextArrayItem(
                layouts,
                currentLayout
            )

        if targetLayout = "" {
            throw Error(
                "The next layout could not be determined."
            )
        }

        if ApplyLayout(
            targetLayout
        ) {
            layoutIndex :=
                FindArrayItemIndex(
                    layouts,
                    targetLayout
                )

            effect :=
                GetSelectedEffect()

            layoutLabel :=
                GetLayoutDisplayLabel(
                    effect["Id"],
                    effect["Name"],
                    targetLayout
                )

            Notify(
                layoutLabel .
                ": " .
                targetLayout .
                " (" .
                FormatPosition(
                    layoutIndex,
                    layouts.Length
                ) .
                ")"
            )

            WriteLog(
                "Layout applied: " .
                targetLayout
            )
        }
    } catch as err {
        Notify(
            "Layout switch failed.`n" .
            err.Message
        )

        WriteLog(
            "Layout switch error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


; =====================================================================
; PICKER HOTKEYS
; =====================================================================

PickPresetHotkey(*) {
    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        pickerMenu :=
            BuildPresetPickerMenu()

        ShowPickerMenu(
            pickerMenu
        )
    } catch as err {
        Notify(
            "Preset picker failed.`n" .
            err.Message
        )

        WriteLog(
            "Preset picker error: " .
            FormatErrorDetails(err)
        )
    }
}


PickEffectHotkey(*) {
    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        pickerMenu :=
            BuildEffectPickerMenu()

        ShowPickerMenu(
            pickerMenu
        )
    } catch as err {
        Notify(
            "Effect picker failed.`n" .
            err.Message
        )

        WriteLog(
            "Effect picker error: " .
            FormatErrorDetails(err)
        )
    }
}


PickLayoutHotkey(*) {
    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        pickerMenu :=
            BuildLayoutPickerMenu()

        ShowPickerMenu(
            pickerMenu
        )
    } catch as err {
        Notify(
            "Layout picker failed.`n" .
            err.Message
        )

        WriteLog(
            "Layout picker error: " .
            FormatErrorDetails(err)
        )
    }
}


OpenPickerMenuHotkey(*) {
    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        mainMenu :=
            Menu()

        effectMenu :=
            BuildEffectPickerMenu()

        presetMenu :=
            BuildPresetPickerMenu()

        layoutMenu :=
            BuildLayoutPickerMenu()

        mainMenu.Add(
            BuildPickerSubmenuLabel(
                "&Effects",
                GetEffectPickerCount()
            ),
            effectMenu
        )

        mainMenu.Add(
            BuildPickerSubmenuLabel(
                "&Presets",
                GetPresetPickerCount()
            ),
            presetMenu
        )

        mainMenu.Add(
            BuildPickerSubmenuLabel(
                "&Layouts",
                GetLayoutPickerCount()
            ),
            layoutMenu
        )

        AddPickerSpecialMenuItems(
            mainMenu
        )

        ShowPickerMenu(
            mainMenu
        )
    } catch as err {
        Notify(
            "Picker menu failed.`n" .
            err.Message
        )

        WriteLog(
            "Picker menu error: " .
            FormatErrorDetails(err)
        )
    }
}


ShowPickerMenu(menuObject) {
    HideNotification()

    WaitForPickerModifiersReleased()

    ApplyWindowsAppTheme()

    menuObject.Show()
}


WaitForPickerModifiersReleased() {
    KeyWait(
        "Ctrl"
    )

    KeyWait(
        "Alt"
    )

    KeyWait(
        "Shift"
    )

    Sleep(30)
}


; =====================================================================
; PICKER MENU BUILDING
; =====================================================================

BuildPresetPickerMenu() {
    pickerMenu :=
        Menu()

    effect :=
        GetSelectedEffect()

    presets := []

    if effect["Id"] != ""
        && effect["Name"] != "" {
        presets :=
            GetAvailablePresetNames(
                effect["Id"],
                true
            )
    }

    AddPickerFavoritesMenu(
        pickerMenu,
        "preset",
        effect["Id"],
        effect["Name"],
        presets
    )

    if effect["Id"] = ""
        || effect["Name"] = "" {
        AddDisabledMenuItem(
            pickerMenu,
            "The active effect could not be read."
        )

        AddPickerSpecialMenuItems(
            pickerMenu
        )

        return pickerMenu
    }

    if presets.Length = 0 {
        AddDisabledMenuItem(
            pickerMenu,
            "No usable saved presets were found."
        )

        AddPickerSpecialMenuItems(
            pickerMenu
        )

        return pickerMenu
    }

    currentPreset :=
        GetCurrentPreset(
            effect["Id"]
        )

    for index, presetName in presets {
        menuLabel :=
            BuildPickerItemLabel(
                presetName
            )

        pickerMenu.Add(
            menuLabel,
            ApplyPresetPickerSelection.Bind(
                effect["Id"],
                effect["Name"],
                presetName,
                index,
                presets.Length
            )
        )

        if SameText(
            presetName,
            currentPreset
        ) {
            pickerMenu.Check(
                menuLabel
            )

            pickerMenu.Default :=
                menuLabel
        }
    }

    AddPickerSpecialMenuItems(
        pickerMenu
    )

    return pickerMenu
}


BuildEffectPickerMenu() {
    pickerMenu :=
        Menu()

    effects :=
        GetEffectNavigationList(
            true
        )

    AddPickerFavoritesMenu(
        pickerMenu,
        "effect",
        "",
        "",
        effects
    )

    if effects.Length = 0 {
        AddDisabledMenuItem(
            pickerMenu,
            "No resolved effects were found in data\inventory.ini."
        )

        AddPickerSpecialMenuItems(
            pickerMenu
        )

        return pickerMenu
    }

    currentEffect :=
        GetSelectedEffect()

    for index, effect in effects {
        menuLabel :=
            BuildPickerItemLabel(
                effect["Name"]
            )

        pickerMenu.Add(
            menuLabel,
            ApplyEffectPickerSelection.Bind(
                effect["Id"],
                effect["Name"],
                index,
                effects.Length
            )
        )

        if EffectMatchesSelection(
            effect,
            currentEffect
        ) {
            pickerMenu.Check(
                menuLabel
            )

            pickerMenu.Default :=
                menuLabel
        }
    }

    AddPickerSpecialMenuItems(
        pickerMenu
    )

    return pickerMenu
}


BuildLayoutPickerMenu() {
    pickerMenu :=
        Menu()

    layouts :=
        GetLayoutNavigationList(
            true
        )

    AddPickerFavoritesMenu(
        pickerMenu,
        "layout",
        "",
        "",
        layouts
    )

    if layouts.Length = 0 {
        AddDisabledMenuItem(
            pickerMenu,
            "No usable saved layouts were found."
        )

        AddPickerSpecialMenuItems(
            pickerMenu
        )

        return pickerMenu
    }

    currentLayout :=
        GetCurrentLayout()

    for index, layoutName in layouts {
        menuLabel :=
            BuildPickerItemLabel(
                layoutName
            )

        pickerMenu.Add(
            menuLabel,
            ApplyLayoutPickerSelection.Bind(
                layoutName,
                index,
                layouts.Length
            )
        )

        if SameText(
            layoutName,
            currentLayout
        ) {
            pickerMenu.Check(
                menuLabel
            )

            pickerMenu.Default :=
                menuLabel
        }
    }

    AddPickerSpecialMenuItems(
        pickerMenu
    )

    return pickerMenu
}


AddPickerFavoritesMenu(
    pickerMenu,
    kind,
    effectId := "",
    effectName := "",
    orderedItems := 0
) {
    pickerMenu.Add(
        BuildPickerSubmenuLabel(
            "Favorites",
            GetFavoritePickerCount(
                kind,
                effectId,
                orderedItems
            )
        ),
        BuildFavoritesSubmenu(
            kind,
            effectId,
            effectName,
            orderedItems
        )
    )

    pickerMenu.Add()
}


BuildFavoritesSubmenu(
    kind,
    effectId := "",
    effectName := "",
    orderedItems := 0
) {
    favoritesMenu :=
        Menu()

    normalizedKind :=
        NormalizeText(
            kind
        )

    if normalizedKind = "effect" {
        AddFavoriteEffectMenuItems(
            favoritesMenu,
            orderedItems
        )
    }
    else if normalizedKind = "preset" {
        AddFavoritePresetMenuItems(
            favoritesMenu,
            effectId,
            effectName,
            orderedItems
        )
    }
    else {
        AddFavoriteLayoutMenuItems(
            favoritesMenu,
            orderedItems
        )
    }

    return favoritesMenu
}


AddFavoriteEffectMenuItems(
    favoritesMenu,
    orderedItems := 0
) {
    favorites :=
        GetFavoriteEffectPickerItems(
            orderedItems
        )

    if favorites.Length = 0 {
        AddDisabledMenuItem(
            favoritesMenu,
            "No favorites"
        )

        return
    }

    currentEffect :=
        GetSelectedEffect()

    for index, effect in favorites {
        menuLabel :=
            BuildPickerItemLabel(
                effect["Name"]
            )

        favoritesMenu.Add(
            menuLabel,
            ApplyEffectPickerSelection.Bind(
                effect["Id"],
                effect["Name"],
                index,
                favorites.Length
            )
        )

        if EffectMatchesSelection(
            effect,
            currentEffect
        ) {
            favoritesMenu.Check(
                menuLabel
            )

            favoritesMenu.Default :=
                menuLabel
        }
    }
}


AddFavoritePresetMenuItems(
    favoritesMenu,
    effectId,
    effectName,
    orderedItems := 0
) {
    favorites :=
        GetFavoritePresetPickerItems(
            effectId,
            orderedItems
        )

    if favorites.Length = 0 {
        AddDisabledMenuItem(
            favoritesMenu,
            "No favorites"
        )

        return
    }

    currentPreset :=
        GetCurrentPreset(
            effectId
        )

    for index, presetName in favorites {
        menuLabel :=
            BuildPickerItemLabel(
                presetName
            )

        favoritesMenu.Add(
            menuLabel,
            ApplyPresetPickerSelection.Bind(
                effectId,
                effectName,
                presetName,
                index,
                favorites.Length
            )
        )

        if SameText(
            presetName,
            currentPreset
        ) {
            favoritesMenu.Check(
                menuLabel
            )

            favoritesMenu.Default :=
                menuLabel
        }
    }
}


AddFavoriteLayoutMenuItems(
    favoritesMenu,
    orderedItems := 0
) {
    favorites :=
        GetFavoriteLayoutPickerItems(
            orderedItems
        )

    if favorites.Length = 0 {
        AddDisabledMenuItem(
            favoritesMenu,
            "No favorites"
        )

        return
    }

    currentLayout :=
        GetCurrentLayout()

    for index, layoutName in favorites {
        menuLabel :=
            BuildPickerItemLabel(
                layoutName
            )

        favoritesMenu.Add(
            menuLabel,
            ApplyLayoutPickerSelection.Bind(
                layoutName,
                index,
                favorites.Length
            )
        )

        if SameText(
            layoutName,
            currentLayout
        ) {
            favoritesMenu.Check(
                menuLabel
            )

            favoritesMenu.Default :=
                menuLabel
        }
    }
}


AddPickerSpecialMenuItems(menuObject) {
    menuObject.Add()

    menuObject.Add(
        "Show Status",
        ShowStatusHotkey
    )

    menuObject.Add(
        "Update Inventory",
        UpdateInventoryNow
    )

    menuObject.Add(
        "Ignore",
        BuildIgnoreMenu()
    )

    menuObject.Add(
        "Open Config Editor",
        OpenConfiguration
    )

    menuObject.Add(
        "Open SignalRGB",
        OpenSignalRgb
    )
}


BuildIgnoreMenu() {
    ignoreMenu :=
        Menu()

    ignoreMenu.Add(
        "Ignore active effect",
        IgnoreActiveEffect
    )

    ignoreMenu.Add(
        "Ignore active preset",
        IgnoreActivePreset
    )

    ignoreMenu.Add(
        "Ignore active layout",
        IgnoreActiveLayout
    )

    try {
        effect :=
            GetSelectedEffect()

        if CountLivePresets(
            effect["Id"]
        ) <= 1 {
            ignoreMenu.Disable(
                "Ignore active preset"
            )
        }
    } catch {
    }

    return ignoreMenu
}


AddConfigEditorMenuItem(menuObject) {
    AddPickerSpecialMenuItems(
        menuObject
    )
}


IgnoreActiveEffect(*) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        effect :=
            GetSelectedEffect()

        if effect["Name"] = "" {
            Notify(
                "The active effect could not be read."
            )

            return
        }

        if IsConfiguredIgnoredEffect(
            effect["Name"]
        ) {
            Notify(
                effect["Name"] .
                " is already ignored."
            )

            return
        }

        AppendBareIniEntry(
            "IgnoredEffects",
            effect["Name"]
        )

        ReloadIgnoredConfiguration()

        Notify(
            "Ignored active effect:`n" .
            effect["Name"]
        )
    } catch as err {
        Notify(
            "Could not ignore the active effect.`n" .
            err.Message
        )

        WriteLog(
            "Ignore active effect error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


IgnoreActivePreset(*) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        effect :=
            GetSelectedEffect()

        if effect["Id"] = ""
            || effect["Name"] = "" {
            Notify(
                "The active effect could not be read."
            )

            return
        }

        if CountLivePresets(
            effect["Id"]
        ) <= 1 {
            Notify(
                effect["Name"] .
                " only has one preset, so it can't be ignored."
            )

            return
        }

        presetName :=
            GetCurrentPreset(
                effect["Id"]
            )

        if presetName = ""
            || IsTemporaryPresetAlias(
                presetName
            ) {
            Notify(
                "The active preset could not be read."
            )

            return
        }

        if IsConfiguredIgnoredPreset(
            effect["Name"],
            presetName
        ) {
            Notify(
                presetName .
                " is already ignored."
            )

            return
        }

        AppendBareIniEntry(
            "IgnoredPresets",
            effect["Name"] .
            "|" .
            presetName
        )

        ReloadIgnoredConfiguration()

        Notify(
            "Ignored active preset:`n" .
            effect["Name"] .
            " | " .
            presetName
        )
    } catch as err {
        Notify(
            "Could not ignore the active preset.`n" .
            err.Message
        )

        WriteLog(
            "Ignore active preset error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


IgnoreActiveLayout(*) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        layoutName :=
            GetCurrentLayout()

        if layoutName = "" {
            Notify(
                "The active layout could not be read."
            )

            return
        }

        if IsConfiguredIgnoredLayout(
            layoutName
        ) {
            Notify(
                layoutName .
                " is already ignored."
            )

            return
        }

        AppendBareIniEntry(
            "IgnoredLayouts",
            layoutName
        )

        ReloadIgnoredConfiguration()

        Notify(
            "Ignored active layout:`n" .
            layoutName
        )
    } catch as err {
        Notify(
            "Could not ignore the active layout.`n" .
            err.Message
        )

        WriteLog(
            "Ignore active layout error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


BuildPickerItemLabel(itemName) {
    cleanName :=
        itemName . ""

    cleanName :=
        StrReplace(
            cleanName,
            "`r",
            " "
        )

    cleanName :=
        StrReplace(
            cleanName,
            "`n",
            " "
        )

    cleanName :=
        StrReplace(
            cleanName,
            "`t",
            " "
        )

    if StrLen(cleanName)
        > 250 {
        cleanName :=
            SubStr(
                cleanName,
                1,
                249
            ) .
            "…"
    }

    return EscapeMenuLabel(
        cleanName
    )
}


BuildPickerSubmenuLabel(
    title,
    total
) {
    return title .
        " (" .
        total .
        ")"
}


EffectMatchesSelection(
    effect,
    currentEffect
) {
    return (
        currentEffect["Id"] != ""
        && effect["Id"] = currentEffect["Id"]
    ) || SameText(
        effect["Name"],
        currentEffect["Name"]
    )
}


GetEffectPickerCount() {
    return GetEffectNavigationList(
        true
    ).Length
}


GetPresetPickerCount() {
    effect :=
        GetSelectedEffect()

    if effect["Id"] = "" {
        return 0
    }

    return GetAvailablePresetNames(
        effect["Id"],
        true
    ).Length
}


GetLayoutPickerCount() {
    return GetLayoutNavigationList(
        true
    ).Length
}


GetFavoriteEffectPickerItems(orderedItems := 0) {
    ; Same sequence as the effect picker: EffectOrder, then natural A-Z.
    sourceItems :=
        GetPickerOrderedItems(
            orderedItems,
            GetEffectNavigationList.Bind(true)
        )

    favorites := []

    for _, effect in sourceItems {
        if IsEffectFavorite(
            effect["Id"],
            effect["Name"]
        ) {
            favorites.Push(
                effect
            )
        }
    }

    return favorites
}


GetFavoritePresetPickerItems(
    effectId,
    orderedItems := 0
) {
    favorites := []

    if effectId = "" {
        return favorites
    }

    ; Same sequence as the preset picker: PresetOrder.<Effect>, then natural A-Z.
    sourceItems :=
        GetPickerOrderedItems(
            orderedItems,
            GetAvailablePresetNames.Bind(effectId, true)
        )

    for _, presetName in sourceItems {
        if IsPresetFavorite(
            effectId,
            presetName
        ) {
            favorites.Push(
                presetName
            )
        }
    }

    return favorites
}


GetFavoriteLayoutPickerItems(orderedItems := 0) {
    ; Same sequence as the layout picker: LayoutOrder, then natural A-Z.
    sourceItems :=
        GetPickerOrderedItems(
            orderedItems,
            GetLayoutNavigationList.Bind(true)
        )

    favorites := []

    for _, layoutName in sourceItems {
        if IsLayoutFavorite(
            layoutName
        ) {
            favorites.Push(
                layoutName
            )
        }
    }

    return favorites
}


GetPickerOrderedItems(
    orderedItems,
    fallbackCallback
) {
    if Type(orderedItems) = "Array" {
        return orderedItems
    }

    return fallbackCallback()
}


GetFavoritePickerCount(
    kind,
    effectId := "",
    orderedItems := 0
) {
    normalizedKind :=
        NormalizeText(
            kind
        )

    if normalizedKind = "effect" {
        return GetFavoriteEffectPickerItems(
            orderedItems
        ).Length
    }

    if normalizedKind = "preset" {
        return GetFavoritePresetPickerItems(
            effectId,
            orderedItems
        ).Length
    }

    return GetFavoriteLayoutPickerItems(
        orderedItems
    ).Length
}


EscapeMenuLabel(text) {
    return StrReplace(
        text,
        "&",
        "&&"
    )
}


AddDisabledMenuItem(
    menuObject,
    text
) {
    menuLabel :=
        EscapeMenuLabel(
            text
        )

    menuObject.Add(
        menuLabel,
        NoAction
    )

    menuObject.Disable(
        menuLabel
    )
}


NoAction(*) {
}


; =====================================================================
; PICKER SELECTION CALLBACKS
; =====================================================================

ApplyPresetPickerSelection(
    effectId,
    effectName,
    presetName,
    presetIndex,
    presetTotal,
    *
) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        currentEffect :=
            GetSelectedEffect()

        if currentEffect["Id"]
            != effectId {
            Notify(
                "The active effect changed.`n" .
                "Open the preset picker again."
            )

            return
        }

        if !PresetExists(
            effectId,
            presetName
        ) {
            throw Error(
                "Preset no longer exists: " .
                presetName
            )
        }

        if ApplyPresetByAlias(
            effectId,
            effectName,
            presetName
        ) {
            WriteLog(
                "Preset selected from picker: " .
                effectName .
                " | " .
                presetName
            )
        }
    } catch as err {
        Notify(
            "Preset selection failed.`n" .
            err.Message
        )

        WriteLog(
            "Preset picker selection error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


ApplyEffectPickerSelection(
    effectId,
    effectName,
    effectIndex,
    effectTotal,
    *
) {
    global gLastSeenEffectId

    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        if ApplyEffect(
            effectId,
            effectName
        ) {
            gLastSeenEffectId :=
                effectId

            Sleep(300)

            ApplyEffectActivationPolicy(
                effectId,
                effectName
            )

            WriteLog(
                "Effect selected from picker: " .
                effectName .
                " | " .
                effectId
            )
        }
    } catch as err {
        Notify(
            "Effect selection failed.`n" .
            err.Message
        )

        WriteLog(
            "Effect picker selection error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


ApplyLayoutPickerSelection(
    layoutName,
    layoutIndex,
    layoutTotal,
    *
) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        if !LayoutExists(
            layoutName
        ) {
            throw Error(
                "Layout no longer exists: " .
                layoutName
            )
        }

        if ApplyLayout(
            layoutName
        ) {
            WriteLog(
                "Layout selected from picker: " .
                layoutName
            )
        }
    } catch as err {
        Notify(
            "Layout selection failed.`n" .
            err.Message
        )

        WriteLog(
            "Layout picker selection error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


; =====================================================================
; CURRENT STATUS
; =====================================================================

ShowStatusHotkey(*) {
    if !BeginOperation() {
        return
    }

    try {
        if !EnsureSignalRgbRunning() {
            return
        }

        effect :=
            GetSelectedEffect()

        effectName :=
            effect["Name"]

        if effectName = "" {
            effectName :=
                "(unknown)"
        }

        effects :=
            GetEffectNavigationList()

        if effects.Length > 0 {
            effectIndex :=
                FindEffectRecordIndex(
                    effects,
                    effect["Id"],
                    effect["Name"]
                )

            effectPosition :=
                FormatPosition(
                    effectIndex,
                    effects.Length
                )
        } else {
            effectPosition :=
                FormatPosition(
                    0,
                    GetLiveEffectCount()
                )
        }

        presetName :=
            GetCurrentPreset(
                effect["Id"]
            )

        if presetName = "" {
            presetName :=
                "(none)"
        }

        presets :=
            GetAvailablePresetNames(
                effect["Id"]
            )

        presetIndex :=
            FindArrayItemIndex(
                presets,
                presetName
            )

        presetPosition :=
            FormatPosition(
                presetIndex,
                presets.Length
            )

        layoutName :=
            GetCurrentLayout()

        if layoutName = "" {
            layoutName :=
                "(none)"
        }

        layouts :=
            GetLayoutNavigationList()

        layoutIndex :=
            FindArrayItemIndex(
                layouts,
                layoutName
            )

        layoutPosition :=
            FormatPosition(
                layoutIndex,
                layouts.Length
            )

        layoutLabel :=
            GetLayoutDisplayLabel(
                effect["Id"],
                effect["Name"],
                layoutName
            )

        statusMessage :=
            "Effect: " .
            effectName .
            " (" .
            effectPosition .
            ")`n" .
            "Preset: " .
            presetName .
            " (" .
            presetPosition .
            ")`n" .
            layoutLabel .
            ": " .
            layoutName .
            " (" .
            layoutPosition .
            ")"

        Notify(
            statusMessage,
            4000
        )
    } catch as err {
        Notify(
            "Status check failed.`n" .
            err.Message
        )

        WriteLog(
            "Status check error: " .
            FormatErrorDetails(err)
        )
    } finally {
        EndOperation()
    }
}


; =====================================================================
; OPERATION LOCKING
; =====================================================================

BeginOperation() {
    global gBusy

    if gBusy {
        return false
    }

    gBusy := true

    return true
}


EndOperation() {
    global gBusy

    gBusy := false
}


; =====================================================================
; SIGNALRGB PROCESS CHECK
; =====================================================================

EnsureSignalRgbRunning() {
    if ProcessExist(
        "SignalRgb.exe"
    ) {
        return true
    }

    Notify(
        "SignalRGB isn't running."
    )

    return false
}


; =====================================================================
; EFFECT AND PRESET STATE
; =====================================================================

GetSelectedEffect() {
    global SELECTED_EFFECT_KEY

    return Map(
        "Id",
        ReadRegistryValue(
            SELECTED_EFFECT_KEY,
            "id",
            ""
        ),

        "Name",
        ReadRegistryValue(
            SELECTED_EFFECT_KEY,
            "name",
            ""
        ),

        "Previous",
        ReadRegistryValue(
            SELECTED_EFFECT_KEY,
            "previous",
            ""
        )
    )
}


GetCurrentPreset(effectId) {
    global EFFECTS_KEY

    if effectId = "" {
        return ""
    }

    effectKey :=
        EFFECTS_KEY "\" effectId

    return ReadRegistryValue(
        effectKey,
        "current_preset",
        ""
    )
}


CountLivePresets(effectId) {
    global STATES_KEY

    if effectId = "" {
        return 0
    }

    stateKey :=
        STATES_KEY "\" effectId

    if !RegistryKeyExists(
        stateKey
    ) {
        return 0
    }

    count := 0

    try {
        Loop Reg, stateKey, "V" {
            presetName :=
                A_LoopRegName

            if presetName = "" {
                continue
            }

            if IsTemporaryPresetAlias(
                presetName
            ) {
                continue
            }

            count++
        }
    }

    return count
}


GetAvailablePresetNames(
    effectId,
    forPicker := false
) {
    global STATES_KEY

    stateKey :=
        STATES_KEY "\" effectId

    livePresets := []

    if !RegistryKeyExists(
        stateKey
    ) {
        return livePresets
    }

    try {
        Loop Reg, stateKey, "V" {
            presetName :=
                A_LoopRegName

            if presetName = "" {
                continue
            }

            if IsTemporaryPresetAlias(
                presetName
            ) {
                continue
            }

            if IsPresetIgnored(
                effectId,
                presetName,
                forPicker
            ) {
                continue
            }

            livePresets.Push(
                presetName
            )
        }
    }

    orderedPresets :=
        GetEffectPresetOrder(
            effectId
        )

    if orderedPresets.Length = 0 {
        return NaturalSortArray(
            livePresets
        )
    }

    results := []
    addedPresets := Map()

    for _, configuredPreset in orderedPresets {
        liveName :=
            FindMatchingArrayItem(
                livePresets,
                configuredPreset
            )

        if liveName = "" {
            continue
        }

        normalizedName :=
            NormalizeText(
                liveName
            )

        if addedPresets.Has(
            normalizedName
        ) {
            continue
        }

        results.Push(
            liveName
        )

        addedPresets[normalizedName] :=
            true
    }

    for _, presetName in NaturalSortArray(livePresets) {
        normalizedName :=
            NormalizeText(
                presetName
            )

        if addedPresets.Has(
            normalizedName
        ) {
            continue
        }

        results.Push(
            presetName
        )

        addedPresets[normalizedName] :=
            true
    }

    return results
}


; =====================================================================
; PRESET APPLYING THROUGH TEMPORARY ALIAS A
; =====================================================================

ApplyPresetByAlias(
    effectId,
    effectName,
    targetPreset
) {
    global STATES_KEY
    global EFFECTS_KEY

    stateKey :=
        STATES_KEY "\" effectId

    effectKey :=
        EFFECTS_KEY "\" effectId

    if !RegistryKeyExists(
        stateKey
    ) {
        throw Error(
            "The preset state key does not exist."
        )
    }

    targetType :=
        GetRegistryValueType(
            stateKey,
            targetPreset
        )

    if targetType = "" {
        throw Error(
            "Preset not found: " .
            targetPreset
        )
    }

    try {
        targetValue :=
            RegRead(
                stateKey,
                targetPreset
            )
    } catch as err {
        throw Error(
            "The preset data could not be read: " .
            err.Message
        )
    }

    originalCurrentPreset :=
        GetCurrentPreset(
            effectId
        )

    aliasName := "A"

    aliasPreviouslyExisted :=
        RegistryValueExists(
            stateKey,
            aliasName
        )

    aliasBackupValue := ""
    aliasBackupType := ""

    if aliasPreviouslyExisted {
        aliasBackupType :=
            GetRegistryValueType(
                stateKey,
                aliasName
            )

        aliasBackupValue :=
            RegRead(
                stateKey,
                aliasName
            )
    }

    applicationSucceeded :=
        false

    try {
        RegWrite(
            targetValue,
            targetType,
            stateKey,
            aliasName
        )

        uri :=
            "signalrgb://effect/applypreset/" .
            UriEncode(effectName) .
            "/" .
            UriEncode(aliasName) .
            "?-silentlaunch-"

        Run(
            uri
        )

        acknowledged :=
            WaitForCurrentPreset(
                effectId,
                aliasName,
                10000
            )

        if !acknowledged {
            throw Error(
                "SignalRGB did not acknowledge temporary preset alias " .
                aliasName .
                "."
            )
        }

        Sleep(150)

        RegWrite(
            targetPreset,
            "REG_SZ",
            effectKey,
            "current_preset"
        )

        applicationSucceeded :=
            true

        return true
    } finally {
        try {
            if aliasPreviouslyExisted {
                RegWrite(
                    aliasBackupValue,
                    aliasBackupType,
                    stateKey,
                    aliasName
                )
            } else {
                RegDelete(
                    stateKey,
                    aliasName
                )
            }
        }

        Sleep(100)

        try {
            if applicationSucceeded {
                RegWrite(
                    targetPreset,
                    "REG_SZ",
                    effectKey,
                    "current_preset"
                )
            } else if originalCurrentPreset != "" {
                RegWrite(
                    originalCurrentPreset,
                    "REG_SZ",
                    effectKey,
                    "current_preset"
                )
            }
        }
    }
}


WaitForCurrentPreset(
    effectId,
    expectedPreset,
    timeoutMilliseconds
) {
    deadline :=
        A_TickCount +
        timeoutMilliseconds

    while A_TickCount < deadline {
        if GetCurrentPreset(
            effectId
        ) = expectedPreset {
            return true
        }

        Sleep(100)
    }

    return false
}


; =====================================================================
; EFFECT APPLYING
; =====================================================================

ApplyEffect(
    effectId,
    effectName
) {
    if effectName = "" {
        throw Error(
            "The effect name is empty."
        )
    }

    uri :=
        "signalrgb://effect/apply/" .
        UriEncode(effectName) .
        "?-silentlaunch-"

    Run(
        uri
    )

    if !WaitForEffect(
        effectId,
        effectName,
        12000
    ) {
        throw Error(
            "SignalRGB did not activate effect: " .
            effectName
        )
    }

    return true
}


WaitForEffect(
    expectedId,
    expectedName,
    timeoutMilliseconds
) {
    deadline :=
        A_TickCount +
        timeoutMilliseconds

    while A_TickCount < deadline {
        effect :=
            GetSelectedEffect()

        idMatches :=
            expectedId != ""
            && effect["Id"] = expectedId

        nameMatches :=
            expectedName != ""
            && SameText(
                effect["Name"],
                expectedName
            )

        if idMatches
            || nameMatches {
            return true
        }

        Sleep(100)
    }

    return false
}


GetEffectNavigationList(
    forPicker := false
) {
    global gConfig

    effectsMap :=
        gConfig["Effects"]

    configuredOrder :=
        gConfig["EffectOrder"]

    results := []
    addedIds := Map()

    if configuredOrder.Length > 0 {
        for _, configuredItem in configuredOrder {
            record :=
                ResolveConfiguredEffect(
                    configuredItem,
                    effectsMap
                )

            if !record {
                continue
            }

            effectId :=
                record["Id"]

            effectName :=
                record["Name"]

            normalizedId :=
                NormalizeText(
                    effectId
                )

            if addedIds.Has(
                normalizedId
            ) {
                continue
            }

            if IsEffectIgnored(
                effectId,
                effectName,
                forPicker
            ) {
                continue
            }

            results.Push(
                record
            )

            addedIds[normalizedId] :=
                true
        }
    }

    remainingRecords := []

    for effectId, effectName in effectsMap {
        normalizedId :=
            NormalizeText(
                effectId
            )

        if addedIds.Has(
            normalizedId
        ) {
            continue
        }

        if effectName = "" {
            continue
        }

        if IsEffectIgnored(
            effectId,
            effectName,
            forPicker
        ) {
            continue
        }

        remainingRecords.Push(
            Map(
                "Id",
                effectId,

                "Name",
                effectName
            )
        )
    }

    remainingRecords :=
        NaturalSortEffectRecords(
            remainingRecords
        )

    for _, record in remainingRecords {
        results.Push(
            record
        )
    }

    return results
}


ResolveConfiguredEffect(
    configuredItem,
    effectsMap
) {
    for effectId, effectName in effectsMap {
        if SameText(
            configuredItem,
            effectName
        ) {
            return Map(
                "Id",
                effectId,

                "Name",
                effectName
            )
        }
    }

    return false
}


GetNextEffectRecord(
    effects,
    currentId,
    currentName
) {
    if effects.Length = 0 {
        return false
    }

    currentIndex :=
        FindEffectRecordIndex(
            effects,
            currentId,
            currentName
        )

    if currentIndex = 0 {
        return effects[1]
    }

    nextIndex :=
        Mod(
            currentIndex,
            effects.Length
        ) + 1

    return effects[nextIndex]
}


GetLiveEffectCount() {
    global EFFECTS_KEY

    count := 0

    try {
        Loop Reg, EFFECTS_KEY, "K" {
            if SameText(
                A_LoopRegName,
                "selected"
            ) {
                continue
            }

            count++
        }
    }

    return count
}


; =====================================================================
; LAYOUT STATE AND APPLYING
; =====================================================================

GetCurrentLayout() {
    global LAYOUTS_KEY

    return ReadRegistryValue(
        LAYOUTS_KEY,
        "currentLayout",
        ""
    )
}


GetLiveLayoutNames() {
    global LAYOUTS_KEY

    results := []

    try {
        Loop Reg, LAYOUTS_KEY, "K" {
            layoutName :=
                A_LoopRegName

            if layoutName != "" {
                results.Push(
                    layoutName
                )
            }
        }
    }

    return NaturalSortArray(
        results
    )
}


GetLayoutNavigationList(
    forPicker := false
) {
    global gConfig

    liveLayouts :=
        GetLiveLayoutNames()

    configuredOrder :=
        gConfig["LayoutOrder"]

    results := []
    addedLayouts := Map()

    for _, configuredLayout in configuredOrder {
        liveName :=
            FindMatchingArrayItem(
                liveLayouts,
                configuredLayout
            )

        if liveName = "" {
            continue
        }

        if IsLayoutIgnored(
            liveName,
            forPicker
        ) {
            continue
        }

        normalizedName :=
            NormalizeText(
                liveName
            )

        if addedLayouts.Has(
            normalizedName
        ) {
            continue
        }

        results.Push(
            liveName
        )

        addedLayouts[normalizedName] :=
            true
    }

    for _, layoutName in liveLayouts {
        normalizedName :=
            NormalizeText(
                layoutName
            )

        if addedLayouts.Has(
            normalizedName
        ) {
            continue
        }

        if IsLayoutIgnored(
            layoutName,
            forPicker
        ) {
            continue
        }

        results.Push(
            layoutName
        )

        addedLayouts[normalizedName] :=
            true
    }

    return results
}


ApplyLayout(layoutName) {
    if layoutName = "" {
        throw Error(
            "The layout name is empty."
        )
    }

    uri :=
        "signalrgb://layout/apply/" .
        UriEncode(layoutName) .
        "?-silentlaunch-"

    Run(
        uri
    )

    if !WaitForLayout(
        layoutName,
        10000
    ) {
        throw Error(
            "SignalRGB did not activate layout: " .
            layoutName
        )
    }

    return true
}


WaitForLayout(
    expectedLayout,
    timeoutMilliseconds
) {
    deadline :=
        A_TickCount +
        timeoutMilliseconds

    while A_TickCount < deadline {
        if SameText(
            GetCurrentLayout(),
            expectedLayout
        ) {
            return true
        }

        Sleep(100)
    }

    return false
}


GetLayoutDisplayLabel(
    effectId,
    effectName,
    currentLayout
) {
    global gConfig

    assignedLayout :=
        LookupConfiguredValue(
            gConfig["EffectLayouts"],
            effectId,
            effectName
        )

    if assignedLayout != ""
        && SameText(
            assignedLayout,
            currentLayout
        ) {
        return "Assigned Layout"
    }

    return "Layout"
}


; =====================================================================
; EFFECT ACTIVATION POLICIES
; =====================================================================

WatchActiveEffect() {
    global gBusy
    global gConfig
    global gLastSeenEffectId

    if gBusy {
        return
    }

    if !gConfig["Behavior"]["WatchExternalEffectChanges"] {
        return
    }

    if !ProcessExist(
        "SignalRgb.exe"
    ) {
        return
    }

    effect :=
        GetSelectedEffect()

    if effect["Id"] = "" {
        return
    }

    if gLastSeenEffectId = "" {
        gLastSeenEffectId :=
            effect["Id"]

        return
    }

    if effect["Id"]
        = gLastSeenEffectId {
        return
    }

    gLastSeenEffectId :=
        effect["Id"]

    gBusy := true

    try {
        Sleep(300)

        ApplyEffectActivationPolicy(
            effect["Id"],
            effect["Name"]
        )

        WriteLog(
            "External effect activation detected: " .
            effect["Name"] .
            " | " .
            effect["Id"]
        )
    } catch as err {
        WriteLog(
            "Activation policy error: " .
            FormatErrorDetails(err)
        )
    } finally {
        gBusy := false
    }
}


ApplyEffectActivationPolicy(
    effectId,
    effectName,
    applyPresetRule := true
) {
    global gConfig

    presetMode :=
        NormalizeText(
            gConfig["Behavior"]["PresetOnEffectActivation"]
        )

    if applyPresetRule
        && !gConfig["Cycling"]["PresetCyclingEnabled"]
        && presetMode = "preferred" {
        preferredPreset :=
            GetEffectActivationPreset(
                effectId
            )

        if preferredPreset != ""
            && PresetExists(
                effectId,
                preferredPreset
            ) {
            ApplyPresetByAlias(
                effectId,
                effectName,
                preferredPreset
            )
        }
    }

    assignedLayout :=
        LookupConfiguredValue(
            gConfig["EffectLayouts"],
            effectId,
            effectName
        )

    if assignedLayout != "" {
        if LayoutExists(
            assignedLayout
        ) {
            ApplyLayout(
                assignedLayout
            )
        }

        return
    }

    unassignedLayoutMode :=
        NormalizeText(
            gConfig["Behavior"]["UnassignedEffectLayoutMode"]
        )

    if unassignedLayoutMode = "defaultlayout"
        || unassignedLayoutMode = "default"
        || unassignedLayoutMode = "preferred" {
        defaultLayout :=
            Trim(
                gConfig["Behavior"]["DefaultLayout"]
            )

        if defaultLayout != ""
            && LayoutExists(
                defaultLayout
            ) {
            ApplyLayout(
                defaultLayout
            )
        }
    }
}


GetEffectActivationPreset(
    effectId
) {
    orderedPresets :=
        GetEffectPresetOrder(
            effectId
        )

    if orderedPresets.Length > 0 {
        availablePresets :=
            GetAvailablePresetNames(
                effectId
            )

        for _, configuredPreset in orderedPresets {
            livePreset :=
                FindMatchingArrayItem(
                    availablePresets,
                    configuredPreset
                )

            if livePreset != "" {
                return livePreset
            }
        }
    }

    return ""
}


LookupConfiguredValue(
    sourceMap,
    effectId,
    effectName
) {
    for configuredKey, configuredValue in sourceMap {
        if SameText(
            configuredKey,
            effectName
        ) {
            return configuredValue
        }
    }

    return ""
}


GetEffectPresetOrder(effectId) {
    global gConfig

    cache :=
        gConfig["PresetOrderCache"]

    if cache.Has(
        effectId
    ) {
        return cache[effectId]
    }

    effectName :=
        GetKnownEffectName(
            effectId
        )

    presetOrder := []

    if effectName != "" {
        presetOrder :=
            ParseIniOrderedSection(
                "PresetOrder." .
                effectName
            )
    }

    cache[effectId] :=
        presetOrder

    return presetOrder
}


GetKnownEffectName(effectId) {
    global gConfig

    effects :=
        gConfig["Effects"]

    if effects.Has(
        effectId
    ) {
        return effects[effectId]
    }

    for knownEffectId, knownEffectName in effects {
        if SameText(
            knownEffectId,
            effectId
        ) {
            return knownEffectName
        }
    }

    return ""
}


; =====================================================================
; IGNORE RULES
; =====================================================================

IsEffectIgnored(
    effectId,
    effectName,
    forPicker := false
) {
    global gConfig

    if !ShouldApplyExclusionRules(
        forPicker
    ) {
        return false
    }

    ignored :=
        gConfig["IgnoredEffects"]

    return ignored.Has(
        NormalizeText(
            effectName
        )
    )
}


IsPresetIgnored(
    effectId,
    presetName,
    forPicker := false
) {
    global gConfig

    if !ShouldApplyExclusionRules(
        forPicker
    ) {
        return false
    }

    normalizedPreset :=
        NormalizeText(
            presetName
        )

    normalizedEffectName :=
        NormalizeText(
            GetKnownEffectName(
                effectId
            )
        )

    ignoredPresets :=
        gConfig["IgnoredPresets"]

    if ignoredPresets.Has(
        "*"
    ) && ignoredPresets["*"].Has(
        normalizedPreset
    ) {
        return true
    }

    return normalizedEffectName != ""
        && ignoredPresets.Has(
            normalizedEffectName
        ) && ignoredPresets[normalizedEffectName].Has(
        normalizedPreset
    )
}


IsLayoutIgnored(
    layoutName,
    forPicker := false
) {
    global gConfig

    if !ShouldApplyExclusionRules(
        forPicker
    ) {
        return false
    }

    return gConfig["IgnoredLayouts"].Has(
        NormalizeText(
            layoutName
        )
    )
}


ShouldApplyExclusionRules(
    useKind
) {
    global gConfig

    if useKind = true {
        return gConfig["Behavior"]["ExcludeFromPickers"]
    }

    normalizedKind :=
        NormalizeText(
            useKind
        )

    if normalizedKind = "picker" {
        return gConfig["Behavior"]["ExcludeFromPickers"]
    }

    if normalizedKind = "cycling" {
        return gConfig["Behavior"]["ExcludeFromCycling"]
    }

    return gConfig["Behavior"]["ExcludeFromNextHotkeys"]
}


IsEffectFavorite(
    effectId,
    effectName
) {
    global gConfig

    return gConfig["FavoriteEffects"].Has(
        NormalizeText(
            effectName
        )
    )
}


IsPresetFavorite(
    effectId,
    presetName
) {
    global gConfig

    normalizedPreset :=
        NormalizeText(
            presetName
        )

    normalizedEffectName :=
        NormalizeText(
            GetKnownEffectName(
                effectId
            )
        )

    favoritePresets :=
        gConfig["FavoritePresets"]

    return normalizedEffectName != ""
        && favoritePresets.Has(
            normalizedEffectName
        ) && favoritePresets[normalizedEffectName].Has(
        normalizedPreset
    )
}


IsLayoutFavorite(layoutName) {
    global gConfig

    return gConfig["FavoriteLayouts"].Has(
        NormalizeText(
            layoutName
        )
    )
}


IsConfiguredIgnoredEffect(effectName) {
    global gConfig

    return gConfig["IgnoredEffects"].Has(
        NormalizeText(
            effectName
        )
    )
}


IsConfiguredIgnoredPreset(
    effectName,
    presetName
) {
    global gConfig

    normalizedPreset :=
        NormalizeText(
            presetName
        )

    normalizedEffectName :=
        NormalizeText(
            effectName
        )

    ignoredPresets :=
        gConfig["IgnoredPresets"]

    if ignoredPresets.Has(
        "*"
    ) && ignoredPresets["*"].Has(
        normalizedPreset
    ) {
        return true
    }

    return normalizedEffectName != ""
        && ignoredPresets.Has(
            normalizedEffectName
        ) && ignoredPresets[normalizedEffectName].Has(
        normalizedPreset
    )
}


IsConfiguredIgnoredLayout(layoutName) {
    global gConfig

    return gConfig["IgnoredLayouts"].Has(
        NormalizeText(
            layoutName
        )
    )
}


ReloadIgnoredConfiguration() {
    global gConfig

    gConfig :=
        LoadConfig()
}


AppendBareIniEntry(
    section,
    entryText
) {
    global CONFIG_PATH

    cleanEntry :=
        Trim(
            entryText . ""
        )

    if cleanEntry = "" {
        throw Error(
            "The ignore entry is empty."
        )
    }

    if !FileExist(
        CONFIG_PATH
    ) {
        throw Error(
            "config.ini was not found."
        )
    }

    try {
        text :=
            FileRead(
                CONFIG_PATH,
                "UTF-8"
            )
    } catch as err {
        throw Error(
            "config.ini could not be read: " .
            err.Message
        )
    }

    newline :=
        InStr(
            text,
            "`r`n"
        )
            ? "`r`n"
            : "`n"

    lines := []

    Loop Parse, text, "`n", "`r" {
        lines.Push(
            A_LoopField
        )
    }

    sectionIndex := 0
    nextSectionIndex := 0

    for index, line in lines {
        trimmedLine :=
            Trim(
                line
            )

        if !RegExMatch(
            trimmedLine,
            "^\[(.*)\]$",
            &sectionMatch
        ) {
            continue
        }

        if SameText(
            Trim(
                sectionMatch[1]
            ),
            section
        ) {
            sectionIndex := index
            continue
        }

        if sectionIndex > 0
            && nextSectionIndex = 0 {
            nextSectionIndex := index
            break
        }
    }

    if sectionIndex = 0 {
        if lines.Length > 0
            && Trim(
                lines[lines.Length]
            ) != "" {
            lines.Push(
                ""
            )
        }

        lines.Push(
            "[" .
            section .
            "]"
        )

        lines.Push(
            cleanEntry
        )
    } else {
        searchEnd :=
            nextSectionIndex > 0
                ? nextSectionIndex - 1
                : lines.Length

        for index, line in lines {
            if index <= sectionIndex
                || index > searchEnd {
                continue
            }

            candidate :=
                Trim(
                    line
                )

            if candidate = "" {
                continue
            }

            firstCharacter :=
                SubStr(
                    candidate,
                    1,
                    1
                )

            if firstCharacter = ";"
                || firstCharacter = "#" {
                continue
            }

            separatorPosition :=
                InStr(
                    candidate,
                    "="
                )

            existingKey :=
                separatorPosition > 0
                    ? Trim(
                        SubStr(
                            candidate,
                            1,
                            separatorPosition - 1
                        )
                    )
                    : candidate

            if SameText(
                existingKey,
                cleanEntry
            ) {
                return
            }
        }

        insertAt :=
            searchEnd + 1

        while insertAt > sectionIndex + 1
            && Trim(
                lines[insertAt - 1]
            ) = "" {
            insertAt--
        }

        lines.InsertAt(
            insertAt,
            cleanEntry
        )
    }

    newText := ""

    for index, line in lines {
        newText .=
            line

        if index < lines.Length {
            newText .=
                newline
        }
    }

    if (
        SubStr(
            text,
            -1
        ) = "`n"
        || SubStr(
            text,
            -2
        ) = "`r`n"
    ) {
        newText .=
            newline
    }

    file :=
        FileOpen(
            CONFIG_PATH,
            "w",
            "UTF-8-RAW"
        )

    if !file {
        throw Error(
            "config.ini could not be written."
        )
    }

    try {
        file.Write(
            newText
        )
    } finally {
        file.Close()
    }
}


; =====================================================================
; EXISTENCE AND REGISTRY HELPERS
; =====================================================================

PresetExists(
    effectId,
    presetName
) {
    global STATES_KEY

    stateKey :=
        STATES_KEY "\" effectId

    return RegistryValueExists(
        stateKey,
        presetName
    )
}


LayoutExists(layoutName) {
    liveLayouts :=
        GetLiveLayoutNames()

    return FindMatchingArrayItem(
        liveLayouts,
        layoutName
    ) != ""
}


RegistryKeyExists(keyName) {
    try {
        Loop Reg, keyName, "V" {
            return true
        }

        Loop Reg, keyName, "K" {
            return true
        }

        RegRead(
            keyName
        )

        return true
    } catch {
        return false
    }
}


RegistryValueExists(
    keyName,
    valueName
) {
    try {
        Loop Reg, keyName, "V" {
            if A_LoopRegName
                = valueName {
                return true
            }
        }
    }

    return false
}


GetRegistryValueType(
    keyName,
    valueName
) {
    try {
        Loop Reg, keyName, "V" {
            if A_LoopRegName
                = valueName {
                return A_LoopRegType
            }
        }
    }

    return ""
}


ReadRegistryValue(
    keyName,
    valueName,
    defaultValue := ""
) {
    try {
        return RegRead(
            keyName,
            valueName
        )
    } catch {
        return defaultValue
    }
}


; =====================================================================
; NATURAL WINDOWS EXPLORER-STYLE SORTING
; =====================================================================

NaturalCompare(
    first,
    second
) {
    firstText :=
        first . ""

    secondText :=
        second . ""

    try {
        return DllCall(
            "Shlwapi.dll\StrCmpLogicalW",
            "Str",
            firstText,
            "Str",
            secondText,
            "Int"
        )
    } catch {
        firstNormalized :=
            NormalizeText(
                firstText
            )

        secondNormalized :=
            NormalizeText(
                secondText
            )

        if firstNormalized
            = secondNormalized {
            return 0
        }

        return firstNormalized
            < secondNormalized
                ? -1
                : 1
    }
}


NaturalSortArray(items) {
    sorted := []

    for _, item in items {
        insertionIndex :=
            sorted.Length + 1

        for existingIndex, existingItem in sorted {
            if NaturalCompare(
                item,
                existingItem
            ) < 0 {
                insertionIndex :=
                    existingIndex

                break
            }
        }

        sorted.InsertAt(
            insertionIndex,
            item
        )
    }

    return sorted
}


NaturalSortEffectRecords(records) {
    sorted := []

    for _, record in records {
        insertionIndex :=
            sorted.Length + 1

        for existingIndex, existingRecord in sorted {
            comparison :=
                NaturalCompare(
                    record["Name"],
                    existingRecord["Name"]
                )

            if comparison = 0 {
                comparison :=
                    NaturalCompare(
                        record["Id"],
                        existingRecord["Id"]
                    )
            }

            if comparison < 0 {
                insertionIndex :=
                    existingIndex

                break
            }
        }

        sorted.InsertAt(
            insertionIndex,
            record
        )
    }

    return sorted
}


; =====================================================================
; ARRAY AND POSITION HELPERS
; =====================================================================

GetNextArrayItem(
    items,
    currentValue
) {
    if items.Length = 0 {
        return ""
    }

    currentIndex :=
        FindArrayItemIndex(
            items,
            currentValue
        )

    if currentIndex = 0 {
        return items[1]
    }

    nextIndex :=
        Mod(
            currentIndex,
            items.Length
        ) + 1

    return items[nextIndex]
}


FindArrayItemIndex(
    items,
    requestedValue
) {
    for index, item in items {
        if SameText(
            item,
            requestedValue
        ) {
            return index
        }
    }

    return 0
}


FindMatchingArrayItem(
    items,
    requestedValue
) {
    index :=
        FindArrayItemIndex(
            items,
            requestedValue
        )

    if index = 0 {
        return ""
    }

    return items[index]
}


FindEffectRecordIndex(
    effects,
    currentId,
    currentName
) {
    for index, effect in effects {
        if (
            currentId != ""
            && effect["Id"] = currentId
        ) || SameText(
            effect["Name"],
            currentName
        ) {
            return index
        }
    }

    return 0
}


FormatPosition(
    index,
    total
) {
    if total <= 0 {
        return "?/0"
    }

    if index <= 0 {
        return "?/" total
    }

    return index "/" total
}


; =====================================================================
; URL ENCODING
; =====================================================================

UriEncode(text) {
    byteCount :=
        StrPut(
            text,
            "UTF-8"
        )

    utf8Buffer :=
        Buffer(
            byteCount
        )

    StrPut(
        text,
        utf8Buffer,
        "UTF-8"
    )

    result := ""

    Loop (byteCount - 1) {
        byteValue :=
            NumGet(
                utf8Buffer,
                A_Index - 1,
                "UChar"
            )

        isUnreserved :=
            (
                byteValue >= 0x41
                && byteValue <= 0x5A
            )
            || (
                byteValue >= 0x61
                && byteValue <= 0x7A
            )
            || (
                byteValue >= 0x30
                && byteValue <= 0x39
            )
            || byteValue = 0x2D
            || byteValue = 0x2E
            || byteValue = 0x5F
            || byteValue = 0x7E

        if isUnreserved {
            result .=
                Chr(
                    byteValue
                )
        } else {
            result .=
                "%" .
                Format(
                    "{:02X}",
                    byteValue
                )
        }
    }

    return result
}


; =====================================================================
; WINDOWS APP THEME (NATIVE MENUS AND TOOLTIPS)
; Undocumented uxtheme ordinals:
;   132 ShouldAppsUseDarkMode
;   133 AllowDarkModeForWindow
;   135 SetPreferredAppMode (1903+) / AllowDarkModeForApp (1809)
;   136 FlushMenuThemes
;   104 RefreshImmersiveColorPolicyState
; =====================================================================

InitializeWindowsAppTheme() {
    global gThemeWinEventCallback
    global gThemeWinEventHook

    LoadUxThemeThemeApis()
    ApplyWindowsAppTheme()

    OnMessage(
        0x001A,
        OnWindowsSettingChange
    )

    if gThemeWinEventHook {
        return
    }

    try {
        gThemeWinEventCallback :=
            CallbackCreate(
                OnThemeWindowEvent
            )

        gThemeWinEventHook :=
            DllCall(
                "SetWinEventHook",
                "UInt",
                0x8000,
                "UInt",
                0x8002,
                "Ptr",
                0,
                "Ptr",
                gThemeWinEventCallback,
                "UInt",
                DllCall(
                    "GetCurrentProcessId"
                ),
                "UInt",
                0,
                "UInt",
                0,
                "Ptr"
            )
    } catch {
        gThemeWinEventHook :=
            0
    }
}


LoadUxThemeThemeApis() {
    global gUxThemeModule
    global gSetPreferredAppMode
    global gAllowDarkModeForApp
    global gAllowDarkModeForWindow
    global gFlushMenuThemes
    global gRefreshImmersiveColorPolicyState

    if gUxThemeModule {
        return
    }

    try {
        gUxThemeModule :=
            DllCall(
                "GetModuleHandle",
                "Str",
                "uxtheme",
                "Ptr"
            )

        if !gUxThemeModule {
            gUxThemeModule :=
                DllCall(
                    "LoadLibrary",
                    "Str",
                    "uxtheme.dll",
                    "Ptr"
                )
        }
    } catch {
        gUxThemeModule :=
            0
    }

    if !gUxThemeModule {
        return
    }

    gAllowDarkModeForWindow :=
        GetUxThemeProc(
            133
        )

    gFlushMenuThemes :=
        GetUxThemeProc(
            136
        )

    gRefreshImmersiveColorPolicyState :=
        GetUxThemeProc(
            104
        )

    ordinal135 :=
        GetUxThemeProc(
            135
        )

    if VerCompare(
        A_OSVersion,
        "10.0.18362"
    ) >= 0 {
        gSetPreferredAppMode :=
            ordinal135
    } else {
        gAllowDarkModeForApp :=
            ordinal135
    }
}


GetUxThemeProc(ordinal) {
    global gUxThemeModule

    if !gUxThemeModule {
        return 0
    }

    try {
        return DllCall(
            "GetProcAddress",
            "Ptr",
            gUxThemeModule,
            "Ptr",
            ordinal,
            "Ptr"
        )
    } catch {
        return 0
    }
}


IsWindowsAppDarkTheme() {
    global WINDOWS_THEME_PERSONALIZE_KEY

    value :=
        ReadRegistryValue(
            WINDOWS_THEME_PERSONALIZE_KEY,
            "AppsUseLightTheme",
            1
        )

    try {
        return Integer(
            value
        ) = 0
    } catch {
        return false
    }
}


GetWindowsAppThemeColors() {
    if IsWindowsAppDarkTheme() {
        return Map(
            "Background",
            "1E1E1E",

            "Text",
            "F2F2F2",

            "UseDark",
            true
        )
    }

    return Map(
        "Background",
        "F5F5F5",

        "Text",
        "1A1A1A",

        "UseDark",
        false
    )
}


ApplyWindowsAppTheme() {
    global gCurrentAppThemeIsDark
    global gNotifyGui
    global gNotifyText
    global gSetPreferredAppMode
    global gAllowDarkModeForApp
    global gFlushMenuThemes
    global gRefreshImmersiveColorPolicyState

    LoadUxThemeThemeApis()

    useDark :=
        IsWindowsAppDarkTheme()

    gCurrentAppThemeIsDark :=
        useDark

    try {
        if gSetPreferredAppMode {
            DllCall(
                gSetPreferredAppMode,
                "Int",
                useDark ? 2 : 3
            )
        } else if gAllowDarkModeForApp {
            DllCall(
                gAllowDarkModeForApp,
                "Int",
                useDark
            )
        }

        if gRefreshImmersiveColorPolicyState {
            DllCall(
                gRefreshImmersiveColorPolicyState
            )
        }

        if gFlushMenuThemes {
            DllCall(
                gFlushMenuThemes
            )
        }
    } catch {
    }

    ApplyNativeWindowTheme(
        A_ScriptHwnd
    )

    ApplyThemeToExistingTooltipWindows()

    if IsObject(
        gNotifyGui
    ) {
        colors :=
            GetWindowsAppThemeColors()

        try {
            gNotifyGui.BackColor :=
                colors["Background"]
        }

        try {
            if IsObject(
                gNotifyText
            ) {
                gNotifyText.SetFont(
                    "c" colors["Text"]
                )
            }
        }

        try {
            ApplyNativeWindowTheme(
                gNotifyGui.Hwnd
            )
        }
    }
}


ApplyNativeWindowTheme(windowHandle) {
    global gAllowDarkModeForWindow

    if !windowHandle {
        return
    }

    useDark :=
        IsWindowsAppDarkTheme()

    try {
        if gAllowDarkModeForWindow {
            DllCall(
                gAllowDarkModeForWindow,
                "Ptr",
                windowHandle,
                "Int",
                useDark
            )
        }
    } catch {
    }

    themeName :=
        useDark
            ? "DarkMode_Explorer"
            : "Explorer"

    try {
        DllCall(
            "uxtheme\SetWindowTheme",
            "Ptr",
            windowHandle,
            "Str",
            themeName,
            "Ptr",
            0
        )
    } catch {
    }

    attribute :=
        VerCompare(
            A_OSVersion,
            "10.0.18985"
        ) >= 0
            ? 20
            : 19

    darkValue :=
        useDark ? 1 : 0

    try {
        DllCall(
            "dwmapi\DwmSetWindowAttribute",
            "Ptr",
            windowHandle,
            "UInt",
            attribute,
            "Int*",
            darkValue,
            "UInt",
            4
        )
    } catch {
    }

    try {
        SendMessage(
            0x031A,
            0,
            0,
            windowHandle
        )
    } catch {
    }
}


ApplyThemeToExistingTooltipWindows() {
    previousDetect :=
        A_DetectHiddenWindows

    DetectHiddenWindows(
        true
    )

    try {
        for windowHandle in WinGetList(
            "ahk_class tooltips_class32"
        ) {
            ApplyNativeWindowTheme(
                windowHandle
            )
        }
    } catch {
    }

    DetectHiddenWindows(
        previousDetect
    )
}


OnWindowsSettingChange(
    wParam,
    lParam,
    *
) {
    themeChanged :=
        false

    if lParam {
        try {
            settingName :=
                StrGet(
                    lParam
                )

            if settingName = "ImmersiveColorSet"
                || settingName = "WindowsThemeElement" {
                themeChanged :=
                    true
            }
        } catch {
        }
    }

    if themeChanged {
        SetTimer(
            ApplyWindowsAppTheme,
            -50
        )
    }

    return 0
}


OnThemeWindowEvent(
    hWinEventHook,
    event,
    hwnd,
    idObject,
    idChild,
    idEventThread,
    dwmsEventTime
) {
    if !hwnd
        || idObject != 0 {
        return
    }

    className :=
        GetWindowClassName(
            hwnd
        )

    if className = "tooltips_class32" {
        ApplyNativeWindowTheme(
            hwnd
        )
    }
}


GetWindowClassName(windowHandle) {
    if !windowHandle {
        return ""
    }

    classBuffer :=
        Buffer(
            256,
            0
        )

    try {
        DllCall(
            "GetClassName",
            "Ptr",
            windowHandle,
            "Ptr",
            classBuffer,
            "Int",
            128
        )
    } catch {
        return ""
    }

    return StrGet(
        classBuffer
    )
}


; =====================================================================
; STATUS NOTIFICATIONS
; =====================================================================

Notify(
    message,
    durationMilliseconds := 2000
) {
    global gConfig
    global gNotifyGui
    global gNotifyText

    if gConfig.Has(
        "Behavior"
    ) && !gConfig["Behavior"]["ShowHotkeyNotifications"] {
        return
    }

    SetTimer(
        HideNotification,
        0
    )

    HideNotification()

    colors :=
        GetWindowsAppThemeColors()

    gNotifyGui :=
        Gui(
            "+AlwaysOnTop " .
            "-Caption " .
            "+ToolWindow " .
            "+Border " .
            "+E0x20"
        )

    gNotifyGui.BackColor :=
        colors["Background"]

    gNotifyGui.MarginX := 12
    gNotifyGui.MarginY := 9

    gNotifyGui.SetFont(
        "s10 c" colors["Text"],
        "Segoe UI"
    )

    gNotifyText :=
        gNotifyGui.AddText(
            "",
            message
        )

    ApplyNativeWindowTheme(
        gNotifyGui.Hwnd
    )

    gNotifyText.GetPos(
        ,
        ,
        &textWidth,
        &textHeight
    )

    estimatedWidth :=
        textWidth +
        (gNotifyGui.MarginX * 2) +
        4

    estimatedHeight :=
        textHeight +
        (gNotifyGui.MarginY * 2) +
        4

    CoordMode(
        "Mouse",
        "Screen"
    )

    MouseGetPos(
        &mouseX,
        &mouseY
    )

    workArea :=
        GetWorkAreaForPoint(
            mouseX,
            mouseY
        )

    verticalGap := 16

    ; Prefer centered directly above the cursor.
    targetX :=
        mouseX -
        Floor(
            estimatedWidth / 2
        )

    targetY :=
        mouseY -
        estimatedHeight -
        verticalGap

    if targetX
        < workArea["Left"] {
        targetX :=
            workArea["Left"] + 8
    }

    if targetX + estimatedWidth
        > workArea["Right"] {
        targetX :=
            workArea["Right"] -
            estimatedWidth -
            8
    }

    ; Place below the cursor when there is not enough room above.
    if targetY
        < workArea["Top"] {
        targetY :=
            mouseY +
            verticalGap
    }

    if targetY + estimatedHeight
        > workArea["Bottom"] {
        targetY :=
            workArea["Bottom"] -
            estimatedHeight -
            8
    }

    gNotifyGui.Show(
        "NA AutoSize " .
        "x" targetX " " .
        "y" targetY
    )

    gNotifyGui.GetPos(
        ,
        ,
        &actualWidth,
        &actualHeight
    )

    correctedX :=
        mouseX -
        Floor(
            actualWidth / 2
        )

    correctedY :=
        mouseY -
        actualHeight -
        verticalGap

    if correctedX
        < workArea["Left"] {
        correctedX :=
            workArea["Left"] + 8
    }

    if correctedX + actualWidth
        > workArea["Right"] {
        correctedX :=
            workArea["Right"] -
            actualWidth -
            8
    }

    if correctedY
        < workArea["Top"] {
        correctedY :=
            mouseY +
            verticalGap
    }

    if correctedY + actualHeight
        > workArea["Bottom"] {
        correctedY :=
            workArea["Bottom"] -
            actualHeight -
            8
    }

    gNotifyGui.Show(
        "NA AutoSize " .
        "x" correctedX " " .
        "y" correctedY
    )

    SetTimer(
        HideNotification,
        -durationMilliseconds
    )

    SetNotificationClickDismiss(
        true
    )
}


HideNotification() {
    global gNotifyGui
    global gNotifyText

    SetTimer(
        HideNotification,
        0
    )

    SetNotificationClickDismiss(
        false
    )

    if IsObject(
        gNotifyGui
    ) {
        try {
            gNotifyGui.Hide()
        }

        try {
            gNotifyGui.Destroy()
        }
    }

    gNotifyGui := 0
    gNotifyText := 0
}


HideNotificationFromClick(*) {
    HideNotification()
}


SetNotificationClickDismiss(isEnabled) {
    global gNotifyClickHotkeysActive
    global NOTIFY_CLICK_DISMISS_HOTKEYS

    if gNotifyClickHotkeysActive = isEnabled {
        return
    }

    for _, hotkeyText in NOTIFY_CLICK_DISMISS_HOTKEYS {
        try {
            Hotkey(
                hotkeyText,
                HideNotificationFromClick,
                isEnabled ? "On" : "Off"
            )
        }
    }

    gNotifyClickHotkeysActive := isEnabled
}


GetWorkAreaForPoint(
    pointX,
    pointY
) {
    monitorCount :=
        MonitorGetCount()

    Loop monitorCount {
        monitorIndex :=
            A_Index

        MonitorGetWorkArea(
            monitorIndex,
            &left,
            &top,
            &right,
            &bottom
        )

        if pointX >= left
            && pointX < right
            && pointY >= top
            && pointY < bottom {
            return Map(
                "Left",
                left,

                "Top",
                top,

                "Right",
                right,

                "Bottom",
                bottom
            )
        }
    }

    MonitorGetWorkArea(
        1,
        &left,
        &top,
        &right,
        &bottom
    )

    return Map(
        "Left",
        left,

        "Top",
        top,

        "Right",
        right,

        "Bottom",
        bottom
    )
}


; =====================================================================
; ERROR DETAILS
; =====================================================================

FormatErrorDetails(errorObject) {
    details :=
        errorObject.Message

    try {
        if errorObject.What != "" {
            details .=
                " | What=" .
                errorObject.What
        }
    }

    try {
        if errorObject.Line != "" {
            details .=
                " | Line=" .
                errorObject.Line
        }
    }

    try {
        if errorObject.File != "" {
            details .=
                " | File=" .
                errorObject.File
        }
    }

    try {
        if errorObject.Stack != "" {
            details .=
                " | Stack=" .
                StrReplace(
                    errorObject.Stack,
                    "`n",
                    " <- "
                )
        }
    }

    return details
}


; =====================================================================
; LOGGING
; =====================================================================

WriteLog(message) {
    global gConfig
    global LOG_PATH

    if !gConfig.Has(
        "Behavior"
    ) || !gConfig["Behavior"]["Logging"] {
        return
    }

    timestamp :=
        FormatTime(
            A_Now,
            "yyyy-MM-dd HH:mm:ss"
        )

    try {
        FileAppend(
            timestamp .
            " | " .
            message .
            "`n",
            LOG_PATH,
            "UTF-8"
        )
    }
}
