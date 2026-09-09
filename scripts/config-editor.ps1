[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ConfigPath,
    [string]$InventoryPath,
    [string]$SnapshotPath,
    [ValidateSet('Effects', 'Layouts', 'Cycling', 'Hotkeys', 'Settings')]
    [string]$SnapshotTab = 'Effects',
    [switch]$SnapshotExpandFirst,
    [switch]$ValidateOnly,
    [switch]$TestSave
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# WPF uses XAML for presentation and routed events for interaction.
# Sources:
# https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/
# https://learn.microsoft.com/en-us/dotnet/desktop/wpf/controls/styles-templates-overview
# https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/drag-and-drop-overview
# https://learn.microsoft.com/en-us/dotnet/api/system.windows.markup.xamlreader.load
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

if (
    [Threading.Thread]::CurrentThread.ApartmentState -ne
    [Threading.ApartmentState]::STA
) {
    throw 'The config editor must run in an STA PowerShell process.'
}

$script:ScriptDirectory = Split-Path -Parent $PSCommandPath
$script:Window = $null
$script:InventoryPathWasProvided = $PSBoundParameters.ContainsKey(
    'InventoryPath'
)

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $script:ProjectRoot = Split-Path -Parent $script:ScriptDirectory
}
else {
    $script:ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $script:ConfigPath = Join-Path $script:ProjectRoot 'config.ini'
}
else {
    $script:ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
}

if ([string]::IsNullOrWhiteSpace($InventoryPath)) {
    $script:InventoryPath = Join-Path $script:ProjectRoot 'data\inventory.ini'
}
else {
    $script:InventoryPath = [IO.Path]::GetFullPath($InventoryPath)
}

$script:XamlPath = Join-Path $script:ScriptDirectory 'config-editor.xaml'
$script:IsInitializing = $true
$script:IsDirty = $false
$script:SaveOccurred = $false
$script:AllowClose = $false
$script:AdvancedExpanded = $false
$script:DragStartPoint = $null
$script:DragSource = $null
$script:DropRows = [Collections.ArrayList]::new()
$script:InitialStateSignature = ''
$script:ActiveDropIndicatorKey = ''
$script:ClosePromptActive = $false
$script:HotkeyCaptureFinalized = $false
$script:StatusResetTimer = $null
$script:ActiveStatusTimer = $null
$script:EffectsFilterSort = 'CustomOrder'
$script:EffectsFilterAssignedLayouts = $false
$script:EffectsFilterSpecificLayout = ''
$script:EffectsFilterNoAssignedLayouts = $false
$script:EffectsFilterFavorites = $false
$script:EffectsFilterIgnoredPlacement = ''
$script:OwnCustomEffectOrderSnapshot = $null
$script:LoadedCustomEffectOrderSnapshot = $null
$script:IsUpdatingEffectsFilterUi = $false
$script:HotkeyDefaults = [ordered]@{
    OpenPickerMenu = '^!+m'
    PickPreset = '^!+p'
    PickEffect = '^!+e'
    PickLayout = '^!+l'
    GoToNextPreset = '^!p'
    GoToNextEffect = '^!e'
    GoToNextLayout = '^!l'
    ShowStatus = '^!s'
}

function New-CaseInsensitiveOrderedDictionary {
    return ,([Collections.Specialized.OrderedDictionary]::new(
        [StringComparer]::OrdinalIgnoreCase
    ))
}

function New-DefaultConfigText {
    return @'
; --------------------------

; SignalRGB Pro Switcher Free
; by landnthrn

; The inventory updater won't overwrite your custom config setup, it'll just add new detected items.
; If any items are no longer detected, they will remain in this file marked as 'No Longer Found'.
; Highly suggest using the app to configure this file, but if not use the `data/inventory.md` to help you
; Inventory updates rewrite `data\config.backup.ini` with the config's previous state before latest update.

; --------------------------

[Assets]
InventoryFile=data\inventory.ini
UpdaterScript=scripts\inventory-creator-updater.ps1

; --------------------------

[Hotkeys]
; Hotkey format uses normal AutoHotkey style
; + = Shift, ^ = Ctrl, ! = Alt, # = Win
; Example: ^!+p = Ctrl+Alt+Shift+P, !s = Alt+S
OpenPickerMenu=^!+m
PickPreset=^!+p
PickEffect=^!+e
PickLayout=^!+l
GoToNextPreset=^!p
GoToNextEffect=^!e
GoToNextLayout=^!l
ShowStatus=^!s

; --------------------------

[Behavior]
LaunchOnStartup=false
AutoUpdateInventory=false
AutoUpdateInventoryInterval=0h 2m 30s
ShowHotkeyNotifications=true
Logging=false

; Watches only for active effect changes made outside the macros.
; When that happens, preset/layout activation rules are applied to the new active effect.
WatchExternalEffectChanges=true

; Applies preset/layout rules to the currently active effect when the macros start.
ApplyPoliciesOnStartup=true
RememberLastActiveEffectPreset=true

; Behaviour for Loading preset on effect activation.
; LastUsed or Preferred. Preferred uses the top preset in [PresetOrder.<Effect Name>].
PresetOnEffectActivation=LastUsed

; Current or DefaultLayout
UnassignedEffectLayoutMode=Current
DefaultLayout=

; --------------------------

ExcludeFromPickers=false
ExcludeFromNextHotkeys=true
ExcludeFromCycling=true

; --------------------------

[Cycling]
; EffectCyclingMode: Order or Random
; CycleEffectOnceAllPresetsElapsed: when on, effects advance after all presets have elapsed instead of on the effect interval.
; PresetCyclingMode: Order or Random
; If both normal effect cycling and preset cycling are enabled, keep PresetCyclingInterval lower than EffectCyclingInterval.
EffectCyclingEnabled=false
EffectCyclingMode=Order
EffectCyclingInterval=0h 15m 0s
CycleEffectOnceAllPresetsElapsed=false
PresetCyclingEnabled=false
PresetCyclingMode=Order
PresetCyclingInterval=0h 15m 0s

[IgnoredEffects]
; Exclude effects from pickers, go-to-next hotkeys, and/or cycling
; Format: Effect Name

[IgnoredPresets]
; Exclude presets from pickers, go-to-next hotkeys, and/or cycling
; Format: Effect Name|Preset Name

[IgnoredLayouts]
; Exclude layouts from pickers and/or go-to-next hotkeys
; Format: Layout Name

; --------------------------

[FavoriteEffects]
; Starred effects in the config editor
; Format: Effect Name

[FavoritePresets]
; Starred presets in the config editor
; Format: Effect Name|Preset Name

[FavoriteLayouts]
; Starred layouts in the config editor
; Format: Layout Name

; --------------------------

[EffectLayouts]
; Assign layouts to effects.
; Format: Effect Name=Layout Name

; --------------------------

[LayoutOrder]
; The order for pickers, go-to-next hotkeys, and cycling
; Format: 001=Layout Name

; --------------------------

[EffectOrder]
; The order for pickers, go-to-next hotkeys, and cycling
; Format: 001=Effect Name

; [PresetOrder.<Effect Name>]
; The order for pickers, go-to-next hotkeys, and cycling.
; Format: 001=Preset Name

; --------------------------
'@
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path

    if (
        -not [string]::IsNullOrWhiteSpace($parent) -and
        -not (Test-Path -LiteralPath $parent -PathType Container)
    ) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }

    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $cleanPath = $Path.Trim()

    if ([IO.Path]::IsPathRooted($cleanPath)) {
        return [IO.Path]::GetFullPath($cleanPath)
    }

    return [IO.Path]::GetFullPath(
        (Join-Path $script:ProjectRoot $cleanPath)
    )
}

function Read-IniDocument {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Path = $Path
            Lines = [Collections.ArrayList]::new()
            Sections = New-CaseInsensitiveOrderedDictionary
        }
    }

    $rawText = [IO.File]::ReadAllText($Path)
    $rawLines = [Text.RegularExpressions.Regex]::Split(
        $rawText,
        "`r`n|`n|`r"
    )

    $lines = [Collections.ArrayList]::new()

    foreach ($line in $rawLines) {
        [void]$lines.Add([string]$line)
    }

    $sections = New-CaseInsensitiveOrderedDictionary
    $currentSection = $null

    foreach ($line in $lines) {
        $trimmed = ([string]$line).Trim()

        if ($trimmed -match '^\[(?<Name>[^\]]+)\]$') {
            $currentSection = $Matches.Name.Trim()

            if (-not $sections.Contains($currentSection)) {
                $sections.Add(
                    $currentSection,
                    (New-CaseInsensitiveOrderedDictionary)
                )
            }

            continue
        }

        if (
            $null -eq $currentSection -or
            $trimmed.Length -eq 0 -or
            $trimmed.StartsWith(';') -or
            $trimmed.StartsWith('#')
        ) {
            continue
        }

        $separator = $trimmed.IndexOf('=')

        if ($separator -lt 1) {
            $key = $trimmed
            $value = 'true'
        }
        else {
            $key = $trimmed.Substring(0, $separator).Trim()
            $value = $trimmed.Substring($separator + 1).Trim()
        }

        $section = $sections[$currentSection]

        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        if ($section.Contains($key)) {
            $section[$key] = $value
        }
        else {
            $section.Add($key, $value)
        }
    }

    return [pscustomobject]@{
        Path = $Path
        Lines = $lines
        Sections = $sections
    }
}

function Get-IniSection {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Document.Sections.Contains($Name)) {
        return ,$Document.Sections[$Name]
    }

    return ,(New-CaseInsensitiveOrderedDictionary)
}

function Get-IniValue {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )

    $values = Get-IniSection -Document $Document -Name $Section

    if ($values.Contains($Key)) {
        return [string]$values[$Key]
    }

    return $Default
}

function Test-IniTrue {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }

    switch -Regex (([string]$Value).Trim()) {
        '^(1|true|yes|on|enabled)$' { return $true }
        '^(0|false|no|off|disabled)$' { return $false }
        default { return $Default }
    }
}

function Test-SameText {
    param(
        [AllowNull()][object]$Left,
        [AllowNull()][object]$Right
    )

    return [string]::Equals(
        ([string]$Left).Trim(),
        ([string]$Right).Trim(),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-NormalizedText {
    param([AllowNull()][object]$Value)

    return ([string]$Value).Trim().ToLowerInvariant()
}

function Get-EnabledKeySet {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Section
    )

    $result = @{}
    $values = Get-IniSection -Document $Document -Name $Section

    foreach ($key in $values.Keys) {
        if (Test-IniTrue -Value $values[$key] -Default $false) {
            $result[(Get-NormalizedText $key)] = $true
        }
    }

    return ,$result
}

function Add-LookupSetValue {
    param(
        [Parameter(Mandatory)]$Lookup,
        [Parameter(Mandatory)][string]$OuterKey,
        [Parameter(Mandatory)][string]$InnerKey
    )

    $normalizedOuter = Get-NormalizedText $OuterKey
    $normalizedInner = Get-NormalizedText $InnerKey

    if (
        [string]::IsNullOrWhiteSpace($normalizedOuter) -or
        [string]::IsNullOrWhiteSpace($normalizedInner)
    ) {
        return
    }

    if (-not $Lookup.ContainsKey($normalizedOuter)) {
        $Lookup[$normalizedOuter] = @{}
    }

    $Lookup[$normalizedOuter][$normalizedInner] = $true
}

function Get-IgnoredPresetLookup {
    param(
        [Parameter(Mandatory)]$Document,
        [string]$Section = 'IgnoredPresets'
    )

    $lookup = @{}
    $ignoredPresets = Get-IniSection `
        -Document $Document `
        -Name $Section

    foreach ($key in $ignoredPresets.Keys) {
        $left = ([string]$key).Trim()
        $right = ([string]$ignoredPresets[$key]).Trim()

        if ([string]::IsNullOrWhiteSpace($left)) {
            continue
        }

        if ($left.Contains('|')) {
            $parts = $left -split '\|', 2
            Add-LookupSetValue `
                -Lookup $lookup `
                -OuterKey $parts[0] `
                -InnerKey $parts[1]
        }
    }

    return ,$lookup
}

function Test-IgnoredPreset {
    param(
        [Parameter(Mandatory)]$Lookup,
        [Parameter(Mandatory)][string]$EffectName,
        [Parameter(Mandatory)][string]$PresetName
    )

    $normalizedEffectName = Get-NormalizedText $EffectName
    $normalizedPresetName = Get-NormalizedText $PresetName

    return (
        $Lookup.ContainsKey($normalizedEffectName) -and
        $Lookup[$normalizedEffectName].ContainsKey($normalizedPresetName)
    )
}

function Get-OrderedValues {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Section
    )

    $result = [Collections.ArrayList]::new()
    $values = Get-IniSection -Document $Document -Name $Section

    foreach ($key in $values.Keys) {
        $value = ([string]$values[$key]).Trim()

        if ($value.Length -gt 0) {
            [void]$result.Add($value)
        }
    }

    return ,$result
}

function Find-MatchingItemIndex {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string[]]$Properties
    )

    for ($index = 0; $index -lt $Items.Count; $index++) {
        foreach ($property in $Properties) {
            if (Test-SameText $Items[$index].$property $Value) {
                return $index
            }
        }
    }

    return -1
}

function Get-OrderedItems {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)]$ConfiguredOrder,
        [Parameter(Mandatory)][string[]]$MatchProperties,
        [Parameter(Mandatory)][string]$SortProperty
    )

    $remaining = [Collections.ArrayList]::new()
    $result = [Collections.ArrayList]::new()

    foreach ($item in $Items) {
        [void]$remaining.Add($item)
    }

    foreach ($configuredValue in $ConfiguredOrder) {
        $matchIndex = Find-MatchingItemIndex `
            -Items $remaining `
            -Value ([string]$configuredValue) `
            -Properties $MatchProperties

        if ($matchIndex -ge 0) {
            [void]$result.Add($remaining[$matchIndex])
            $remaining.RemoveAt($matchIndex)
        }
    }

    foreach ($item in @($remaining | Sort-Object -Property $SortProperty)) {
        [void]$result.Add($item)
    }

    return ,$result
}

function Get-MapValueForItem {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string[]]$Keys,
        [string]$Default = ''
    )

    foreach ($candidate in $Keys) {
        if ($Map.Contains($candidate)) {
            return [string]$Map[$candidate]
        }
    }

    return $Default
}

function Initialize-Models {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        Write-Utf8NoBom `
            -Path $script:ConfigPath `
            -Content ((New-DefaultConfigText).Trim() + "`r`n")
    }

    $script:ConfigDocument = Read-IniDocument -Path $script:ConfigPath

    if (-not $script:InventoryPathWasProvided) {
        $configuredInventoryPath = Get-IniValue `
            -Document $script:ConfigDocument `
            -Section 'Assets' `
            -Key 'InventoryFile' `
            -Default (
                Get-IniValue `
                    -Document $script:ConfigDocument `
                    -Section 'Integration' `
                    -Key 'InventoryFile' `
                    -Default 'data\inventory.ini'
            )

        if (-not [string]::IsNullOrWhiteSpace($configuredInventoryPath)) {
            $script:InventoryPath = Resolve-ProjectPath $configuredInventoryPath
        }
    }

    $script:InventoryDocument = Read-IniDocument -Path $script:InventoryPath

    $ignoredEffects = Get-EnabledKeySet `
        -Document $script:ConfigDocument `
        -Section 'IgnoredEffects'

    $favoriteEffects = Get-EnabledKeySet `
        -Document $script:ConfigDocument `
        -Section 'FavoriteEffects'

    $effectLayouts = Get-IniSection `
        -Document $script:ConfigDocument `
        -Name 'EffectLayouts'

    $effectStatus = Get-IniSection `
        -Document $script:InventoryDocument `
        -Name 'EffectInventoryStatus'

    $effectItems = [Collections.ArrayList]::new()
    $inventoryEffects = Get-IniSection `
        -Document $script:InventoryDocument `
        -Name 'Effects'

    $ignoredPresets = Get-IgnoredPresetLookup `
        -Document $script:ConfigDocument

    $favoritePresets = Get-IgnoredPresetLookup `
        -Document $script:ConfigDocument `
        -Section 'FavoritePresets'

    foreach ($effectId in $inventoryEffects.Keys) {
        if ([string]$effectId -match '[\[\]\r\n]') {
            continue
        }

        $effectName = [string]$inventoryEffects[$effectId]
        $presetSectionName = 'Presets.' + $effectId
        $presetStatusSectionName = 'PresetInventoryStatus.' + $effectId
        $presetValues = Get-IniSection `
            -Document $script:InventoryDocument `
            -Name $presetSectionName

        $presetStatus = Get-IniSection `
            -Document $script:InventoryDocument `
            -Name $presetStatusSectionName

        $presetItems = [Collections.ArrayList]::new()

        foreach ($presetKey in $presetValues.Keys) {
            $presetName = [string]$presetValues[$presetKey]

            [void]$presetItems.Add([pscustomobject]@{
                Key = [string]$presetKey
                Name = $presetName
                Status = Get-MapValueForItem `
                    -Map $presetStatus `
                    -Keys @([string]$presetKey) `
                    -Default 'Present'
                Ignored = Test-IgnoredPreset `
                    -Lookup $ignoredPresets `
                    -EffectName $effectName `
                    -PresetName $presetName
                Favorite = Test-IgnoredPreset `
                    -Lookup $favoritePresets `
                    -EffectName $effectName `
                    -PresetName $presetName
            })
        }

        $presetOrder = Get-OrderedValues `
            -Document $script:ConfigDocument `
            -Section ('PresetOrder.' + $effectName)

        $orderedPresets = Get-OrderedItems `
            -Items $presetItems `
            -ConfiguredOrder $presetOrder `
            -MatchProperties @('Name') `
            -SortProperty 'Name'

        $normalizedId = Get-NormalizedText $effectId
        $normalizedName = Get-NormalizedText $effectName
        $status = Get-MapValueForItem `
            -Map $effectStatus `
            -Keys @([string]$effectId) `
            -Default 'Present'

        if (Test-SameText $status 'Present-Unusable') {
            continue
        }

        [void]$effectItems.Add([pscustomobject]@{
            Id = [string]$effectId
            Name = $effectName
            Status = $status
            Ignored = (
                $ignoredEffects.ContainsKey($normalizedName)
            )
            Favorite = (
                $favoriteEffects.ContainsKey($normalizedName)
            )
            Layout = Get-MapValueForItem `
                -Map $effectLayouts `
                -Keys @($effectName)
            Presets = $orderedPresets
            IsExpanded = $false
        })
    }

    $effectOrder = Get-OrderedValues `
        -Document $script:ConfigDocument `
        -Section 'EffectOrder'

    $script:Effects = Get-OrderedItems `
        -Items $effectItems `
        -ConfiguredOrder $effectOrder `
        -MatchProperties @('Id', 'Name') `
        -SortProperty 'Name'
    $script:LoadedCustomEffectOrderSnapshot = @(Get-EffectOrderKeys)
    $script:OwnCustomEffectOrderSnapshot = $null

    $ignoredLayouts = Get-EnabledKeySet `
        -Document $script:ConfigDocument `
        -Section 'IgnoredLayouts'

    $favoriteLayouts = Get-EnabledKeySet `
        -Document $script:ConfigDocument `
        -Section 'FavoriteLayouts'

    $layoutStatus = Get-IniSection `
        -Document $script:InventoryDocument `
        -Name 'LayoutInventoryStatus'

    $layoutItems = [Collections.ArrayList]::new()
    $inventoryLayouts = Get-IniSection `
        -Document $script:InventoryDocument `
        -Name 'Layouts'

    foreach ($layoutKey in $inventoryLayouts.Keys) {
        $layoutName = [string]$inventoryLayouts[$layoutKey]

        [void]$layoutItems.Add([pscustomobject]@{
            Key = [string]$layoutKey
            Name = $layoutName
            Status = Get-MapValueForItem `
                -Map $layoutStatus `
                -Keys @([string]$layoutKey) `
                -Default 'Present'
            Ignored = $ignoredLayouts.ContainsKey(
                (Get-NormalizedText $layoutName)
            )
            Favorite = $favoriteLayouts.ContainsKey(
                (Get-NormalizedText $layoutName)
            )
        })
    }

    $layoutOrder = Get-OrderedValues `
        -Document $script:ConfigDocument `
        -Section 'LayoutOrder'

    $script:Layouts = Get-OrderedItems `
        -Items $layoutItems `
        -ConfiguredOrder $layoutOrder `
        -MatchProperties @('Name') `
        -SortProperty 'Name'
}

function ConvertFrom-XamlString {
    param(
        [Parameter(Mandatory)]
        [string]$Xaml
    )

    $stringReader = [IO.StringReader]::new($Xaml)
    $xmlReader = [Xml.XmlReader]::Create($stringReader)

    try {
        return [Windows.Markup.XamlReader]::Load($xmlReader)
    }
    finally {
        $xmlReader.Dispose()
        $stringReader.Dispose()
    }
}

function Import-WindowXaml {
    if (-not (Test-Path -LiteralPath $script:XamlPath -PathType Leaf)) {
        throw "The WPF layout file was not found: $($script:XamlPath)"
    }

    $stream = [IO.File]::OpenRead($script:XamlPath)

    try {
        return [Windows.Markup.XamlReader]::Load($stream)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-UiElement {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $element = $script:Window.FindName($Name)

    if ($null -eq $element) {
        throw "The WPF element '$Name' was not found."
    }

    return $element
}

function Set-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [ValidateSet('Normal', 'Accent', 'Error')]
        [string]$Kind = 'Normal'
    )

    if (
        $null -ne $script:StatusResetTimer
    ) {
        $script:StatusResetTimer.Stop()
    }

    $script:StatusText.Text = $Text

    switch ($Kind) {
        'Accent' {
            $script:StatusText.Foreground = $script:AccentBrush
        }
        'Error' {
            $script:StatusText.Foreground = $script:ErrorBrush
        }
        default {
            $script:StatusText.Foreground = $script:DimBrush
        }
    }

    if (Test-IsBaselineStatus $Text) {
        return
    }

    if ($Text.EndsWith('...')) {
        return
    }

    if ($null -eq $script:StatusResetTimer) {
        $script:StatusResetTimer = [Windows.Threading.DispatcherTimer]::new()
        $script:StatusResetTimer.Interval = [TimeSpan]::FromSeconds(4)
        $script:StatusResetTimer.Add_Tick({
            $script:StatusResetTimer.Stop()

            if (-not (Test-IsBaselineStatus ([string]$script:StatusText.Text))) {
                Restore-BaselineStatus
            }
        })
    }

    $script:StatusResetTimer.Start()
}

function Test-IsBaselineStatus {
    param([AllowEmptyString()][string]$Text)

    return (Test-SameText $Text 'Showing current') -or
        (Test-SameText $Text 'Unsaved changes')
}

function Restore-BaselineStatus {
    if ($script:IsDirty) {
        Set-Status -Text 'Unsaved changes' -Kind Accent
        return
    }

    Set-Status -Text 'Showing current' -Kind Normal
}

function Set-SavedStatus {
    Set-Status -Text 'Saved changes.' -Kind Accent
}

function Get-EditorStateSignature {
    $defaultLayout = if (
        $null -ne $script:DefaultLayoutComboBox -and
        $script:DefaultLayoutComboBox.SelectedIndex -gt 0
    ) {
        [string]$script:DefaultLayoutComboBox.SelectedItem
    }
    else {
        ''
    }

    $state = [ordered]@{
        Hotkeys = [ordered]@{}
        Behavior = [ordered]@{
            LaunchOnStartup = [bool]$script:LaunchOnStartupToggle.IsChecked
            AutoUpdateInventory = [bool]$script:AutoUpdateInventoryToggle.IsChecked
            AutoUpdateInventoryInterval = [string]$script:AutoUpdateInventoryIntervalTextBox.Text
            ShowHotkeyNotifications = [bool]$script:ShowHotkeyNotificationsToggle.IsChecked
            Logging = [bool]$script:LoggingToggle.IsChecked
            WatchExternalEffectChanges = [bool]$script:WatchExternalEffectChangesToggle.IsChecked
            ApplyPoliciesOnStartup = [bool]$script:ApplyPoliciesOnStartupToggle.IsChecked
            RememberLastActiveEffectPreset = [bool]$script:RememberLastActiveEffectPresetToggle.IsChecked
            ExcludeFromPickers = [bool]$script:ExcludeFromPickersToggle.IsChecked
            ExcludeFromNextHotkeys = [bool]$script:ExcludeFromNextHotkeysToggle.IsChecked
            ExcludeFromCycling = [bool]$script:ExcludeFromCyclingToggle.IsChecked
            PresetOnEffectActivation = $(if ($script:PresetPreferredRadio.IsChecked) { 'Preferred' } else { 'LastUsed' })
            UnassignedEffectLayoutMode = $(if ($script:UseDefaultLayoutRadio.IsChecked) { 'DefaultLayout' } else { 'Current' })
            DefaultLayout = $defaultLayout
        }
        Cycling = [ordered]@{
            EffectCyclingEnabled = [bool]$script:EffectCyclingEnabledToggle.IsChecked
            EffectCyclingMode = Get-SelectedEffectCyclingMode
            EffectCyclingInterval = [string]$script:EffectCyclingIntervalTextBox.Text
            CycleEffectOnceAllPresetsElapsed = [bool]$script:CycleEffectOnceAllPresetsElapsedToggle.IsChecked
            PresetCyclingEnabled = [bool]$script:PresetCyclingEnabledToggle.IsChecked
            PresetCyclingMode = Get-SelectedPresetCyclingMode
            PresetCyclingInterval = [string]$script:PresetCyclingIntervalTextBox.Text
        }
        Assets = [ordered]@{
            InventoryFile = [string]$script:InventoryFileTextBox.Text
            UpdaterScript = [string]$script:UpdaterScriptTextBox.Text
        }
        Effects = @(
            foreach ($effect in $script:Effects) {
                [ordered]@{
                    Key = Get-EffectConfigKey -Effect $effect
                    Layout = [string]$effect.Layout
                    Ignored = [bool]$effect.Ignored
                    Favorite = [bool]$effect.Favorite
                    Presets = @(
                        foreach ($preset in $effect.Presets) {
                            [ordered]@{
                                Name = [string]$preset.Name
                                Ignored = [bool]$preset.Ignored
                                Favorite = [bool]$preset.Favorite
                            }
                        }
                    )
                }
            }
        )
        Layouts = @(
            foreach ($layout in $script:Layouts) {
                [ordered]@{
                    Name = [string]$layout.Name
                    Ignored = [bool]$layout.Ignored
                    Favorite = [bool]$layout.Favorite
                }
            }
        )
    }

    $hotkeyControls = Get-HotkeyControls

    foreach ($key in $hotkeyControls.Keys) {
        $state.Hotkeys[$key] = [string]$hotkeyControls[$key].Tag
    }

    return ($state | ConvertTo-Json -Depth 8 -Compress)
}

function Update-DirtyState {
    if ($script:IsInitializing) {
        return
    }

    $script:IsDirty = (Get-EditorStateSignature) -ne $script:InitialStateSignature

    if ($script:IsDirty) {
        Set-Status -Text 'Unsaved changes' -Kind Accent
    }
    else {
        Set-Status -Text 'Showing current' -Kind Normal
    }
}

function Set-Dirty {
    if ($script:IsInitializing) {
        return
    }

    Update-DirtyState
}

function New-EmptyStateText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $message = [Windows.Controls.TextBlock]::new()
    $message.Text = $Text
    $message.Foreground = $script:MutedBrush
    $message.FontSize = 12
    $message.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $message.Margin = [Windows.Thickness]::new(16, 36, 16, 0)

    return $message
}

function Remove-DropRowsForKind {
    param(
        [Parameter(Mandatory)]
        [string[]]$Kinds
    )

    $kept = [Collections.ArrayList]::new()

    foreach ($row in $script:DropRows) {
        if ($Kinds -notcontains [string]$row.Kind) {
            [void]$kept.Add($row)
        }
    }

    $script:DropRows = $kept
}

function Clear-DropIndicators {
    foreach ($row in $script:DropRows) {
        $row.TopLine.Background = $script:TransparentBrush
        $row.BottomLine.Background = $script:TransparentBrush
    }

    $script:ActiveDropIndicatorKey = ''
}

function Show-DropIndicator {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][bool]$InsertAfter
    )

    $insertIndex = [int]$Target.Index

    if ($InsertAfter) {
        $insertIndex++
    }

    $indicatorKey = (
        [string]$Target.Kind + '|' +
        [string]$Target.EffectId + '|' +
        [string]$insertIndex
    )

    if ($script:ActiveDropIndicatorKey -eq $indicatorKey) {
        return
    }

    Clear-DropIndicators
    $script:ActiveDropIndicatorKey = $indicatorKey

    $matchingRows = @(
        $script:DropRows |
        Where-Object {
            $_.Kind -eq $Target.Kind -and
            $_.EffectId -eq $Target.EffectId
        }
    )

    $nextRow = $matchingRows |
        Where-Object { [int]$_.Index -eq $insertIndex } |
        Select-Object -First 1

    if ($null -ne $nextRow) {
        $nextRow.TopLine.Background = $script:AccentBrush
        return
    }

    $lastRow = $matchingRows |
        Sort-Object -Property Index |
        Select-Object -Last 1

    if ($null -ne $lastRow) {
        $lastRow.BottomLine.Background = $script:AccentBrush
    }
}

function Get-DragFormat {
    param(
        [Parameter(Mandatory)]
        [string]$Kind
    )

    switch ($Kind) {
        'Effect' { return 'SignalRGB.ConfigEditor.EffectOrder' }
        'Preset' { return 'SignalRGB.ConfigEditor.PresetOrder' }
        'Layout' { return 'SignalRGB.ConfigEditor.LayoutOrder' }
        default { throw "Unsupported drag item kind: $Kind" }
    }
}

function Get-ScrollViewerForDragKind {
    param([Parameter(Mandatory)][string]$Kind)

    if ($Kind -eq 'Layout') {
        return $script:LayoutsScrollViewer
    }

    return $script:EffectsScrollViewer
}

function Invoke-DragAutoScroll {
    param(
        [Parameter(Mandatory)]$ScrollViewer,
        [Parameter(Mandatory)]$EventArgs
    )

    if ($null -eq $ScrollViewer -or $ScrollViewer.ActualHeight -le 0) {
        return
    }

    $position = $EventArgs.GetPosition($ScrollViewer)
    $threshold = [Math]::Min(58, [Math]::Max(30, $ScrollViewer.ActualHeight / 5))
    $offset = [double]$ScrollViewer.VerticalOffset
    $maxOffset = [double]$ScrollViewer.ScrollableHeight
    $step = 0.0

    if ($position.Y -lt $threshold) {
        $distance = [Math]::Max(0, $threshold - $position.Y)
        $step = -[Math]::Max(3, [Math]::Ceiling(($distance / $threshold) * 24))
    }
    elseif ($position.Y -gt ($ScrollViewer.ActualHeight - $threshold)) {
        $distance = [Math]::Max(
            0,
            $position.Y - ($ScrollViewer.ActualHeight - $threshold)
        )
        $step = [Math]::Max(3, [Math]::Ceiling(($distance / $threshold) * 24))
    }

    if ($step -eq 0) {
        return
    }

    $nextOffset = [Math]::Max(0, [Math]::Min($maxOffset, $offset + $step))

    if ([Math]::Abs($nextOffset - $offset) -ge 0.5) {
        $ScrollViewer.ScrollToVerticalOffset($nextOffset)
    }
}

function Register-DragAutoScrollSupport {
    foreach ($entry in @(
        [pscustomobject]@{
            ScrollViewer = $script:EffectsScrollViewer
            Kinds = @('Effect', 'Preset')
        },
        [pscustomobject]@{
            ScrollViewer = $script:LayoutsScrollViewer
            Kinds = @('Layout')
        }
    )) {
        $scrollViewer = $entry.ScrollViewer

        if ($null -eq $scrollViewer) {
            continue
        }

        $scrollViewer.AllowDrop = $true
        $scrollViewer.Tag = $entry.Kinds
        $scrollViewer.Add_PreviewDragOver({
            param($sender, $eventArgs)

            foreach ($kind in @($sender.Tag)) {
                $format = Get-DragFormat -Kind ([string]$kind)

                if ($eventArgs.Data.GetDataPresent($format)) {
                    Invoke-DragAutoScroll `
                        -ScrollViewer $sender `
                        -EventArgs $eventArgs
                    break
                }
            }
        })
    }
}

function Register-DragHandle {
    param(
        [Parameter(Mandatory)]$Handle,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$ItemKey,
        [string]$EffectId = ''
    )

    $Handle.Tag = [pscustomobject]@{
        Kind = $Kind
        ItemKey = $ItemKey
        EffectId = $EffectId
    }

    $Handle.Cursor = [Windows.Input.Cursors]::SizeAll

    $Handle.Add_PreviewMouseLeftButtonDown({
        param($sender, $eventArgs)

        $script:DragStartPoint = $eventArgs.GetPosition($script:Window)
        $script:DragSource = $sender.Tag
    })

    $Handle.Add_PreviewMouseMove({
        param($sender, $eventArgs)

        if (
            [Windows.Input.Mouse]::LeftButton -ne
            [Windows.Input.MouseButtonState]::Pressed -or
            $null -eq $script:DragStartPoint -or
            $null -eq $script:DragSource
        ) {
            return
        }

        $currentPoint = $eventArgs.GetPosition($script:Window)
        $horizontalDistance = [Math]::Abs(
            $currentPoint.X - $script:DragStartPoint.X
        )
        $verticalDistance = [Math]::Abs(
            $currentPoint.Y - $script:DragStartPoint.Y
        )

        if (
            $horizontalDistance -lt [Windows.SystemParameters]::MinimumHorizontalDragDistance -and
            $verticalDistance -lt [Windows.SystemParameters]::MinimumVerticalDragDistance
        ) {
            return
        }

        $metadata = $sender.Tag
        $format = Get-DragFormat -Kind $metadata.Kind
        $payload = if ($metadata.Kind -eq 'Preset') {
            $metadata.EffectId + "`n" + $metadata.ItemKey
        }
        else {
            $metadata.ItemKey
        }

        $data = [Windows.DataObject]::new()
        $data.SetData($format, $payload)

        try {
            [void][Windows.DragDrop]::DoDragDrop(
                $sender,
                $data,
                [Windows.DragDropEffects]::Move
            )
        }
        finally {
            Clear-DropIndicators
            $script:DragStartPoint = $null
            $script:DragSource = $null
        }
    })
}

function Register-DragSurface {
    param(
        [Parameter(Mandatory)]$Surface,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$ItemKey,
        [string]$EffectId = ''
    )

    $Surface.Tag = [pscustomobject]@{
        Kind = $Kind
        ItemKey = $ItemKey
        EffectId = $EffectId
    }

    $Surface.Add_PreviewMouseLeftButtonDown({
        param($sender, $eventArgs)

        if (Test-IsInsideInteractiveElement $eventArgs.OriginalSource) {
            return
        }

        $script:DragStartPoint = $eventArgs.GetPosition($script:Window)
        $script:DragSource = $sender.Tag
    })

    $Surface.Add_PreviewMouseMove({
        param($sender, $eventArgs)

        if (
            [Windows.Input.Mouse]::LeftButton -ne
            [Windows.Input.MouseButtonState]::Pressed -or
            $null -eq $script:DragStartPoint -or
            $null -eq $script:DragSource
        ) {
            return
        }

        if (Test-IsInsideInteractiveElement $eventArgs.OriginalSource) {
            return
        }

        $currentPoint = $eventArgs.GetPosition($script:Window)
        $horizontalDistance = [Math]::Abs(
            $currentPoint.X - $script:DragStartPoint.X
        )
        $verticalDistance = [Math]::Abs(
            $currentPoint.Y - $script:DragStartPoint.Y
        )

        if (
            $horizontalDistance -lt [Windows.SystemParameters]::MinimumHorizontalDragDistance -and
            $verticalDistance -lt [Windows.SystemParameters]::MinimumVerticalDragDistance
        ) {
            return
        }

        $metadata = $sender.Tag
        $format = Get-DragFormat -Kind $metadata.Kind
        $payload = if ($metadata.Kind -eq 'Preset') {
            $metadata.EffectId + "`n" + $metadata.ItemKey
        }
        else {
            $metadata.ItemKey
        }

        $data = [Windows.DataObject]::new()
        $data.SetData($format, $payload)

        try {
            [void][Windows.DragDrop]::DoDragDrop(
                $sender,
                $data,
                [Windows.DragDropEffects]::Move
            )
        }
        finally {
            Clear-DropIndicators
            $script:DragStartPoint = $null
            $script:DragSource = $null
        }
    })
}

function Get-ListForDropKind {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [string]$EffectId = ''
    )

    switch ($Kind) {
        'Effect' {
            return ,$script:Effects
        }
        'Layout' {
            return ,$script:Layouts
        }
        'Preset' {
            foreach ($effect in $script:Effects) {
                if (Test-SameText $effect.Id $EffectId) {
                    return ,$effect.Presets
                }
            }
        }
    }

    return $null
}

function Get-ItemKeyForKind {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Kind
    )

    switch ($Kind) {
        'Effect' { return [string]$Item.Id }
        'Layout' { return [string]$Item.Name }
        'Preset' { return [string]$Item.Name }
    }
}

function Move-OrderedItem {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][int]$TargetIndex,
        [Parameter(Mandatory)][bool]$InsertAfter,
        [string]$EffectId = ''
    )

    $items = Get-ListForDropKind -Kind $Kind -EffectId $EffectId

    if ($null -eq $items -or $items.Count -lt 2) {
        return
    }

    $sourceIndex = -1

    for ($index = 0; $index -lt $items.Count; $index++) {
        if (Test-SameText (Get-ItemKeyForKind $items[$index] $Kind) $SourceKey) {
            $sourceIndex = $index
            break
        }
    }

    if ($sourceIndex -lt 0) {
        return
    }

    $insertIndex = $TargetIndex

    if ($InsertAfter) {
        $insertIndex++
    }

    if ($sourceIndex -lt $insertIndex) {
        $insertIndex--
    }

    $insertIndex = [Math]::Max(0, [Math]::Min($insertIndex, $items.Count - 1))

    if ($insertIndex -eq $sourceIndex) {
        return
    }

    $movingItem = $items[$sourceIndex]
    $items.RemoveAt($sourceIndex)
    $items.Insert($insertIndex, $movingItem)
    Set-Dirty

    switch ($Kind) {
        'Effect' { Refresh-EffectsView }
        'Layout' { Refresh-LayoutsView }
        'Preset' { Refresh-EffectsView }
    }
}

function Register-DropTarget {
    param(
        [Parameter(Mandatory)]$Wrapper,
        [Parameter(Mandatory)]$TopLine,
        [Parameter(Mandatory)]$BottomLine,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][int]$Index,
        [string]$EffectId = ''
    )

    $metadata = [pscustomobject]@{
        Kind = $Kind
        Index = $Index
        EffectId = $EffectId
        TopLine = $TopLine
        BottomLine = $BottomLine
    }

    $Wrapper.Tag = $metadata
    $Wrapper.AllowDrop = $true
    [void]$script:DropRows.Add($metadata)

    $Wrapper.Add_DragOver({
        param($sender, $eventArgs)

        $target = $sender.Tag
        $format = Get-DragFormat -Kind $target.Kind

        if (-not $eventArgs.Data.GetDataPresent($format)) {
            $eventArgs.Effects = [Windows.DragDropEffects]::None
            return
        }

        if ($target.Kind -eq 'Preset') {
            $payloadParts = ([string]$eventArgs.Data.GetData($format)) -split "`n", 2

            if (
                $payloadParts.Count -ne 2 -or
                -not (Test-SameText $payloadParts[0] $target.EffectId)
            ) {
                $eventArgs.Effects = [Windows.DragDropEffects]::None
                return
            }
        }

        Invoke-DragAutoScroll `
            -ScrollViewer (Get-ScrollViewerForDragKind -Kind $target.Kind) `
            -EventArgs $eventArgs

        $position = $eventArgs.GetPosition($sender)
        Show-DropIndicator `
            -Target $target `
            -InsertAfter ($position.Y -ge ($sender.ActualHeight / 2))

        $eventArgs.Effects = [Windows.DragDropEffects]::Move
        $eventArgs.Handled = $true
    })

    $Wrapper.Add_Drop({
        param($sender, $eventArgs)

        $target = $sender.Tag
        $format = Get-DragFormat -Kind $target.Kind

        if (-not $eventArgs.Data.GetDataPresent($format)) {
            return
        }

        $payload = [string]$eventArgs.Data.GetData($format)
        $sourceKey = $payload

        if ($target.Kind -eq 'Preset') {
            $parts = $payload -split "`n", 2

            if (
                $parts.Count -ne 2 -or
                -not (Test-SameText $parts[0] $target.EffectId)
            ) {
                return
            }

            $sourceKey = $parts[1]
        }

        $position = $eventArgs.GetPosition($sender)

        Move-OrderedItem `
            -Kind $target.Kind `
            -SourceKey $sourceKey `
            -TargetIndex $target.Index `
            -InsertAfter ($position.Y -ge ($sender.ActualHeight / 2)) `
            -EffectId $target.EffectId

        $eventArgs.Handled = $true
    })
}

function Set-IgnoredTextTone {
    param(
        [Parameter(Mandatory)]$TextBlock,
        [Parameter(Mandatory)][bool]$Ignored
    )

    if ($Ignored) {
        $TextBlock.Foreground = $script:MutedBrush
        $TextBlock.Opacity = 0.62
        return
    }

    $TextBlock.Foreground = $script:TextBrush
    $TextBlock.Opacity = 1.0
}

function Get-ActiveStatusDisplayValue {
    param([AllowEmptyString()][string]$Value)

    $text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return '—'
    }

    return $text
}

function Update-ActiveSignalRgbStatus {
    if (
        $null -eq $script:ActiveEffectValueText -or
        $null -eq $script:ActivePresetValueText -or
        $null -eq $script:ActiveLayoutValueText
    ) {
        return
    }

    $selected = Get-SignalRgbSelectedEffect
    $presetName = Get-SignalRgbCurrentPreset -EffectId $selected.Id
    $layoutName = Get-SignalRgbCurrentLayout

    $script:ActiveEffectValueText.Text = Get-ActiveStatusDisplayValue $selected.Name
    $script:ActivePresetValueText.Text = Get-ActiveStatusDisplayValue $presetName
    $script:ActiveLayoutValueText.Text = Get-ActiveStatusDisplayValue $layoutName
}

function Start-ActiveStatusPolling {
    if ($null -eq $script:ActiveStatusTimer) {
        $script:ActiveStatusTimer = [Windows.Threading.DispatcherTimer]::new()
        $script:ActiveStatusTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:ActiveStatusTimer.Add_Tick({
            Update-ActiveSignalRgbStatus
        })
    }

    Update-ActiveSignalRgbStatus
    $script:ActiveStatusTimer.Start()
}

function Stop-ActiveStatusPolling {
    if ($null -ne $script:ActiveStatusTimer) {
        $script:ActiveStatusTimer.Stop()
    }
}

function Set-FavoriteButtonState {
    param(
        [Parameter(Mandatory)]$Button,
        [Parameter(Mandatory)][bool]$IsFavorite
    )

    if ($IsFavorite) {
        $Button.Content = [string][char]0x2605
        $Button.Foreground = $script:AccentBrush
        $Button.ToolTip = 'Remove from favorites'
    }
    else {
        $Button.Content = [string][char]0x2606
        $Button.Foreground = $script:DimBrush
        $Button.ToolTip = 'Add to favorites'
    }
}

function Register-FavoriteButton {
    param(
        [Parameter(Mandatory)]$Button,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][ValidateSet('Effect', 'Preset', 'Layout')][string]$Kind
    )

    Set-FavoriteButtonState -Button $Button -IsFavorite ([bool]$Item.Favorite)
    $Button.Tag = $Item
    $Button.Add_Click({
        param($clickSender)
        $target = $clickSender.Tag
        $target.Favorite = -not [bool]$target.Favorite
        Set-FavoriteButtonState -Button $clickSender -IsFavorite ([bool]$target.Favorite)
        Set-Dirty

        if (
            $Kind -ne 'Layout' -and
            [bool]$script:EffectsFilterFavorites
        ) {
            Refresh-EffectsView
        }
    }.GetNewClosure())
}

function Confirm-EditorReset {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string]$ConfirmLabel = 'Reset'
    )

    $result = Show-ThemedChoiceDialog `
        -Title $Title `
        -Message $Message `
        -Buttons @(
            [pscustomobject]@{ Label = 'Cancel'; Value = 'Cancel' },
            [pscustomobject]@{ Label = $ConfirmLabel; Value = 'Reset'; Danger = $true }
        ) `
        -AccentButton ''

    return $result -eq 'Reset'
}

function Complete-EditorResetSave {
    param([Parameter(Mandatory)][string]$SuccessText)

    if (Save-Configuration -RestartAhk) {
        Set-Status -Text $SuccessText -Kind Accent
    }
}

function Test-IsInsideInteractiveElement {
    param([AllowNull()]$Element)

    $current = $Element

    while ($null -ne $current) {
        if (
            $current -is [Windows.Controls.Primitives.ButtonBase] -or
            $current -is [Windows.Controls.TextBox] -or
            $current -is [Windows.Controls.ComboBox]
        ) {
            return $true
        }

        if (
            $current -is [Windows.FrameworkElement] -and
            [string]$current.Name -eq 'DragHandle'
        ) {
            return $true
        }

        if ($current -eq $script:Window) {
            break
        }

        try {
            $current = [Windows.Media.VisualTreeHelper]::GetParent($current)
        }
        catch {
            break
        }
    }

    return $false
}

function Toggle-EffectExpansion {
    param(
        [Parameter(Mandatory)]$Effect,
        [Parameter(Mandatory)]$ExpandedPanel
    )

    $Effect.IsExpanded = -not [bool]$Effect.IsExpanded

    if ($Effect.IsExpanded) {
        $ExpandedPanel.Visibility = [Windows.Visibility]::Visible
    }
    else {
        $ExpandedPanel.Visibility = [Windows.Visibility]::Collapsed
    }
}

function ConvertTo-SignalRgbUriText {
    param([AllowEmptyString()][string]$Text)

    return [Uri]::EscapeDataString(([string]$Text).Trim())
}

function Get-SignalRgbSelectedEffect {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'SOFTWARE\WhirlwindFX\SignalRgb\effects\selected',
        $false
    )

    if ($null -eq $key) {
        return [pscustomobject]@{
            Id = ''
            Name = ''
        }
    }

    try {
        return [pscustomobject]@{
            Id = [string]$key.GetValue('id', '')
            Name = [string]$key.GetValue('name', '')
        }
    }
    finally {
        $key.Close()
    }
}

function Get-SignalRgbCurrentPreset {
    param([AllowEmptyString()][string]$EffectId)

    if ([string]::IsNullOrWhiteSpace($EffectId)) {
        return ''
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        ('SOFTWARE\WhirlwindFX\SignalRgb\effects\' + $EffectId),
        $false
    )

    if ($null -eq $key) {
        return ''
    }

    try {
        return [string]$key.GetValue('current_preset', '')
    }
    finally {
        $key.Close()
    }
}

function Get-SignalRgbCurrentLayout {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'SOFTWARE\WhirlwindFX\SignalRgb\layouts',
        $false
    )

    if ($null -eq $key) {
        return ''
    }

    try {
        return [string]$key.GetValue('currentLayout', '')
    }
    finally {
        $key.Close()
    }
}

function Wait-ForUiCondition {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutMilliseconds = 12000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) {
            return $true
        }

        if ($null -ne $script:Window) {
            [void]$script:Window.Dispatcher.Invoke(
                [Windows.Threading.DispatcherPriority]::Background,
                [action]{}
            )
        }

        Start-Sleep -Milliseconds 100
    }

    return $false
}

function Invoke-SignalRgbUri {
    param([Parameter(Mandatory)][string]$Uri)

    Start-Process -FilePath $Uri | Out-Null
}

function Test-SignalRgbRunning {
    return $null -ne (
        Get-Process -Name 'SignalRgb' -ErrorAction SilentlyContinue |
            Select-Object -First 1
    )
}

function Set-RegistryValueTyped {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Key,
        [Parameter(Mandatory)][string]$Name,
        $Value,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryValueKind]$Kind
    )

    $Key.SetValue($Name, $Value, $Kind)
}

function Invoke-SignalRgbApplyEffect {
    param(
        [Parameter(Mandatory)][string]$EffectName,
        [AllowEmptyString()][string]$EffectId = ''
    )

    if (-not (Test-SignalRgbRunning)) {
        throw 'SignalRGB isn''t running.'
    }

    $uri = 'signalrgb://effect/apply/' + (ConvertTo-SignalRgbUriText $EffectName) + '?-silentlaunch-'
    Invoke-SignalRgbUri -Uri $uri

    $matched = Wait-ForUiCondition -TimeoutMilliseconds 12000 -Condition {
        $current = Get-SignalRgbSelectedEffect
        (
            -not [string]::IsNullOrWhiteSpace($EffectId) -and
            (Test-SameText $current.Id $EffectId)
        ) -or (
            Test-SameText $current.Name $EffectName
        )
    }

    if (-not $matched) {
        throw ('SignalRGB did not activate effect: ' + $EffectName)
    }
}

function Invoke-SignalRgbApplyLayout {
    param([Parameter(Mandatory)][string]$LayoutName)

    if (-not (Test-SignalRgbRunning)) {
        throw 'SignalRGB isn''t running.'
    }

    $uri = 'signalrgb://layout/apply/' + (ConvertTo-SignalRgbUriText $LayoutName) + '?-silentlaunch-'
    Invoke-SignalRgbUri -Uri $uri

    $matched = Wait-ForUiCondition -TimeoutMilliseconds 10000 -Condition {
        Test-SameText (Get-SignalRgbCurrentLayout) $LayoutName
    }

    if (-not $matched) {
        throw ('SignalRGB did not activate layout: ' + $LayoutName)
    }
}

function Invoke-SignalRgbApplyPreset {
    param(
        [Parameter(Mandatory)][string]$EffectName,
        [Parameter(Mandatory)][string]$EffectId,
        [Parameter(Mandatory)][string]$PresetName
    )

    if (-not (Test-SignalRgbRunning)) {
        throw 'SignalRGB isn''t running.'
    }

    if ([string]::IsNullOrWhiteSpace($EffectId)) {
        throw 'The effect id is missing for that preset.'
    }

    $currentEffect = Get-SignalRgbSelectedEffect
    if (
        -not (Test-SameText $currentEffect.Id $EffectId) -and
        -not (Test-SameText $currentEffect.Name $EffectName)
    ) {
        Invoke-SignalRgbApplyEffect -EffectName $EffectName -EffectId $EffectId
    }

    $statePath = 'SOFTWARE\WhirlwindFX\SignalRgb\states\' + $EffectId
    $effectPath = 'SOFTWARE\WhirlwindFX\SignalRgb\effects\' + $EffectId
    $stateKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($statePath, $true)
    $effectKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($effectPath, $true)

    if ($null -eq $stateKey) {
        throw 'The preset state key does not exist.'
    }

    if ($null -eq $effectKey) {
        $stateKey.Close()
        throw 'The effect registry key does not exist.'
    }

    $aliasName = 'A'
    $originalCurrentPreset = [string]$effectKey.GetValue('current_preset', '')
    $aliasNames = @($stateKey.GetValueNames())
    $aliasPreviouslyExisted = $false
    foreach ($name in $aliasNames) {
        if (Test-SameText $name $aliasName) {
            $aliasPreviouslyExisted = $true
            break
        }
    }

    $targetValue = $null
    $targetKind = [Microsoft.Win32.RegistryValueKind]::Unknown
    try {
        $targetValue = $stateKey.GetValue($PresetName)
        $targetKind = $stateKey.GetValueKind($PresetName)
    }
    catch {
        $stateKey.Close()
        $effectKey.Close()
        throw ('Preset not found: ' + $PresetName)
    }

    $aliasBackupValue = $null
    $aliasBackupKind = [Microsoft.Win32.RegistryValueKind]::Unknown
    if ($aliasPreviouslyExisted) {
        $aliasBackupValue = $stateKey.GetValue($aliasName)
        $aliasBackupKind = $stateKey.GetValueKind($aliasName)
    }

    $applicationSucceeded = $false

    try {
        Set-RegistryValueTyped -Key $stateKey -Name $aliasName -Value $targetValue -Kind $targetKind

        $uri = 'signalrgb://effect/applypreset/' +
            (ConvertTo-SignalRgbUriText $EffectName) + '/' +
            (ConvertTo-SignalRgbUriText $aliasName) +
            '?-silentlaunch-'
        Invoke-SignalRgbUri -Uri $uri

        $acknowledged = Wait-ForUiCondition -TimeoutMilliseconds 10000 -Condition {
            Test-SameText (Get-SignalRgbCurrentPreset -EffectId $EffectId) $aliasName
        }

        if (-not $acknowledged) {
            throw 'SignalRGB did not acknowledge the temporary preset alias.'
        }

        Start-Sleep -Milliseconds 150
        $effectKey.SetValue('current_preset', $PresetName, [Microsoft.Win32.RegistryValueKind]::String)
        $applicationSucceeded = $true
    }
    finally {
        try {
            if ($aliasPreviouslyExisted) {
                Set-RegistryValueTyped -Key $stateKey -Name $aliasName -Value $aliasBackupValue -Kind $aliasBackupKind
            }
            else {
                $stateKey.DeleteValue($aliasName, $false)
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 100

        try {
            if ($applicationSucceeded) {
                $effectKey.SetValue('current_preset', $PresetName, [Microsoft.Win32.RegistryValueKind]::String)
            }
            elseif (-not [string]::IsNullOrWhiteSpace($originalCurrentPreset)) {
                $effectKey.SetValue('current_preset', $originalCurrentPreset, [Microsoft.Win32.RegistryValueKind]::String)
            }
        }
        catch {
        }

        $stateKey.Close()
        $effectKey.Close()
    }

    if (-not $applicationSucceeded) {
        throw ('SignalRGB did not activate preset: ' + $PresetName)
    }
}

function Invoke-RowApply {
    param(
        [Parameter(Mandatory)][ValidateSet('Effect', 'Preset', 'Layout')][string]$Kind,
        [Parameter(Mandatory)][string]$DisplayName,
        [scriptblock]$Action
    )

    Set-Status -Text ('Applying ' + $DisplayName + '...') -Kind Accent

    try {
        & $Action
        Update-ActiveSignalRgbStatus
        Set-Status -Text ('Applied ' + $DisplayName) -Kind Accent
    }
    catch {
        Set-Status -Text $_.Exception.Message -Kind Error
    }
}

function New-PresetRow {
    param(
        [Parameter(Mandatory)]$Effect,
        [Parameter(Mandatory)]$Preset,
        [Parameter(Mandatory)][int]$Index
    )

    $xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="Transparent">
    <Grid.RowDefinitions>
        <RowDefinition Height="2" />
        <RowDefinition Height="38" />
        <RowDefinition Height="2" />
    </Grid.RowDefinitions>
    <Border x:Name="TopLine" Grid.Row="0" Background="Transparent" />
    <Grid x:Name="PresetSurface" Grid.Row="1" Margin="0,0,0,0">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="34" />
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <Border x:Name="DragHandle" Grid.Column="0" Cursor="SizeAll"
                ToolTip="Drag to reorder preset" Background="Transparent">
            <TextBlock Text="&#x22EE;&#x22EE;"
                       Foreground="{DynamicResource DimBrush}" FontSize="12"
                       VerticalAlignment="Center" HorizontalAlignment="Center" />
        </Border>
        <TextBlock x:Name="PresetNameText" Grid.Column="1" VerticalAlignment="Center"
                   FontSize="12" TextTrimming="CharacterEllipsis" />
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="IgnoreLabel" Text="Ignore" Foreground="{DynamicResource DimBrush}" FontSize="10"
                       Margin="0,0,7,0" VerticalAlignment="Center" />
            <ToggleButton x:Name="IgnoreToggle" Style="{DynamicResource ToggleSwitchStyle}" />
            <Button x:Name="ApplyButton" Content="Apply" Style="{DynamicResource SmallButtonStyle}"
                    MinWidth="46" Height="26" Padding="8,0" Margin="8,0,0,0"
                    VerticalAlignment="Center" ToolTip="Apply this preset now" />
            <Button x:Name="FavoriteButton" Style="{DynamicResource IconButtonStyle}"
                    Width="26" Height="26" Margin="4,0,0,0" Padding="0" FontSize="15"
                    VerticalAlignment="Center" />
        </StackPanel>
    </Grid>
    <Border x:Name="BottomLine" Grid.Row="2" Background="Transparent" />
</Grid>
'@

    $row = ConvertFrom-XamlString -Xaml $xaml
    $topLine = $row.FindName('TopLine')
    $bottomLine = $row.FindName('BottomLine')
    $presetSurface = $row.FindName('PresetSurface')
    $dragHandle = $row.FindName('DragHandle')
    $nameText = $row.FindName('PresetNameText')
    $ignoreLabel = $row.FindName('IgnoreLabel')
    $ignoreToggle = $row.FindName('IgnoreToggle')
    $applyButton = $row.FindName('ApplyButton')
    $favoriteButton = $row.FindName('FavoriteButton')

    $nameText.Text = $Preset.Name
    Set-IgnoredTextTone -TextBlock $nameText -Ignored ([bool]$Preset.Ignored)
    $ignoreToggle.IsChecked = [bool]$Preset.Ignored
    $ignoreToggle.Tag = [pscustomobject]@{
        EffectId = $Effect.Id
        Preset = $Preset
    }

    $ignoreToggle.ToolTip = 'Mark this preset as ignored for this effect'
    $showIgnore = ($Effect.Presets.Count -gt 1) -or [bool]$Preset.Ignored
    if (-not $showIgnore) {
        $ignoreLabel.Visibility = [Windows.Visibility]::Collapsed
        $ignoreToggle.Visibility = [Windows.Visibility]::Collapsed
    }

    $applyButton.Tag = [pscustomobject]@{
        Effect = $Effect
        Preset = $Preset
    }
    $applyButton.Add_Click({
        param($clickSender)
        $effect = $clickSender.Tag.Effect
        $preset = $clickSender.Tag.Preset
        Invoke-RowApply -Kind Preset -DisplayName $preset.Name -Action {
            Invoke-SignalRgbApplyPreset `
                -EffectName $effect.Name `
                -EffectId $effect.Id `
                -PresetName $preset.Name
        }.GetNewClosure()
    }.GetNewClosure())

    Register-FavoriteButton `
        -Button $favoriteButton `
        -Item $Preset `
        -Kind Preset

    $ignoreToggle.Add_Checked({
        param($sender)
        $sender.Tag.Preset.Ignored = $true
        Set-IgnoredTextTone -TextBlock $nameText -Ignored $true
        Set-Dirty
        Update-EffectsCount
    }.GetNewClosure())

    $ignoreToggle.Add_Unchecked({
        param($sender)
        $sender.Tag.Preset.Ignored = $false
        Set-IgnoredTextTone -TextBlock $nameText -Ignored $false
        Set-Dirty
        Update-EffectsCount
    }.GetNewClosure())

    Register-DragHandle `
        -Handle $dragHandle `
        -Kind 'Preset' `
        -ItemKey $Preset.Name `
        -EffectId $Effect.Id

    Register-DragSurface `
        -Surface $presetSurface `
        -Kind 'Preset' `
        -ItemKey $Preset.Name `
        -EffectId $Effect.Id

    Register-DropTarget `
        -Wrapper $row `
        -TopLine $topLine `
        -BottomLine $bottomLine `
        -Kind 'Preset' `
        -Index $Index `
        -EffectId $Effect.Id

    return $row
}

function New-EffectRow {
    param(
        [Parameter(Mandatory)]$Effect,
        [Parameter(Mandatory)][int]$Index
    )

    $xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="Transparent" Margin="0,0,0,6">
    <Grid.RowDefinitions>
        <RowDefinition Height="2" />
        <RowDefinition Height="Auto" />
        <RowDefinition Height="2" />
    </Grid.RowDefinitions>
    <Border x:Name="TopLine" Grid.Row="0" Background="Transparent" />
    <Border x:Name="RowCard" Grid.Row="1" CornerRadius="5">
        <Border.Style>
            <Style TargetType="Border">
                <Setter Property="Background" Value="{DynamicResource SurfaceBrush}" />
                <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}" />
                <Setter Property="BorderThickness" Value="1" />
                <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter Property="BorderBrush" Value="{DynamicResource AccentHoverBrush}" />
                    </Trigger>
                </Style.Triggers>
            </Style>
        </Border.Style>
        <StackPanel>
            <Grid x:Name="HeaderGrid" Height="48" Cursor="Hand" Background="Transparent">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="DragColumn" Width="34" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <Border x:Name="DragHandle" Grid.Column="0" Cursor="SizeAll"
                        ToolTip="Drag to reorder effect" Background="Transparent">
                    <TextBlock Text="&#x22EE;&#x22EE;"
                               Foreground="{DynamicResource DimBrush}" FontSize="13"
                               VerticalAlignment="Center" HorizontalAlignment="Center" />
                </Border>
                <TextBlock x:Name="EffectNameText" Grid.Column="1" VerticalAlignment="Center"
                           FontSize="12" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
                <TextBlock x:Name="PresetCountText" Grid.Column="2" VerticalAlignment="Center"
                           Foreground="{DynamicResource MutedBrush}" FontSize="10" Margin="8,0,10,0" />
                <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,10,0">
                    <TextBlock Text="Ignore" Foreground="{DynamicResource DimBrush}" FontSize="10"
                               Margin="0,0,7,0" VerticalAlignment="Center" />
                    <ToggleButton x:Name="IgnoreToggle" Style="{DynamicResource ToggleSwitchStyle}" />
                    <Button x:Name="ApplyButton" Content="Apply" Style="{DynamicResource SmallButtonStyle}"
                            MinWidth="46" Height="26" Padding="8,0" Margin="8,0,0,0"
                            VerticalAlignment="Center" ToolTip="Apply this effect now" />
                    <Button x:Name="FavoriteButton" Style="{DynamicResource IconButtonStyle}"
                            Width="26" Height="26" Margin="4,0,0,0" Padding="0" FontSize="15"
                            VerticalAlignment="Center" />
                </StackPanel>
            </Grid>
            <Border x:Name="ExpandedPanel" Visibility="Collapsed"
                    Background="#131318" BorderBrush="{DynamicResource BorderBrush}"
                    BorderThickness="0,1,0,0" Padding="10,9,10,9">
                <StackPanel>
                    <Grid Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="78" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="31" />
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="Layout" VerticalAlignment="Center"
                                   Foreground="{DynamicResource MutedBrush}" FontSize="11" />
                        <ComboBox x:Name="LayoutComboBox" Grid.Column="1" Height="32" />
                        <Button x:Name="ClearLayoutButton" Grid.Column="2" Content="x"
                                Style="{DynamicResource IconButtonStyle}" Margin="2,1,0,1"
                                ToolTip="Clear assigned layout" />
                    </Grid>
                    <TextBlock Text="Presets" Foreground="{DynamicResource MutedBrush}"
                               FontSize="11" FontWeight="SemiBold" Margin="0,2,0,6" />
                    <StackPanel x:Name="PresetsPanel" />
                </StackPanel>
            </Border>
        </StackPanel>
    </Border>
    <Border x:Name="BottomLine" Grid.Row="2" Background="Transparent" />
</Grid>
'@

    $row = ConvertFrom-XamlString -Xaml $xaml
    $topLine = $row.FindName('TopLine')
    $bottomLine = $row.FindName('BottomLine')
    $rowCard = $row.FindName('RowCard')
    $headerGrid = $row.FindName('HeaderGrid')
    $dragColumn = $row.FindName('DragColumn')
    $dragHandle = $row.FindName('DragHandle')
    $nameText = $row.FindName('EffectNameText')
    $presetCountText = $row.FindName('PresetCountText')
    $ignoreToggle = $row.FindName('IgnoreToggle')
    $applyButton = $row.FindName('ApplyButton')
    $favoriteButton = $row.FindName('FavoriteButton')
    $expandedPanel = $row.FindName('ExpandedPanel')
    $layoutComboBox = $row.FindName('LayoutComboBox')
    $clearLayoutButton = $row.FindName('ClearLayoutButton')
    $presetsPanel = $row.FindName('PresetsPanel')

    $nameText.Text = $Effect.Name
    $nameText.ToolTip = $Effect.Name
    Set-IgnoredTextTone -TextBlock $nameText -Ignored ([bool]$Effect.Ignored)
    $presetCountText.Text = '{0} preset{1}' -f @(
        $Effect.Presets.Count,
        $(if ($Effect.Presets.Count -eq 1) { '' } else { 's' })
    )
    $ignoreToggle.IsChecked = [bool]$Effect.Ignored
    $ignoreToggle.Tag = [pscustomobject]@{
        Effect = $Effect
        NameText = $nameText
    }
    $ignoreToggle.ToolTip = 'Mark this effect as ignored'
    $applyButton.Tag = $Effect
    $applyButton.Add_Click({
        param($clickSender)
        $effect = $clickSender.Tag
        Invoke-RowApply -Kind Effect -DisplayName $effect.Name -Action {
            Invoke-SignalRgbApplyEffect `
                -EffectName $effect.Name `
                -EffectId $effect.Id
        }.GetNewClosure()
    }.GetNewClosure())

    Register-FavoriteButton `
        -Button $favoriteButton `
        -Item $Effect `
        -Kind Effect

    if ($Effect.IsExpanded) {
        $expandedPanel.Visibility = [Windows.Visibility]::Visible
    }

    [void]$layoutComboBox.Items.Add('(No assigned layout)')

    foreach ($layout in $script:Layouts) {
        [void]$layoutComboBox.Items.Add($layout.Name)
    }

    $selectedLayoutIndex = 0

    if (-not [string]::IsNullOrWhiteSpace($Effect.Layout)) {
        for ($layoutIndex = 1; $layoutIndex -lt $layoutComboBox.Items.Count; $layoutIndex++) {
            if (Test-SameText $layoutComboBox.Items[$layoutIndex] $Effect.Layout) {
                $selectedLayoutIndex = $layoutIndex
                break
            }
        }
    }

    $layoutComboBox.SelectedIndex = $selectedLayoutIndex
    $layoutComboBox.Tag = $Effect
    $clearLayoutButton.Tag = [pscustomobject]@{
        Effect = $Effect
        ComboBox = $layoutComboBox
    }

    $ignoreToggle.Add_Checked({
        param($sender)
        $sender.Tag.Effect.Ignored = $true
        Set-IgnoredTextTone -TextBlock $sender.Tag.NameText -Ignored $true
        Set-Dirty
        Update-EffectsCount
    })

    $ignoreToggle.Add_Unchecked({
        param($sender)
        $sender.Tag.Effect.Ignored = $false
        Set-IgnoredTextTone -TextBlock $sender.Tag.NameText -Ignored $false
        Set-Dirty
        Update-EffectsCount
    })

    $headerGrid.Add_MouseLeftButtonUp({
        param($sender, $eventArgs)

        if (Test-IsInsideInteractiveElement $eventArgs.OriginalSource) {
            return
        }

        Toggle-EffectExpansion `
            -Effect $Effect `
            -ExpandedPanel $expandedPanel
        $eventArgs.Handled = $true
    }.GetNewClosure())

    $layoutComboBox.Add_SelectionChanged({
        param($sender)

        if ($script:IsInitializing -or $sender.SelectedIndex -lt 0) {
            return
        }

        $sender.Tag.Layout = if ($sender.SelectedIndex -eq 0) {
            ''
        }
        else {
            [string]$sender.SelectedItem
        }

        Set-Dirty
    })

    $clearLayoutButton.Add_Click({
        param($sender)
        $sender.Tag.Effect.Layout = ''
        $sender.Tag.ComboBox.SelectedIndex = 0
        Set-Dirty
    })

    for ($presetIndex = 0; $presetIndex -lt $Effect.Presets.Count; $presetIndex++) {
        [void]$presetsPanel.Children.Add(
            (New-PresetRow `
                -Effect $Effect `
                -Preset $Effect.Presets[$presetIndex] `
                -Index $presetIndex)
        )
    }

    if ($Effect.Presets.Count -eq 0) {
        [void]$presetsPanel.Children.Add(
            (New-EmptyStateText -Text 'No saved presets')
        )
    }

    if (Test-EffectsDragAllowed) {
        Register-DragHandle `
            -Handle $dragHandle `
            -Kind 'Effect' `
            -ItemKey $Effect.Id

        Register-DragSurface `
            -Surface $headerGrid `
            -Kind 'Effect' `
            -ItemKey $Effect.Id

        Register-DropTarget `
            -Wrapper $row `
            -TopLine $topLine `
            -BottomLine $bottomLine `
            -Kind 'Effect' `
            -Index $Index
    }
    else {
        $dragHandle.Visibility = [Windows.Visibility]::Collapsed
    }

    return $row
}

function New-LayoutRow {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][int]$Index
    )

    $xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="Transparent" Margin="0,0,0,6">
    <Grid.RowDefinitions>
        <RowDefinition Height="2" />
        <RowDefinition Height="48" />
        <RowDefinition Height="2" />
    </Grid.RowDefinitions>
    <Border x:Name="TopLine" Grid.Row="0" Background="Transparent" />
    <Border x:Name="RowCard" Grid.Row="1" CornerRadius="5">
        <Border.Style>
            <Style TargetType="Border">
                <Setter Property="Background" Value="{DynamicResource SurfaceBrush}" />
                <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}" />
                <Setter Property="BorderThickness" Value="1" />
                <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter Property="BorderBrush" Value="{DynamicResource AccentHoverBrush}" />
                    </Trigger>
                </Style.Triggers>
            </Style>
        </Border.Style>
        <Grid x:Name="LayoutSurface">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="36" />
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <Border x:Name="DragHandle" Grid.Column="0" Cursor="SizeAll"
                    ToolTip="Drag to reorder layout" Background="Transparent">
                <TextBlock Text="&#x22EE;&#x22EE;"
                           Foreground="{DynamicResource DimBrush}" FontSize="13"
                           VerticalAlignment="Center" HorizontalAlignment="Center" />
            </Border>
            <TextBlock x:Name="LayoutNameText" Grid.Column="1" VerticalAlignment="Center"
                       FontSize="12" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,10,0">
                <TextBlock Text="Ignore" Foreground="{DynamicResource DimBrush}" FontSize="10"
                           Margin="0,0,7,0" VerticalAlignment="Center" />
                <ToggleButton x:Name="IgnoreToggle" Style="{DynamicResource ToggleSwitchStyle}" />
                <Button x:Name="ApplyButton" Content="Apply" Style="{DynamicResource SmallButtonStyle}"
                        MinWidth="46" Height="26" Padding="8,0" Margin="8,0,0,0"
                        VerticalAlignment="Center" ToolTip="Apply this layout now" />
                <Button x:Name="FavoriteButton" Style="{DynamicResource IconButtonStyle}"
                        Width="26" Height="26" Margin="4,0,0,0" Padding="0" FontSize="15"
                        VerticalAlignment="Center" />
            </StackPanel>
        </Grid>
    </Border>
    <Border x:Name="BottomLine" Grid.Row="2" Background="Transparent" />
</Grid>
'@

    $row = ConvertFrom-XamlString -Xaml $xaml
    $topLine = $row.FindName('TopLine')
    $bottomLine = $row.FindName('BottomLine')
    $rowCard = $row.FindName('RowCard')
    $layoutSurface = $row.FindName('LayoutSurface')
    $dragHandle = $row.FindName('DragHandle')
    $nameText = $row.FindName('LayoutNameText')
    $ignoreToggle = $row.FindName('IgnoreToggle')
    $applyButton = $row.FindName('ApplyButton')
    $favoriteButton = $row.FindName('FavoriteButton')

    $nameText.Text = $Layout.Name
    $nameText.ToolTip = $Layout.Name
    Set-IgnoredTextTone -TextBlock $nameText -Ignored ([bool]$Layout.Ignored)
    $ignoreToggle.IsChecked = [bool]$Layout.Ignored
    $ignoreToggle.Tag = [pscustomobject]@{
        Layout = $Layout
        NameText = $nameText
    }
    $ignoreToggle.ToolTip = 'Mark this layout as ignored'
    $applyButton.Tag = $Layout
    $applyButton.Add_Click({
        param($clickSender)
        $layout = $clickSender.Tag
        Invoke-RowApply -Kind Layout -DisplayName $layout.Name -Action {
            Invoke-SignalRgbApplyLayout -LayoutName $layout.Name
        }.GetNewClosure()
    }.GetNewClosure())

    Register-FavoriteButton `
        -Button $favoriteButton `
        -Item $Layout `
        -Kind Layout

    $ignoreToggle.Add_Checked({
        param($sender)
        $sender.Tag.Layout.Ignored = $true
        Set-IgnoredTextTone -TextBlock $sender.Tag.NameText -Ignored $true
        Set-Dirty
        Update-LayoutsCount
    })

    $ignoreToggle.Add_Unchecked({
        param($sender)
        $sender.Tag.Layout.Ignored = $false
        Set-IgnoredTextTone -TextBlock $sender.Tag.NameText -Ignored $false
        Set-Dirty
        Update-LayoutsCount
    })

    Register-DragHandle `
        -Handle $dragHandle `
        -Kind 'Layout' `
        -ItemKey $Layout.Name

    Register-DragSurface `
        -Surface $layoutSurface `
        -Kind 'Layout' `
        -ItemKey $Layout.Name

    Register-DropTarget `
        -Wrapper $row `
        -TopLine $topLine `
        -BottomLine $bottomLine `
        -Kind 'Layout' `
        -Index $Index

    return $row
}

function Update-EffectsCount {
    $installedCount = @(
        $script:Effects |
        Where-Object { -not (Test-SameText $_.Status 'Missing') }
    ).Count

    $ignoredCount = @(
        $script:Effects |
        Where-Object { $_.Ignored }
    ).Count

    $script:EffectsCountText.Text = (
        '{0} installed  /  {1} ignored' -f
        $installedCount,
        $ignoredCount
    )
}

function Update-LayoutsCount {
    $installedCount = @(
        $script:Layouts |
        Where-Object { -not (Test-SameText $_.Status 'Missing') }
    ).Count

    $ignoredCount = @(
        $script:Layouts |
        Where-Object { $_.Ignored }
    ).Count

    $script:LayoutsCountText.Text = (
        '{0} installed  /  {1} ignored' -f
        $installedCount,
        $ignoredCount
    )
}

function Get-VisibleEffects {
    $effects = @($script:Effects)
    $assignmentFilterActive = (
        $script:EffectsFilterAssignedLayouts -or
        $script:EffectsFilterNoAssignedLayouts -or
        -not [string]::IsNullOrWhiteSpace($script:EffectsFilterSpecificLayout)
    )

    if ($assignmentFilterActive) {
        $effects = @(
            foreach ($effect in $effects) {
                $hasLayout = -not [string]::IsNullOrWhiteSpace([string]$effect.Layout)
                $matches = $false

                if ($script:EffectsFilterAssignedLayouts -and $hasLayout) {
                    $matches = $true
                }

                if ($script:EffectsFilterNoAssignedLayouts -and -not $hasLayout) {
                    $matches = $true
                }

                if (
                    -not [string]::IsNullOrWhiteSpace($script:EffectsFilterSpecificLayout) -and
                    (Test-SameText $effect.Layout $script:EffectsFilterSpecificLayout)
                ) {
                    $matches = $true
                }

                if ($matches) {
                    $effect
                }
            }
        )
    }

    if ([bool]$script:EffectsFilterFavorites) {
        $effects = @(
            $effects |
            Where-Object {
                [bool]$_.Favorite -or
                @($_.Presets | Where-Object { [bool]$_.Favorite }).Count -gt 0
            }
        )
    }

    switch ($script:EffectsFilterSort) {
        'A-Z' {
            $effects = @($effects | Sort-Object -Property Name)
        }
        'MostPresets' {
            $effects = @($effects | Sort-Object -Property @{ Expression = { $_.Presets.Count }; Descending = $true }, @{ Expression = { $_.Name }; Ascending = $true })
        }
        'LeastPresets' {
            $effects = @($effects | Sort-Object -Property @{ Expression = { $_.Presets.Count }; Ascending = $true }, @{ Expression = { $_.Name }; Ascending = $true })
        }
    }

    switch ($script:EffectsFilterIgnoredPlacement) {
        'First' {
            $effects = @(
                @($effects | Where-Object { [bool]$_.Ignored }) +
                @($effects | Where-Object { -not [bool]$_.Ignored })
            )
        }
        'Last' {
            $effects = @(
                @($effects | Where-Object { -not [bool]$_.Ignored }) +
                @($effects | Where-Object { [bool]$_.Ignored })
            )
        }
    }

    return $effects
}

function Get-EffectModelIndex {
    param([Parameter(Mandatory)]$Effect)

    for ($index = 0; $index -lt $script:Effects.Count; $index++) {
        if (Test-SameText $script:Effects[$index].Id $Effect.Id) {
            return $index
        }
    }

    return 0
}

function Test-EffectsFilterActive {
    return (
        -not (Test-SameText $script:EffectsFilterSort 'CustomOrder') -or
        $script:EffectsFilterAssignedLayouts -or
        $script:EffectsFilterNoAssignedLayouts -or
        -not [string]::IsNullOrWhiteSpace($script:EffectsFilterSpecificLayout) -or
        [bool]$script:EffectsFilterFavorites -or
        -not [string]::IsNullOrWhiteSpace($script:EffectsFilterIgnoredPlacement)
    )
}

function Test-EffectsDragAllowed {
    return -not (Test-EffectsFilterActive)
}

function Get-EffectOrderKeys {
    return ,@($script:Effects | ForEach-Object { [string]$_.Id })
}

function Restore-EffectsOrderByKeys {
    param([AllowNull()][object[]]$Keys)

    if ($null -eq $Keys -or $Keys.Count -eq 0) {
        return
    }

    $byId = @{}

    foreach ($effect in $script:Effects) {
        $byId[[string]$effect.Id] = $effect
    }

    $ordered = [Collections.ArrayList]::new()
    $used = @{}

    foreach ($key in $Keys) {
        $id = [string]$key

        if ($byId.ContainsKey($id) -and -not $used.ContainsKey($id)) {
            [void]$ordered.Add($byId[$id])
            $used[$id] = $true
        }
    }

    foreach ($effect in $script:Effects) {
        $id = [string]$effect.Id

        if (-not $used.ContainsKey($id)) {
            [void]$ordered.Add($effect)
        }
    }

    $script:Effects.Clear()

    foreach ($effect in $ordered) {
        $script:Effects.Add($effect)
    }
}

function Test-EffectOrderMatchesKeys {
    param([AllowNull()][object[]]$Keys)

    if ($null -eq $Keys -or $Keys.Count -ne $script:Effects.Count) {
        return $false
    }

    for ($index = 0; $index -lt $script:Effects.Count; $index++) {
        if (-not (Test-SameText $script:Effects[$index].Id ([string]$Keys[$index]))) {
            return $false
        }
    }

    return $true
}

function Update-EffectsFilterPanel {
    if ($null -eq $script:EffectsFilterPanel) {
        return
    }

    $script:IsUpdatingEffectsFilterUi = $true

    try {
        $script:EffectsFilterCustomOrderCheck.IsChecked = Test-SameText $script:EffectsFilterSort 'CustomOrder'
        $script:EffectsFilterAzCheck.IsChecked = Test-SameText $script:EffectsFilterSort 'A-Z'
        $script:EffectsFilterMostPresetsCheck.IsChecked = Test-SameText $script:EffectsFilterSort 'MostPresets'
        $script:EffectsFilterLeastPresetsCheck.IsChecked = Test-SameText $script:EffectsFilterSort 'LeastPresets'
        $script:EffectsFilterAssignedLayoutsCheck.IsChecked = [bool]$script:EffectsFilterAssignedLayouts
        $script:EffectsFilterSpecificLayoutCheck.IsChecked = -not [string]::IsNullOrWhiteSpace($script:EffectsFilterSpecificLayout)
        $script:EffectsFilterSpecificLayoutComboBox.IsEnabled = [bool]$script:EffectsFilterSpecificLayoutCheck.IsChecked
        $script:EffectsFilterNoAssignedLayoutsCheck.IsChecked = [bool]$script:EffectsFilterNoAssignedLayouts
        $script:EffectsFilterFavoritesCheck.IsChecked = [bool]$script:EffectsFilterFavorites
        $script:EffectsFilterIgnoredLastCheck.IsChecked = Test-SameText $script:EffectsFilterIgnoredPlacement 'Last'
        $script:EffectsFilterIgnoredFirstCheck.IsChecked = Test-SameText $script:EffectsFilterIgnoredPlacement 'First'
        $revertKeys = if ($null -ne $script:OwnCustomEffectOrderSnapshot) {
            @($script:OwnCustomEffectOrderSnapshot)
        }
        else {
            @($script:LoadedCustomEffectOrderSnapshot)
        }
        $script:EffectsFilterRevertOrderButton.IsEnabled =
            (Test-EffectsFilterActive) -or
            (
                $revertKeys.Count -gt 0 -and
                -not (Test-EffectOrderMatchesKeys -Keys $revertKeys)
            )

        $layoutIndex = 0

        if (-not [string]::IsNullOrWhiteSpace($script:EffectsFilterSpecificLayout)) {
            for ($index = 1; $index -lt $script:EffectsFilterSpecificLayoutComboBox.Items.Count; $index++) {
                if (Test-SameText $script:EffectsFilterSpecificLayoutComboBox.Items[$index] $script:EffectsFilterSpecificLayout) {
                    $layoutIndex = $index
                    break
                }
            }
        }

        $script:EffectsFilterSpecificLayoutComboBox.SelectedIndex = $layoutIndex
    }
    finally {
        $script:IsUpdatingEffectsFilterUi = $false
    }
}

function Apply-EffectFilterOrderIfNeeded {
    $visibleEffects = @(Get-VisibleEffects)

    if ($visibleEffects.Count -eq 0) {
        return
    }

    $visibleIds = @{}
    $ordered = [Collections.ArrayList]::new()

    foreach ($effect in $visibleEffects) {
        [void]$ordered.Add($effect)
        $visibleIds[[string]$effect.Id] = $true
    }

    $baseKeys = if ($null -ne $script:OwnCustomEffectOrderSnapshot) {
        @($script:OwnCustomEffectOrderSnapshot)
    }
    else {
        @(Get-EffectOrderKeys)
    }

    foreach ($id in $baseKeys) {
        foreach ($effect in $script:Effects) {
            if (
                (Test-SameText $effect.Id $id) -and
                -not $visibleIds.ContainsKey([string]$effect.Id)
            ) {
                [void]$ordered.Add($effect)
                $visibleIds[[string]$effect.Id] = $true
                break
            }
        }
    }

    foreach ($effect in $script:Effects) {
        if (-not $visibleIds.ContainsKey([string]$effect.Id)) {
            [void]$ordered.Add($effect)
        }
    }

    $script:Effects.Clear()

    foreach ($effect in $ordered) {
        $script:Effects.Add($effect)
    }
}

function Update-EffectsFilterState {
    param([bool]$AffectsSavedOrder = $false)

    Update-EffectsFilterPanel
    Refresh-EffectsView
}

function Close-EffectsFilterPanel {
    if ($script:EffectsFilterPanel.Visibility -eq [Windows.Visibility]::Visible) {
        $script:EffectsFilterPanel.Visibility = [Windows.Visibility]::Collapsed
    }

    if ($script:EffectsFilterDismissLayer.Visibility -eq [Windows.Visibility]::Visible) {
        $script:EffectsFilterDismissLayer.Visibility = [Windows.Visibility]::Collapsed
    }
}

function Open-EffectsFilterPanel {
    Update-EffectsFilterPanel
    $script:EffectsFilterDismissLayer.Visibility = [Windows.Visibility]::Visible
    $script:EffectsFilterPanel.Visibility = [Windows.Visibility]::Visible
}

function Set-EffectsAssignmentFilterMode {
    param([ValidateSet('Assigned', 'Specific', 'None', 'Off')]$Mode)

    switch ($Mode) {
        'Assigned' {
            $script:EffectsFilterAssignedLayouts = $true
            $script:EffectsFilterSpecificLayout = ''
            $script:EffectsFilterNoAssignedLayouts = $false
        }
        'Specific' {
            $script:EffectsFilterAssignedLayouts = $false
            $script:EffectsFilterNoAssignedLayouts = $false

            if ($script:EffectsFilterSpecificLayoutComboBox.SelectedIndex -le 0 -and $script:EffectsFilterSpecificLayoutComboBox.Items.Count -gt 1) {
                $script:EffectsFilterSpecificLayoutComboBox.SelectedIndex = 1
            }

            if ($script:EffectsFilterSpecificLayoutComboBox.SelectedIndex -gt 0) {
                $script:EffectsFilterSpecificLayout = [string]$script:EffectsFilterSpecificLayoutComboBox.SelectedItem
            }
            else {
                $script:EffectsFilterSpecificLayout = ''
            }
        }
        'None' {
            $script:EffectsFilterAssignedLayouts = $false
            $script:EffectsFilterSpecificLayout = ''
            $script:EffectsFilterNoAssignedLayouts = $true
        }
        default {
            $script:EffectsFilterAssignedLayouts = $false
            $script:EffectsFilterSpecificLayout = ''
            $script:EffectsFilterNoAssignedLayouts = $false
        }
    }
}

function Refresh-EffectsView {
    $scrollOffset = $script:EffectsScrollViewer.VerticalOffset
    Remove-DropRowsForKind -Kinds @('Effect', 'Preset')
    $script:EffectsPanel.Children.Clear()
    $visibleEffects = @(Get-VisibleEffects)

    if ($script:Effects.Count -eq 0 -or $visibleEffects.Count -eq 0) {
        $message = if (Test-Path -LiteralPath $script:InventoryPath -PathType Leaf) {
            if ($script:Effects.Count -eq 0) {
                'No effects were found in the inventory.'
            }
            else {
                'No effects match the selected filters.'
            }
        }
        else {
            'Inventory not found. Run the inventory updater first.'
        }

        [void]$script:EffectsPanel.Children.Add(
            (New-EmptyStateText -Text $message)
        )
    }
    else {
        for ($index = 0; $index -lt $visibleEffects.Count; $index++) {
            $effect = $visibleEffects[$index]
            [void]$script:EffectsPanel.Children.Add(
                (New-EffectRow -Effect $effect -Index (Get-EffectModelIndex -Effect $effect))
            )
        }
    }

    Update-EffectsCount
    $script:EffectsPanel.UpdateLayout()
    $script:EffectsScrollViewer.ScrollToVerticalOffset($scrollOffset)
}

function Refresh-LayoutsView {
    $scrollOffset = $script:LayoutsScrollViewer.VerticalOffset
    Remove-DropRowsForKind -Kinds @('Layout')
    $script:LayoutsPanel.Children.Clear()

    if ($script:Layouts.Count -eq 0) {
        $message = if (Test-Path -LiteralPath $script:InventoryPath -PathType Leaf) {
            'No layouts were found in the inventory.'
        }
        else {
            'Inventory not found. Run the inventory updater first.'
        }

        [void]$script:LayoutsPanel.Children.Add(
            (New-EmptyStateText -Text $message)
        )
    }
    else {
        for ($index = 0; $index -lt $script:Layouts.Count; $index++) {
            [void]$script:LayoutsPanel.Children.Add(
                (New-LayoutRow -Layout $script:Layouts[$index] -Index $index)
            )
        }
    }

    Update-LayoutsCount
    $script:LayoutsPanel.UpdateLayout()
    $script:LayoutsScrollViewer.ScrollToVerticalOffset($scrollOffset)
}

function ConvertTo-IniScalar {
    param([AllowNull()][object]$Value)

    return (
        ([string]$Value) -replace "`r|`n", ' '
    ).Trim()
}

function ConvertTo-IniBoolean {
    param([bool]$Value)

    if ($Value) {
        return 'true'
    }

    return 'false'
}

function Get-IniSectionRange {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$Name
    )

    $start = -1

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $line = ([string]$Lines[$index]).Trim()

        if ($line -match '^\[(?<Name>[^\]]+)\]$') {
            if (Test-SameText $Matches.Name $Name) {
                $start = $index
                break
            }
        }
    }

    if ($start -lt 0) {
        return $null
    }

    $end = $Lines.Count

    for ($index = $start + 1; $index -lt $Lines.Count; $index++) {
        if (([string]$Lines[$index]).Trim() -match '^\[[^\]]+\]$') {
            $end = $index
            break
        }
    }

    return [pscustomobject]@{
        Start = $start
        End = $end
    }
}

function Set-IniSectionLines {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$BodyLines
    )

    $replacement = [Collections.ArrayList]::new()
    [void]$replacement.Add('[' + $Name + ']')

    foreach ($line in $BodyLines) {
        [void]$replacement.Add([string]$line)
    }

    [void]$replacement.Add('')
    $range = Get-IniSectionRange -Lines $Lines -Name $Name

    if ($null -eq $range) {
        while (
            $Lines.Count -gt 0 -and
            [string]::IsNullOrWhiteSpace([string]$Lines[$Lines.Count - 1])
        ) {
            $Lines.RemoveAt($Lines.Count - 1)
        }

        if ($Lines.Count -gt 0) {
            [void]$Lines.Add('')
        }

        foreach ($line in $replacement) {
            [void]$Lines.Add($line)
        }

        return
    }

    $removeCount = $range.End - $range.Start

    for ($count = 0; $count -lt $removeCount; $count++) {
        $Lines.RemoveAt($range.Start)
    }

    for ($offset = 0; $offset -lt $replacement.Count; $offset++) {
        $Lines.Insert($range.Start + $offset, $replacement[$offset])
    }
}

function Remove-IniSection {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$Name
    )

    $range = Get-IniSectionRange -Lines $Lines -Name $Name

    if ($null -eq $range) {
        return
    }

    $removeCount = $range.End - $range.Start

    for ($count = 0; $count -lt $removeCount; $count++) {
        $Lines.RemoveAt($range.Start)
    }
}

function Get-NormalizedSet {
    param([Parameter(Mandatory)]$Values)

    $result = @{}

    foreach ($value in $Values) {
        $normalized = Get-NormalizedText $value

        if ($normalized.Length -gt 0) {
            $result[$normalized] = $true
        }
    }

    return ,$result
}

function Get-UnknownSectionEntries {
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)]$KnownKeys
    )

    $knownSet = Get-NormalizedSet -Values $KnownKeys
    $source = Get-IniSection `
        -Document $script:ConfigDocument `
        -Name $Section

    $result = New-CaseInsensitiveOrderedDictionary

    foreach ($key in $source.Keys) {
        if (-not $knownSet.ContainsKey((Get-NormalizedText $key))) {
            $result.Add([string]$key, [string]$source[$key])
        }
    }

    return ,$result
}

function Get-UnknownOrderedValues {
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)]$KnownValues
    )

    $knownSet = Get-NormalizedSet -Values $KnownValues
    $result = [Collections.ArrayList]::new()

    foreach ($value in (Get-OrderedValues `
        -Document $script:ConfigDocument `
        -Section $Section)) {
        if (-not $knownSet.ContainsKey((Get-NormalizedText $value))) {
            [void]$result.Add([string]$value)
        }
    }

    return ,$result
}

function Add-IniPair {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Value
    )

    $cleanKey = ConvertTo-IniScalar $Key

    if ($cleanKey.Length -eq 0) {
        return
    }

    [void]$Lines.Add(
        $cleanKey + '=' + (ConvertTo-IniScalar $Value)
    )
}

function Add-IniEntry {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$Value
    )

    $cleanValue = ConvertTo-IniScalar $Value

    if ($cleanValue.Length -eq 0) {
        return
    }

    [void]$Lines.Add($cleanValue)
}

function Add-UnknownEntries {
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)]$UnknownEntries,
        [switch]$BareTrue
    )

    foreach ($key in $UnknownEntries.Keys) {
        if (
            $BareTrue -and
            (Test-IniTrue -Value $UnknownEntries[$key] -Default $false)
        ) {
            Add-IniEntry `
                -Lines $Lines `
                -Value ([string]$key)

            continue
        }

        Add-IniPair `
            -Lines $Lines `
            -Key ([string]$key) `
            -Value ([string]$UnknownEntries[$key])
    }
}

function Get-HotkeyControls {
    $controls = New-CaseInsensitiveOrderedDictionary
    $controls.Add('OpenPickerMenu', $script:OpenPickerMenuTextBox)
    $controls.Add('PickPreset', $script:PickPresetTextBox)
    $controls.Add('PickEffect', $script:PickEffectTextBox)
    $controls.Add('PickLayout', $script:PickLayoutTextBox)
    $controls.Add('GoToNextPreset', $script:NextPresetTextBox)
    $controls.Add('GoToNextEffect', $script:NextEffectTextBox)
    $controls.Add('GoToNextLayout', $script:NextLayoutTextBox)
    $controls.Add('ShowStatus', $script:ShowStatusTextBox)

    return ,$controls
}

function Get-SelectedEffectCyclingMode {
    if ($script:EffectCyclingRandomRadio.IsChecked) {
        return 'Random'
    }

    return 'Order'
}

function Set-SelectedEffectCyclingMode {
    param([AllowEmptyString()][string]$Mode)

    if (Test-SameText $Mode 'Random') {
        $script:EffectCyclingRandomRadio.IsChecked = $true
    }
    else {
        $script:EffectCyclingOrderRadio.IsChecked = $true
    }
}

function Get-SelectedPresetCyclingMode {
    if ($script:PresetCyclingRandomRadio.IsChecked) {
        return 'Random'
    }

    return 'Order'
}

function Set-SelectedPresetCyclingMode {
    param([AllowEmptyString()][string]$Mode)

    if (Test-SameText $Mode 'Random') {
        $script:PresetCyclingRandomRadio.IsChecked = $true
    }
    else {
        $script:PresetCyclingOrderRadio.IsChecked = $true
    }
}

function Update-CyclingControlState {
    $effectCyclingEnabled = [bool]$script:EffectCyclingEnabledToggle.IsChecked
    $presetCyclingEnabled = [bool]$script:PresetCyclingEnabledToggle.IsChecked
    $afterPresetsAllowed = $effectCyclingEnabled -and $presetCyclingEnabled

    if ($null -ne $script:CycleEffectOnceAllPresetsElapsedToggle) {
        $script:CycleEffectOnceAllPresetsElapsedToggle.IsEnabled = $afterPresetsAllowed

        if (-not $afterPresetsAllowed) {
            $script:CycleEffectOnceAllPresetsElapsedToggle.IsChecked = $false
        }
    }

    $effectAfterPresets =
        $afterPresetsAllowed -and
        [bool]$script:CycleEffectOnceAllPresetsElapsedToggle.IsChecked

    foreach ($control in @(
        $script:EffectCyclingOrderRadio,
        $script:EffectCyclingRandomRadio
    )) {
        $control.IsEnabled = $effectCyclingEnabled
    }

    $script:EffectCyclingIntervalTextBox.IsEnabled =
        $effectCyclingEnabled -and -not $effectAfterPresets

    foreach ($control in @(
        $script:PresetCyclingOrderRadio,
        $script:PresetCyclingRandomRadio
    )) {
        $control.IsEnabled = $presetCyclingEnabled
    }

    $script:PresetCyclingIntervalTextBox.IsEnabled =
        $presetCyclingEnabled

    foreach ($control in @(
        $script:PresetLastUsedRadio,
        $script:PresetPreferredRadio
    )) {
        if ($null -ne $control) {
            $control.IsEnabled = -not $presetCyclingEnabled
        }
    }

    if ($null -ne $script:PresetActivationOverrideText) {
        $script:PresetActivationOverrideText.Visibility = if ($presetCyclingEnabled) {
            [Windows.Visibility]::Visible
        }
        else {
            [Windows.Visibility]::Collapsed
        }
    }
}

function ConvertFrom-AhkHotkey {
    param([AllowEmptyString()][string]$Hotkey)

    $value = ([string]$Hotkey).Trim()

    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }

    $parts = [Collections.ArrayList]::new()

    while ($value.Length -gt 0) {
        $prefix = [string]$value[0]

        if ($prefix -eq '^') {
            [void]$parts.Add('Ctrl')
            $value = $value.Substring(1)
            continue
        }

        if ($prefix -eq '!') {
            [void]$parts.Add('Alt')
            $value = $value.Substring(1)
            continue
        }

        if ($prefix -eq '+') {
            [void]$parts.Add('Shift')
            $value = $value.Substring(1)
            continue
        }

        if ($prefix -eq '#') {
            [void]$parts.Add('Win')
            $value = $value.Substring(1)
            continue
        }

        break
    }

    $keyName = switch -Regex ($value) {
        '^$' { '' }
        '^.$' { $value.ToUpperInvariant() }
        '^Numpad(\d)$' { 'Numpad ' + $Matches[1] }
        '^PgUp$' { 'Page Up' }
        '^PgDn$' { 'Page Down' }
        '^Esc$' { 'Escape' }
        '^vk[0-9A-Fa-f]{2}$' { '*' }
        default { $value }
    }

    if (-not [string]::IsNullOrWhiteSpace($keyName)) {
        [void]$parts.Add($keyName)
    }

    return ($parts -join ' + ')
}

function ConvertTo-AhkKeyName {
    param([Parameter(Mandatory)][Windows.Input.Key]$Key)

    $name = $Key.ToString()

    if ($name -match '^[A-Z]$') {
        return $name.ToLowerInvariant()
    }

    if ($name -match '^D(\d)$') {
        return $Matches[1]
    }

    if ($name -match '^NumPad(\d)$') {
        return 'Numpad' + $Matches[1]
    }

    if ($name -match '^F\d{1,2}$') {
        return $name
    }

    switch ($name) {
        'Return' { return 'Enter' }
        'Escape' { return 'Escape' }
        'Space' { return 'Space' }
        'Tab' { return 'Tab' }
        'Back' { return 'Backspace' }
        'Delete' { return 'Delete' }
        'Insert' { return 'Insert' }
        'Home' { return 'Home' }
        'End' { return 'End' }
        'PageUp' { return 'PgUp' }
        'PageDown' { return 'PgDn' }
        'Up' { return 'Up' }
        'Down' { return 'Down' }
        'Left' { return 'Left' }
        'Right' { return 'Right' }
        'CapsLock' { return 'CapsLock' }
        'Scroll' { return 'ScrollLock' }
        'NumLock' { return 'NumLock' }
        'PrintScreen' { return 'PrintScreen' }
        'Snapshot' { return 'PrintScreen' }
        'Pause' { return 'Pause' }
        'Apps' { return 'AppsKey' }
        'BrowserBack' { return 'Browser_Back' }
        'BrowserForward' { return 'Browser_Forward' }
        'BrowserRefresh' { return 'Browser_Refresh' }
        'BrowserStop' { return 'Browser_Stop' }
        'BrowserSearch' { return 'Browser_Search' }
        'BrowserFavorites' { return 'Browser_Favorites' }
        'BrowserHome' { return 'Browser_Home' }
        'VolumeMute' { return 'Volume_Mute' }
        'VolumeDown' { return 'Volume_Down' }
        'VolumeUp' { return 'Volume_Up' }
        'MediaNextTrack' { return 'Media_Next' }
        'MediaPreviousTrack' { return 'Media_Prev' }
        'MediaStop' { return 'Media_Stop' }
        'MediaPlayPause' { return 'Media_Play_Pause' }
        'LaunchMail' { return 'Launch_Mail' }
        'SelectMedia' { return 'Launch_Media' }
        'LaunchApplication1' { return 'Launch_App1' }
        'LaunchApplication2' { return 'Launch_App2' }
        default {
            $virtualKey = [Windows.Input.KeyInterop]::VirtualKeyFromKey($Key)

            if ($virtualKey -gt 0) {
                return ('vk{0:X2}' -f $virtualKey)
            }

            return ''
        }
    }
}

function Get-EffectiveHotkeyKey {
    param([Parameter(Mandatory)]$EventArgs)

    $key = $EventArgs.Key

    if ($key -eq [Windows.Input.Key]::System) {
        $key = $EventArgs.SystemKey
    }
    elseif ($key -eq [Windows.Input.Key]::ImeProcessed) {
        $key = $EventArgs.ImeProcessedKey
    }
    elseif ($key -eq [Windows.Input.Key]::DeadCharProcessed) {
        $key = $EventArgs.DeadCharProcessedKey
    }

    switch ($key.ToString()) {
        'LeftCtrl' { return $null }
        'RightCtrl' { return $null }
        'LeftAlt' { return $null }
        'RightAlt' { return $null }
        'LeftShift' { return $null }
        'RightShift' { return $null }
        'LWin' { return $null }
        'RWin' { return $null }
        default { return $key }
    }
}

function Convert-KeyEventToAhkHotkey {
    param([Parameter(Mandatory)]$EventArgs)

    $key = Get-EffectiveHotkeyKey -EventArgs $EventArgs

    if ($null -eq $key) {
        return $null
    }

    $keyName = ConvertTo-AhkKeyName -Key $key

    if ([string]::IsNullOrWhiteSpace($keyName)) {
        return ''
    }

    $modifiers = [Windows.Input.Keyboard]::Modifiers
    $prefix = ''

    if (($modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0) {
        $prefix += '^'
    }

    if (($modifiers -band [Windows.Input.ModifierKeys]::Alt) -ne 0) {
        $prefix += '!'
    }

    if (($modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0) {
        $prefix += '+'
    }

    if (($modifiers -band [Windows.Input.ModifierKeys]::Windows) -ne 0) {
        $prefix += '#'
    }

    return ($prefix + $keyName)
}

function Get-CurrentModifierDisplayText {
    $modifiers = [Windows.Input.Keyboard]::Modifiers
    $parts = [Collections.ArrayList]::new()

    if (($modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0) {
        [void]$parts.Add('Ctrl')
    }

    if (($modifiers -band [Windows.Input.ModifierKeys]::Alt) -ne 0) {
        [void]$parts.Add('Alt')
    }

    if (($modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0) {
        [void]$parts.Add('Shift')
    }

    if (($modifiers -band [Windows.Input.ModifierKeys]::Windows) -ne 0) {
        [void]$parts.Add('Win')
    }

    if ($parts.Count -eq 0) {
        return 'Set a hotkey'
    }

    return (($parts -join ' + ') + ' +')
}

function Set-HotkeyControlValue {
    param(
        [Parameter(Mandatory)]$Control,
        [AllowEmptyString()][string]$AhkHotkey
    )

    $value = ([string]$AhkHotkey).Trim()
    $Control.Tag = $value
    if ([string]::IsNullOrWhiteSpace($value)) {
        $Control.Text = 'Empty'
        $Control.Foreground = $script:MutedBrush
    }
    else {
        $Control.Text = ConvertFrom-AhkHotkey $value
        $Control.Foreground = $script:TextBrush
    }
    $Control.BorderBrush = $script:BorderBrush
}

function Get-HotkeyDuplicateControls {
    $controls = Get-HotkeyControls
    $seen = @{}
    $duplicates = [Collections.ArrayList]::new()

    foreach ($key in $controls.Keys) {
        $control = $controls[$key]
        $value = ([string]$control.Tag).Trim()
        $control.BorderBrush = $script:BorderBrush

        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $normalized = Get-NormalizedText $value

        if ($seen.ContainsKey($normalized)) {
            [void]$duplicates.Add($control)
            [void]$duplicates.Add($seen[$normalized])
        }
        else {
            $seen[$normalized] = $control
        }
    }

    return ,$duplicates
}

function Update-HotkeyValidationMessage {
    $duplicates = Get-HotkeyDuplicateControls

    foreach ($control in $duplicates) {
        $control.BorderBrush = $script:ErrorBrush
    }

    if ($duplicates.Count -gt 0) {
        $script:HotkeyWarningText.Text = 'That hotkey is already in use.'
        $script:HotkeyWarningText.Visibility = [Windows.Visibility]::Visible
        return $false
    }

    $script:HotkeyWarningText.Text = ''
    $script:HotkeyWarningText.Visibility = [Windows.Visibility]::Collapsed
    return $true
}

function Install-HotkeyClearButtons {
    $controls = Get-HotkeyControls

    foreach ($key in $controls.Keys) {
        $control = $controls[$key]
        $parent = $control.Parent

        if ($null -eq $parent -or -not ($parent -is [Windows.Controls.Grid])) {
            continue
        }

        $column = [Windows.Controls.Grid]::GetColumn($control)
        $row = [Windows.Controls.Grid]::GetRow($control)
        $columnSpan = [Windows.Controls.Grid]::GetColumnSpan($control)
        $rowSpan = [Windows.Controls.Grid]::GetRowSpan($control)

        [void]$parent.Children.Remove($control)

        $innerGrid = [Windows.Controls.Grid]::new()
        $inputColumn = [Windows.Controls.ColumnDefinition]::new()
        $inputColumn.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $innerGrid.ColumnDefinitions.Add($inputColumn)

        $buttonColumn = [Windows.Controls.ColumnDefinition]::new()
        $buttonColumn.Width = [Windows.GridLength]::new(38)
        $innerGrid.ColumnDefinitions.Add($buttonColumn)

        $resetColumn = [Windows.Controls.ColumnDefinition]::new()
        $resetColumn.Width = [Windows.GridLength]::new(38)
        $innerGrid.ColumnDefinitions.Add($resetColumn)

        [Windows.Controls.Grid]::SetColumn($innerGrid, $column)
        [Windows.Controls.Grid]::SetRow($innerGrid, $row)
        [Windows.Controls.Grid]::SetColumnSpan($innerGrid, $columnSpan)
        [Windows.Controls.Grid]::SetRowSpan($innerGrid, $rowSpan)

        [Windows.Controls.Grid]::SetColumn($control, 0)
        $control.Margin = [Windows.Thickness]::new(0)
        $control.FontSize = 11
        $control.Padding = [Windows.Thickness]::new(7, 4, 7, 4)
        [void]$innerGrid.Children.Add($control)

        $button = [Windows.Controls.Button]::new()
        $button.Content = 'X'
        $button.Width = 34
        $button.Height = 34
        $button.MinWidth = 34
        $button.MinHeight = 34
        $button.MaxWidth = 34
        $button.MaxHeight = 34
        $button.Margin = [Windows.Thickness]::new(4, 0, 0, 0)
        $button.Padding = [Windows.Thickness]::new(0)
        $button.HorizontalContentAlignment = [Windows.HorizontalAlignment]::Center
        $button.VerticalContentAlignment = [Windows.VerticalAlignment]::Center
        $button.FontSize = 11
        $button.FontWeight = [Windows.FontWeights]::SemiBold
        $button.Cursor = [Windows.Input.Cursors]::Hand
        $button.ToolTip = 'Clear hotkey'
        $button.Style = $script:Window.FindResource('SmallButtonStyle')
        $button.Tag = $control

        [Windows.Controls.Grid]::SetColumn($button, 1)
        [void]$innerGrid.Children.Add($button)

        $button.Add_Click({
            param($sender)
            Set-HotkeyControlValue -Control $sender.Tag -AhkHotkey ''
            Set-Dirty
            [void](Update-HotkeyValidationMessage)
        })

        $resetButton = [Windows.Controls.Button]::new()
        $resetButton.Content = [string][char]0x21BB
        $resetButton.Width = 34
        $resetButton.Height = 34
        $resetButton.MinWidth = 34
        $resetButton.MinHeight = 34
        $resetButton.MaxWidth = 34
        $resetButton.MaxHeight = 34
        $resetButton.Margin = [Windows.Thickness]::new(4, 0, 0, 0)
        $resetButton.Padding = [Windows.Thickness]::new(0)
        $resetButton.HorizontalContentAlignment = [Windows.HorizontalAlignment]::Center
        $resetButton.VerticalContentAlignment = [Windows.VerticalAlignment]::Center
        $resetButton.FontSize = 13
        $resetButton.FontWeight = [Windows.FontWeights]::SemiBold
        $resetButton.Cursor = [Windows.Input.Cursors]::Hand
        $resetButton.ToolTip = 'Reset hotkey to default'
        $resetButton.Style = $script:Window.FindResource('SmallButtonStyle')
        $resetButton.Tag = [pscustomobject]@{
            Control = $control
            Key = [string]$key
        }

        [Windows.Controls.Grid]::SetColumn($resetButton, 2)
        [void]$innerGrid.Children.Add($resetButton)
        [void]$parent.Children.Add($innerGrid)

        $resetButton.Add_Click({
            param($sender)
            Set-HotkeyControlValue `
                -Control $sender.Tag.Control `
                -AhkHotkey $script:HotkeyDefaults[$sender.Tag.Key]
            Set-Dirty
            [void](Update-HotkeyValidationMessage)
        })
    }
}

function Register-HotkeyCaptureEvents {
    foreach ($control in (Get-HotkeyControls).Values) {
        $control.IsReadOnly = $true
        $control.Cursor = [Windows.Input.Cursors]::Hand

        $control.Add_GotKeyboardFocus({
            param($sender)
            $script:HotkeyCaptureFinalized = $false
            $sender.Text = 'Set a hotkey'
            $sender.Foreground = $script:MutedBrush
        })

        $control.Add_LostKeyboardFocus({
            param($sender)
            Set-HotkeyControlValue `
                -Control $sender `
                -AhkHotkey ([string]$sender.Tag)
        })

        $control.Add_PreviewTextInput({
            param($sender, $eventArgs)
            $eventArgs.Handled = $true
        })

        $control.Add_PreviewKeyDown({
            param($sender, $eventArgs)

            if ($eventArgs.Key -eq [Windows.Input.Key]::Escape) {
                $script:HotkeyCaptureFinalized = $true
                Set-HotkeyControlValue `
                    -Control $sender `
                    -AhkHotkey ([string]$sender.Tag)
                [void](Update-HotkeyValidationMessage)
                [void]$script:Window.Focus()
                $eventArgs.Handled = $true
                return
            }

            $hotkey = Convert-KeyEventToAhkHotkey -EventArgs $eventArgs

            if ($null -eq $hotkey) {
                if (-not $script:HotkeyCaptureFinalized) {
                    $sender.Text = Get-CurrentModifierDisplayText
                    $sender.Foreground = $script:MutedBrush
                }
                $eventArgs.Handled = $true
                return
            }

            if ([string]::IsNullOrWhiteSpace($hotkey)) {
                Set-Status -Text 'That key is not supported for hotkey capture.' -Kind Error
                $eventArgs.Handled = $true
                return
            }

            Set-HotkeyControlValue -Control $sender -AhkHotkey $hotkey
            Set-Dirty
            [void](Update-HotkeyValidationMessage)
            $script:HotkeyCaptureFinalized = $true
            [void][Windows.Input.Keyboard]::ClearFocus()
            $eventArgs.Handled = $true
        })

        $control.Add_PreviewKeyUp({
            param($sender, $eventArgs)

            $key = Get-EffectiveHotkeyKey -EventArgs $eventArgs

            if ($null -eq $key -and -not $script:HotkeyCaptureFinalized) {
                $sender.Text = Get-CurrentModifierDisplayText
                $sender.Foreground = $script:MutedBrush
                $eventArgs.Handled = $true
            }
        })
    }
}

function Test-HotkeyValues {
    $controls = Get-HotkeyControls
    $values = New-CaseInsensitiveOrderedDictionary

    foreach ($key in $controls.Keys) {
        $control = $controls[$key]
        $value = ([string]$control.Tag).Trim()
        $control.BorderBrush = $script:BorderBrush
        $values.Add([string]$key, $value)
    }

    if (-not (Update-HotkeyValidationMessage)) {
        $script:MainTabs.SelectedIndex = 3
        Set-Status `
            -Text 'Each assigned hotkey must be unique.' `
            -Kind Error
        return $null
    }

    return ,$values
}

function Test-DurationTextFormat {
    param([AllowEmptyString()][string]$Value)

    $text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    return $text -match '^(?:\d+h\s*)?(?:\d+m\s*)?(?:\d+s\s*)?$'
}

function ConvertTo-DurationSeconds {
    param([AllowEmptyString()][string]$Value)

    $text = ([string]$Value).Trim()

    if (-not (Test-DurationTextFormat $text)) {
        return $null
    }

    $hours = 0
    $minutes = 0
    $seconds = 0

    $hourMatch = [regex]::Match($text, '(\d+)h')
    $minuteMatch = [regex]::Match($text, '(\d+)m')
    $secondMatch = [regex]::Match($text, '(\d+)s')

    if ($hourMatch.Success) {
        $hours = [int]$hourMatch.Groups[1].Value
    }

    if ($minuteMatch.Success) {
        $minutes = [int]$minuteMatch.Groups[1].Value
    }

    if ($secondMatch.Success) {
        $seconds = [int]$secondMatch.Groups[1].Value
    }

    return (($hours * 3600) + ($minutes * 60) + $seconds)
}

function Register-DurationTextBox {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)]$ValidationText,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Default,
        [Parameter(Mandatory)][int]$TabIndex
    )

    $Control.Tag = [pscustomobject]@{
        LastValid = $Default
        Default = $Default
        Label = $Label
        TabIndex = $TabIndex
        ValidationText = $ValidationText
        ValidationTimer = $null
    }

    $ValidationText.Visibility = [Windows.Visibility]::Collapsed
}

function Set-DurationTextBoxValue {
    param(
        [Parameter(Mandatory)]$Control,
        [AllowEmptyString()][string]$Value
    )

    $text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = [string]$Control.Tag.Default
    }

    $Control.Text = $text
    $Control.Tag.LastValid = $text
    Clear-DurationValidation -Control $Control
}

function Show-DurationValidation {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][string]$Message
    )

    if (
        $null -ne $Control.Tag.ValidationTimer -and
        $Control.Tag.ValidationTimer -is [Windows.Threading.DispatcherTimer]
    ) {
        $Control.Tag.ValidationTimer.Stop()
    }

    $Control.BorderBrush = $script:ErrorBrush
    $Control.Tag.ValidationText.Text = $Message
    $Control.Tag.ValidationText.Visibility = [Windows.Visibility]::Visible

    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(4)
    $timer.Tag = $Control
    $timer.Add_Tick({
        param($sender)

        $sender.Stop()
        if ($null -ne $sender.Tag) {
            Clear-DurationValidation -Control $sender.Tag
        }
    })
    $Control.Tag.ValidationTimer = $timer
    $timer.Start()
}

function Clear-DurationValidation {
    param([Parameter(Mandatory)]$Control)

    $Control.BorderBrush = $script:BorderBrush

    if ($null -ne $Control.Tag -and $null -ne $Control.Tag.ValidationText) {
        if (
            $null -ne $Control.Tag.ValidationTimer -and
            $Control.Tag.ValidationTimer -is [Windows.Threading.DispatcherTimer]
        ) {
            $Control.Tag.ValidationTimer.Stop()
            $Control.Tag.ValidationTimer = $null
        }

        $Control.Tag.ValidationText.Visibility = [Windows.Visibility]::Collapsed
    }
}

function Clear-AllDurationValidation {
    foreach ($control in @(
        $script:AutoUpdateInventoryIntervalTextBox,
        $script:EffectCyclingIntervalTextBox,
        $script:PresetCyclingIntervalTextBox
    )) {
        if ($null -ne $control) {
            Clear-DurationValidation -Control $control
        }
    }
}

function Test-DurationTextBox {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][string]$Label,
        [string]$Default = '0h 2m 30s',
        [int]$TabIndex = 4
    )

    $value = ([string]$Control.Text).Trim()
    Clear-DurationValidation -Control $Control

    if ($null -ne $Control.Tag) {
        $Default = [string]$Control.Tag.Default
        $Label = [string]$Control.Tag.Label
        $TabIndex = [int]$Control.Tag.TabIndex
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $Default
    }

    if (-not (Test-DurationTextFormat $value)) {
        $previousValue = $Default

        if (
            $null -ne $Control.Tag -and
            -not [string]::IsNullOrWhiteSpace([string]$Control.Tag.LastValid)
        ) {
            $previousValue = [string]$Control.Tag.LastValid
        }

        $Control.Text = $previousValue
        Show-DurationValidation -Control $Control -Message 'Invalid entry.'
        $script:MainTabs.SelectedIndex = $TabIndex

        return $null
    }

    $Control.Text = $value
    if ($null -ne $Control.Tag) {
        $Control.Tag.LastValid = $value
    }

    return $value
}

function Test-CyclingIntervalRelation {
    param(
        [Parameter(Mandatory)][string]$EffectInterval,
        [Parameter(Mandatory)][string]$PresetInterval,
        [switch]$SelectTab
    )

    if (
        -not [bool]$script:EffectCyclingEnabledToggle.IsChecked -or
        -not [bool]$script:PresetCyclingEnabledToggle.IsChecked -or
        [bool]$script:CycleEffectOnceAllPresetsElapsedToggle.IsChecked
    ) {
        return $true
    }

    $effectSeconds = ConvertTo-DurationSeconds $EffectInterval
    $presetSeconds = ConvertTo-DurationSeconds $PresetInterval

    if ($null -eq $effectSeconds -or $null -eq $presetSeconds) {
        return $true
    }

    if ($presetSeconds -gt $effectSeconds) {
        Show-DurationValidation `
            -Control $script:PresetCyclingIntervalTextBox `
            -Message 'Preset interval must be less than Effect cycle'

        if ($SelectTab) {
            $script:MainTabs.SelectedIndex = 2
        }

        return $false
    }

    return $true
}

function Confirm-DurationTextBox {
    param([Parameter(Mandatory)]$Control)

    [void](Test-DurationTextBox `
        -Control $Control `
        -Label ([string]$Control.Tag.Label) `
        -Default ([string]$Control.Tag.Default) `
        -TabIndex ([int]$Control.Tag.TabIndex))

    if (
        $Control -eq $script:EffectCyclingIntervalTextBox -or
        $Control -eq $script:PresetCyclingIntervalTextBox
    ) {
        [void](Test-CyclingIntervalRelation `
            -EffectInterval ([string]$script:EffectCyclingIntervalTextBox.Text) `
            -PresetInterval ([string]$script:PresetCyclingIntervalTextBox.Text))
    }
}

function Get-CurrentEffectKnownKeys {
    $keys = [Collections.ArrayList]::new()

    foreach ($effect in $script:Effects) {
        [void]$keys.Add($effect.Id)
        [void]$keys.Add((Get-EffectConfigKey -Effect $effect))
    }

    return ,$keys
}

function Test-UsableConfigEffect {
    param([Parameter(Mandatory)]$Effect)

    $name = ([string]$Effect.Name).Trim()
    $normalizedName = Get-NormalizedText $name

    return (
        ([string]$Effect.Status) -eq 'Present' -and
        -not [string]::IsNullOrWhiteSpace($name) -and
        -not $normalizedName.StartsWith('[unusable effect ') -and
        -not $normalizedName.StartsWith('[unresolved effect ')
    )
}

function Get-EffectConfigKey {
    param([Parameter(Mandatory)]$Effect)

    if (Test-UsableConfigEffect -Effect $Effect) {
        return [string]$Effect.Name
    }

    return [string]$Effect.Id
}

function Get-AutoHotkeyExecutable {
    $candidates = [Collections.ArrayList]::new()
    $programFiles = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFiles
    )
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')

    foreach ($root in @($programFiles, $programFilesX86)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        foreach ($name in @('AutoHotkey64.exe', 'AutoHotkey.exe')) {
            [void]$candidates.Add(
                (Join-Path $root ('AutoHotkey\v2\' + $name))
            )
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    foreach ($commandName in @('AutoHotkey64.exe', 'AutoHotkey.exe')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue

        if ($null -ne $command) {
            return $command.Source
        }
    }

    return $null
}

function Get-NormalizedFsPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $trimmed = $Path.Trim().Trim('"')

    try {
        return [System.IO.Path]::GetFullPath($trimmed).TrimEnd('\', '/').ToLowerInvariant()
    }
    catch {
        return $trimmed.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    }
}

function Get-StartupShortcutFolder {
    $startupFolder = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Startup
    )

    if ([string]::IsNullOrWhiteSpace($startupFolder)) {
        throw 'The user Startup folder could not be resolved.'
    }

    if (-not (Test-Path -LiteralPath $startupFolder -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $startupFolder -Force)
    }

    return $startupFolder
}

function Get-StartupShortcutPath {
    return (Join-Path (Get-StartupShortcutFolder) 'SignalRGB-Pro-Switcher-Free.lnk')
}

function Get-ShortcutReferencedScriptPath {
    param($Shortcut)

    $targetPath = [string]$Shortcut.TargetPath
    $arguments = [string]$Shortcut.Arguments

    if ($targetPath -match '\.ahk$') {
        return $targetPath
    }

    if ($arguments -match '^"([^"]+)"') {
        return $Matches[1]
    }

    if ($arguments -match '^(\S+)') {
        return $Matches[1]
    }

    return $targetPath
}

function Test-StartupShortcutMatchesCurrentLocation {
    param(
        $Shortcut,
        [string]$ScriptPath,
        [string]$WorkingDirectory
    )

    $referencedScript = Get-ShortcutReferencedScriptPath -Shortcut $Shortcut

    if ((Get-NormalizedFsPath $referencedScript) -ne (Get-NormalizedFsPath $ScriptPath)) {
        return $false
    }

    return (
        (Get-NormalizedFsPath $Shortcut.WorkingDirectory) -eq
        (Get-NormalizedFsPath $WorkingDirectory)
    )
}

function Sync-LaunchOnStartupShortcut {
    param([bool]$Enabled)

    try {
        $shortcutPath = Get-StartupShortcutPath

        if (-not $Enabled) {
            if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
                Remove-Item -LiteralPath $shortcutPath -Force
            }

            return [pscustomobject]@{
                Success = $true
                Message = 'Startup shortcut removed'
            }
        }

        $scriptPath = Join-Path $script:ProjectRoot 'SignalRGB-Pro-Switcher.ahk'

        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            return [pscustomobject]@{
                Success = $false
                Message = 'AHK script not found: SignalRGB-Pro-Switcher.ahk'
            }
        }

        $shell = New-Object -ComObject WScript.Shell
        $shortcutExists = Test-Path -LiteralPath $shortcutPath -PathType Leaf

        if ($shortcutExists) {
            $existingShortcut = $shell.CreateShortcut($shortcutPath)

            if (
                Test-StartupShortcutMatchesCurrentLocation `
                    -Shortcut $existingShortcut `
                    -ScriptPath $scriptPath `
                    -WorkingDirectory $script:ProjectRoot
            ) {
                return [pscustomobject]@{
                    Success = $true
                    Message = 'Startup shortcut already current'
                }
            }
        }

        $shortcut = $shell.CreateShortcut($shortcutPath)
        $autoHotkey = Get-AutoHotkeyExecutable

        if ($null -ne $autoHotkey) {
            $shortcut.TargetPath = $autoHotkey
            $shortcut.Arguments = ConvertTo-ProcessArgument $scriptPath
            $shortcut.IconLocation = $autoHotkey
        }
        else {
            $shortcut.TargetPath = $scriptPath
            $shortcut.Arguments = ''
            $shortcut.IconLocation = ''
        }

        $shortcut.WorkingDirectory = $script:ProjectRoot
        $shortcut.Description = 'Launch SignalRGB Pro Switcher Free'
        $shortcut.Save()

        return [pscustomobject]@{
            Success = $true
            Message = 'Startup shortcut updated'
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Message = ('Startup shortcut failed: ' + $_.Exception.Message)
        }
    }
}

function Restart-AhkScriptFromEditor {
    $scriptPath = Join-Path $script:ProjectRoot 'SignalRGB-Pro-Switcher.ahk'

    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        return [pscustomobject]@{
            Success = $false
            Message = 'AHK script not found: SignalRGB-Pro-Switcher.ahk'
        }
    }

    try {
        $matchers = @(
            [Regex]::Escape($scriptPath),
            'SignalRGB-Pro-Switcher\.ahk'
        )

        $processes = Get-CimInstance Win32_Process |
            Where-Object {
                $commandLine = [string]$_.CommandLine

                if ([string]::IsNullOrWhiteSpace($commandLine)) {
                    $false
                }
                else {
                    $isMatch = $false

                    foreach ($matcher in $matchers) {
                        if ($commandLine -match $matcher) {
                            $isMatch = $true
                            break
                        }
                    }

                    $isMatch
                }
            }

        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }

        Start-Sleep -Milliseconds 250

        $autoHotkey = Get-AutoHotkeyExecutable

        if ($null -ne $autoHotkey) {
            Start-Process `
                -FilePath $autoHotkey `
                -ArgumentList ('"{0}"' -f $scriptPath) `
                -WorkingDirectory $script:ProjectRoot `
                -WindowStyle Hidden
        }
        else {
            Start-Process `
                -FilePath $scriptPath `
                -WorkingDirectory $script:ProjectRoot `
                -WindowStyle Hidden
        }

        return [pscustomobject]@{
            Success = $true
            Message = 'Saved changes.'
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Message = ('Saved, but AHK restart failed: ' + $_.Exception.Message)
        }
    }
}

function Save-Configuration {
    param([switch]$RestartAhk)

    $hotkeys = Test-HotkeyValues

    if ($null -eq $hotkeys) {
        return $false
    }

    $autoUpdateInterval = Test-DurationTextBox `
        -Control $script:AutoUpdateInventoryIntervalTextBox `
        -Label 'Auto-update interval' `
        -Default '0h 2m 30s' `
        -TabIndex 4

    if ($null -eq $autoUpdateInterval) {
        return $false
    }

    $effectCyclingInterval = Test-DurationTextBox `
        -Control $script:EffectCyclingIntervalTextBox `
        -Label 'Effect cycling interval' `
        -Default '0h 15m 0s' `
        -TabIndex 2

    if ($null -eq $effectCyclingInterval) {
        return $false
    }

    $presetCyclingInterval = Test-DurationTextBox `
        -Control $script:PresetCyclingIntervalTextBox `
        -Label 'Preset cycling interval' `
        -Default '0h 15m 0s' `
        -TabIndex 2

    if ($null -eq $presetCyclingInterval) {
        return $false
    }

    if (-not (Test-CyclingIntervalRelation `
        -EffectInterval $effectCyclingInterval `
        -PresetInterval $presetCyclingInterval `
        -SelectTab)) {
        return $false
    }

    try {
        $lines = [Collections.ArrayList]::new()

        foreach ($line in $script:ConfigDocument.Lines) {
            [void]$lines.Add([string]$line)
        }

        $assetKeys = @(
            'InventoryFile',
            ('Inventory' + 'Report'),
            'UpdaterScript'
        )
        $assetUnknown = Get-UnknownSectionEntries `
            -Section 'Assets' `
            -KnownKeys $assetKeys
        $assetLines = [Collections.ArrayList]::new()
        Add-IniPair $assetLines 'InventoryFile' $script:InventoryFileTextBox.Text
        Add-IniPair $assetLines 'UpdaterScript' $script:UpdaterScriptTextBox.Text
        Add-UnknownEntries $assetLines $assetUnknown
        [void]$assetLines.Add('')
        [void]$assetLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'Assets' $assetLines
        Remove-IniSection $lines 'Integration'

        $hotkeyLines = [Collections.ArrayList]::new()
        [void]$hotkeyLines.Add('; Hotkey format uses normal AutoHotkey style')
        [void]$hotkeyLines.Add('; + = Shift, ^ = Ctrl, ! = Alt, # = Win')
        [void]$hotkeyLines.Add('; Example: ^!+p = Ctrl+Alt+Shift+P, !s = Alt+S')

        foreach ($key in $hotkeys.Keys) {
            Add-IniPair $hotkeyLines ([string]$key) ([string]$hotkeys[$key])
        }

        $hotkeyUnknown = Get-UnknownSectionEntries `
            -Section 'Hotkeys' `
            -KnownKeys (@($hotkeys.Keys) + @(
                ('Cycle' + 'Preset'),
                ('Cycle' + 'Effect'),
                ('Cycle' + 'Layout')
            ))
        Add-UnknownEntries $hotkeyLines $hotkeyUnknown
        [void]$hotkeyLines.Add('')
        [void]$hotkeyLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'Hotkeys' $hotkeyLines

        $cyclingKeys = @(
            'EffectCyclingEnabled',
            'EffectCyclingMode',
            'EffectCyclingInterval',
            'CycleEffectOnceAllPresetsElapsed',
            'PresetCyclingEnabled',
            'PresetCyclingMode',
            'PresetCyclingInterval'
        )
        $cyclingUnknown = Get-UnknownSectionEntries `
            -Section 'Cycling' `
            -KnownKeys $cyclingKeys
        $cyclingLines = [Collections.ArrayList]::new()
        [void]$cyclingLines.Add('; EffectCyclingMode: Order or Random')
        [void]$cyclingLines.Add('; CycleEffectOnceAllPresetsElapsed: when on, effects advance after all presets have elapsed instead of on the effect interval.')
        [void]$cyclingLines.Add('; PresetCyclingMode: Order or Random')
        [void]$cyclingLines.Add('; If both normal effect cycling and preset cycling are enabled, keep PresetCyclingInterval lower than EffectCyclingInterval.')
        Add-IniPair $cyclingLines 'EffectCyclingEnabled' (
            ConvertTo-IniBoolean ([bool]$script:EffectCyclingEnabledToggle.IsChecked)
        )
        Add-IniPair $cyclingLines 'EffectCyclingMode' (Get-SelectedEffectCyclingMode)
        Add-IniPair $cyclingLines 'EffectCyclingInterval' ([string]$effectCyclingInterval)
        Add-IniPair $cyclingLines 'CycleEffectOnceAllPresetsElapsed' (
            ConvertTo-IniBoolean ([bool]$script:CycleEffectOnceAllPresetsElapsedToggle.IsChecked)
        )
        Add-IniPair $cyclingLines 'PresetCyclingEnabled' (
            ConvertTo-IniBoolean ([bool]$script:PresetCyclingEnabledToggle.IsChecked)
        )
        Add-IniPair $cyclingLines 'PresetCyclingMode' (Get-SelectedPresetCyclingMode)
        Add-IniPair $cyclingLines 'PresetCyclingInterval' ([string]$presetCyclingInterval)
        Add-UnknownEntries $cyclingLines $cyclingUnknown
        [void]$cyclingLines.Add('')
        [void]$cyclingLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'Cycling' $cyclingLines

        $behaviorKeys = @(
            'LaunchOnStartup',
            'AutoUpdateInventory',
            'AutoUpdateInventoryInterval',
            'ShowHotkeyNotifications',
            ('Show' + 'TooltipNotifications'),
            'ShowNotifications',
            'Logging',
            'UseFiltersAsCustomOrder',
            'WatchExternalEffectChanges',
            'ExcludeFromPickers',
            ('Exclude' + 'From' + 'Cycle'),
            'ExcludeFromNextHotkeys',
            'ExcludeFromCycling',
            'PresetOnEffectActivation',
            'UnassignedEffectLayoutMode',
            'DefaultLayout',
            'ApplyPoliciesOnStartup',
            'RememberLastActiveEffectPreset'
        )
        $behaviorUnknown = Get-UnknownSectionEntries `
            -Section 'Behavior' `
            -KnownKeys $behaviorKeys
        $behaviorLines = [Collections.ArrayList]::new()
        Add-IniPair $behaviorLines 'LaunchOnStartup' (
            ConvertTo-IniBoolean ([bool]$script:LaunchOnStartupToggle.IsChecked)
        )
        Add-IniPair $behaviorLines 'AutoUpdateInventory' (
            ConvertTo-IniBoolean ([bool]$script:AutoUpdateInventoryToggle.IsChecked)
        )
        Add-IniPair $behaviorLines 'AutoUpdateInventoryInterval' (
            [string]$autoUpdateInterval
        )
        Add-IniPair $behaviorLines 'ShowHotkeyNotifications' (
            ConvertTo-IniBoolean ([bool]$script:ShowHotkeyNotificationsToggle.IsChecked)
        )
        Add-IniPair $behaviorLines 'Logging' (
            ConvertTo-IniBoolean ([bool]$script:LoggingToggle.IsChecked)
        )
        [void]$behaviorLines.Add('')
        [void]$behaviorLines.Add('; Watches only for active effect changes made outside the macros.')
        [void]$behaviorLines.Add('; When that happens, preset/layout activation rules are applied to the new active effect.')
        Add-IniPair $behaviorLines 'WatchExternalEffectChanges' (
            ConvertTo-IniBoolean ([bool]$script:WatchExternalEffectChangesToggle.IsChecked)
        )
        [void]$behaviorLines.Add('')
        [void]$behaviorLines.Add('; Applies preset/layout rules to the currently active effect when the macros start.')
        Add-IniPair $behaviorLines 'ApplyPoliciesOnStartup' (
            ConvertTo-IniBoolean ([bool]$script:ApplyPoliciesOnStartupToggle.IsChecked)
        )
        Add-IniPair $behaviorLines 'RememberLastActiveEffectPreset' (
            ConvertTo-IniBoolean ([bool]$script:RememberLastActiveEffectPresetToggle.IsChecked)
        )
        [void]$behaviorLines.Add('')
        [void]$behaviorLines.Add('; Behaviour for Loading preset on effect activation.')
        [void]$behaviorLines.Add('; LastUsed or Preferred. Preferred uses the top preset in [PresetOrder.<Effect Name>].')
        Add-IniPair $behaviorLines 'PresetOnEffectActivation' (
            $(if ($script:PresetPreferredRadio.IsChecked) { 'Preferred' } else { 'LastUsed' })
        )
        [void]$behaviorLines.Add('')
        [void]$behaviorLines.Add('; Current or DefaultLayout')
        Add-IniPair $behaviorLines 'UnassignedEffectLayoutMode' (
            $(if ($script:UseDefaultLayoutRadio.IsChecked) { 'DefaultLayout' } else { 'Current' })
        )
        $defaultLayout = if ($script:DefaultLayoutComboBox.SelectedIndex -gt 0) {
            [string]$script:DefaultLayoutComboBox.SelectedItem
        }
        else {
            ''
        }
        Add-IniPair $behaviorLines 'DefaultLayout' $defaultLayout
        [void]$behaviorLines.Add('')
        Add-IniPair $behaviorLines 'ExcludeFromPickers' (
            ConvertTo-IniBoolean ([bool]$script:ExcludeFromPickersToggle.IsChecked)
        )
        Add-IniPair $behaviorLines 'ExcludeFromNextHotkeys' (
            ConvertTo-IniBoolean ([bool]$script:ExcludeFromNextHotkeysToggle.IsChecked)
        )
        Add-IniPair $behaviorLines 'ExcludeFromCycling' (
            ConvertTo-IniBoolean ([bool]$script:ExcludeFromCyclingToggle.IsChecked)
        )
        Add-UnknownEntries $behaviorLines $behaviorUnknown
        [void]$behaviorLines.Add('')
        [void]$behaviorLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'Behavior' $behaviorLines
        Remove-IniSection $lines 'PreferredPresets'

        $effectKnownKeys = Get-CurrentEffectKnownKeys
        $unknownEffectOrder = Get-UnknownOrderedValues `
            -Section 'EffectOrder' `
            -KnownValues $effectKnownKeys
        $effectOrderLines = [Collections.ArrayList]::new()
        [void]$effectOrderLines.Add('; The order for pickers, go-to-next hotkeys, and cycling')
        [void]$effectOrderLines.Add('; Format: 001=Effect Name')
        $effectOrderIndex = 1

        foreach ($effect in $script:Effects) {
            Add-IniPair `
                -Lines $effectOrderLines `
                -Key ('{0:D3}' -f $effectOrderIndex) `
                -Value (Get-EffectConfigKey -Effect $effect)
            $effectOrderIndex++
        }

        foreach ($unknownValue in $unknownEffectOrder) {
            Add-IniPair `
                -Lines $effectOrderLines `
                -Key ('{0:D3}' -f $effectOrderIndex) `
                -Value $unknownValue
            $effectOrderIndex++
        }

        [void]$effectOrderLines.Add('')
        [void]$effectOrderLines.Add('; [PresetOrder.<Effect Name>]')
        [void]$effectOrderLines.Add('; The order for pickers, go-to-next hotkeys, and cycling.')
        [void]$effectOrderLines.Add('; Format: 001=Preset Name')

        Set-IniSectionLines $lines 'EffectOrder' $effectOrderLines

        $unknownIgnoredEffects = Get-UnknownSectionEntries `
            -Section 'IgnoredEffects' `
            -KnownKeys $effectKnownKeys
        $ignoredEffectLines = [Collections.ArrayList]::new()
        [void]$ignoredEffectLines.Add('; Exclude effects from pickers, go-to-next hotkeys, and/or cycling')
        [void]$ignoredEffectLines.Add('; Format: Effect Name')

        foreach ($effect in $script:Effects) {
            if ($effect.Ignored) {
                Add-IniEntry `
                    -Lines $ignoredEffectLines `
                    -Value (Get-EffectConfigKey -Effect $effect)
            }
        }

        Add-UnknownEntries $ignoredEffectLines $unknownIgnoredEffects -BareTrue
        Set-IniSectionLines $lines 'IgnoredEffects' $ignoredEffectLines

        $ignoredPresetKnownKeys = [Collections.ArrayList]::new()
        $ignoredPresetLines = [Collections.ArrayList]::new()
        [void]$ignoredPresetLines.Add('; Exclude presets from pickers, go-to-next hotkeys, and/or cycling')
        [void]$ignoredPresetLines.Add('; Format: Effect Name|Preset Name')

        foreach ($effect in $script:Effects) {
            foreach ($preset in $effect.Presets) {
                $ignoredPresetKey = (
                    Get-EffectConfigKey -Effect $effect
                ) + '|' + $preset.Name
                [void]$ignoredPresetKnownKeys.Add($ignoredPresetKey)

                if ($preset.Ignored) {
                    Add-IniEntry $ignoredPresetLines $ignoredPresetKey
                }
            }
        }

        $unknownIgnoredPresets = Get-UnknownSectionEntries `
            -Section 'IgnoredPresets' `
            -KnownKeys $ignoredPresetKnownKeys
        Add-UnknownEntries $ignoredPresetLines $unknownIgnoredPresets -BareTrue
        Set-IniSectionLines $lines 'IgnoredPresets' $ignoredPresetLines

        $unknownFavoriteEffects = Get-UnknownSectionEntries `
            -Section 'FavoriteEffects' `
            -KnownKeys $effectKnownKeys
        $favoriteEffectLines = [Collections.ArrayList]::new()
        [void]$favoriteEffectLines.Add('; Starred effects in the config editor')
        [void]$favoriteEffectLines.Add('; Format: Effect Name')

        foreach ($effect in $script:Effects) {
            if ($effect.Favorite) {
                Add-IniEntry `
                    -Lines $favoriteEffectLines `
                    -Value (Get-EffectConfigKey -Effect $effect)
            }
        }

        Add-UnknownEntries $favoriteEffectLines $unknownFavoriteEffects -BareTrue
        Set-IniSectionLines $lines 'FavoriteEffects' $favoriteEffectLines

        $favoritePresetKnownKeys = [Collections.ArrayList]::new()
        $favoritePresetLines = [Collections.ArrayList]::new()
        [void]$favoritePresetLines.Add('; Starred presets in the config editor')
        [void]$favoritePresetLines.Add('; Format: Effect Name|Preset Name')

        foreach ($effect in $script:Effects) {
            foreach ($preset in $effect.Presets) {
                $favoritePresetKey = (
                    Get-EffectConfigKey -Effect $effect
                ) + '|' + $preset.Name
                [void]$favoritePresetKnownKeys.Add($favoritePresetKey)

                if ($preset.Favorite) {
                    Add-IniEntry $favoritePresetLines $favoritePresetKey
                }
            }
        }

        $unknownFavoritePresets = Get-UnknownSectionEntries `
            -Section 'FavoritePresets' `
            -KnownKeys $favoritePresetKnownKeys
        Add-UnknownEntries $favoritePresetLines $unknownFavoritePresets -BareTrue
        Set-IniSectionLines $lines 'FavoritePresets' $favoritePresetLines

        $unknownEffectLayouts = Get-UnknownSectionEntries `
            -Section 'EffectLayouts' `
            -KnownKeys $effectKnownKeys
        $effectLayoutLines = [Collections.ArrayList]::new()
        [void]$effectLayoutLines.Add('; Assign layouts to effects.')
        [void]$effectLayoutLines.Add('; Format: Effect Name=Layout Name')

        foreach ($effect in $script:Effects) {
            if (-not [string]::IsNullOrWhiteSpace($effect.Layout)) {
                Add-IniPair `
                    $effectLayoutLines `
                    (Get-EffectConfigKey -Effect $effect) `
                    $effect.Layout
            }
        }

        Add-UnknownEntries $effectLayoutLines $unknownEffectLayouts

        foreach ($effect in $script:Effects) {
            $presetNames = @($effect.Presets | ForEach-Object { $_.Name })
            $presetOrderSection = 'PresetOrder.' + $effect.Name
            $unknownPresetOrder = Get-UnknownOrderedValues `
                -Section $presetOrderSection `
                -KnownValues $presetNames

            $presetOrderLines = [Collections.ArrayList]::new()
            [void]$presetOrderLines.Add('; Format: 001=Preset Name')
            $presetOrderIndex = 1

            foreach ($preset in $effect.Presets) {
                Add-IniPair `
                    -Lines $presetOrderLines `
                    -Key ('{0:D3}' -f $presetOrderIndex) `
                    -Value $preset.Name
                $presetOrderIndex++
            }

            foreach ($unknownValue in $unknownPresetOrder) {
                Add-IniPair `
                    -Lines $presetOrderLines `
                    -Key ('{0:D3}' -f $presetOrderIndex) `
                    -Value $unknownValue
                $presetOrderIndex++
            }

            if ($presetOrderLines.Count -gt 1) {
                Set-IniSectionLines $lines $presetOrderSection $presetOrderLines
            }
            else {
                Remove-IniSection $lines $presetOrderSection
            }

            Remove-IniSection $lines ('PresetOrder.' + $effect.Id)

            Remove-IniSection $lines ('IgnoredPresets.' + $effect.Id)
        }

        foreach ($sectionName in @($script:ConfigDocument.Sections.Keys)) {
            if (
                ([string]$sectionName).StartsWith(
                    'IgnoredPresets.',
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                Remove-IniSection $lines ([string]$sectionName)
            }
        }

        $layoutNames = @($script:Layouts | ForEach-Object { $_.Name })
        $unknownLayoutOrder = Get-UnknownOrderedValues `
            -Section 'LayoutOrder' `
            -KnownValues $layoutNames
        $layoutOrderLines = [Collections.ArrayList]::new()
        [void]$layoutOrderLines.Add('; The order for pickers, go-to-next hotkeys, and cycling')
        [void]$layoutOrderLines.Add('; Format: 001=Layout Name')
        $layoutOrderIndex = 1

        foreach ($layout in $script:Layouts) {
            Add-IniPair `
                -Lines $layoutOrderLines `
                -Key ('{0:D3}' -f $layoutOrderIndex) `
                -Value $layout.Name
            $layoutOrderIndex++
        }

        foreach ($unknownValue in $unknownLayoutOrder) {
            Add-IniPair `
                -Lines $layoutOrderLines `
                -Key ('{0:D3}' -f $layoutOrderIndex) `
                -Value $unknownValue
            $layoutOrderIndex++
        }

        [void]$layoutOrderLines.Add('')
        [void]$layoutOrderLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'LayoutOrder' $layoutOrderLines

        $unknownIgnoredLayouts = Get-UnknownSectionEntries `
            -Section 'IgnoredLayouts' `
            -KnownKeys $layoutNames
        $ignoredLayoutLines = [Collections.ArrayList]::new()
        [void]$ignoredLayoutLines.Add('; Exclude layouts from pickers and/or go-to-next hotkeys')
        [void]$ignoredLayoutLines.Add('; Format: Layout Name')

        foreach ($layout in $script:Layouts) {
            if ($layout.Ignored) {
                Add-IniEntry $ignoredLayoutLines $layout.Name
            }
        }

        Add-UnknownEntries $ignoredLayoutLines $unknownIgnoredLayouts -BareTrue
        [void]$ignoredLayoutLines.Add('')
        [void]$ignoredLayoutLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'IgnoredLayouts' $ignoredLayoutLines

        $unknownFavoriteLayouts = Get-UnknownSectionEntries `
            -Section 'FavoriteLayouts' `
            -KnownKeys $layoutNames
        $favoriteLayoutLines = [Collections.ArrayList]::new()
        [void]$favoriteLayoutLines.Add('; Starred layouts in the config editor')
        [void]$favoriteLayoutLines.Add('; Format: Layout Name')

        foreach ($layout in $script:Layouts) {
            if ($layout.Favorite) {
                Add-IniEntry $favoriteLayoutLines $layout.Name
            }
        }

        Add-UnknownEntries $favoriteLayoutLines $unknownFavoriteLayouts -BareTrue
        [void]$favoriteLayoutLines.Add('')
        [void]$favoriteLayoutLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'FavoriteLayouts' $favoriteLayoutLines

        [void]$effectLayoutLines.Add('')
        [void]$effectLayoutLines.Add('; --------------------------')
        Set-IniSectionLines $lines 'EffectLayouts' $effectLayoutLines

        $content = ($lines -join "`r`n")
        $content = $content.TrimEnd([char[]]@([char]13, [char]10)) + "`r`n"
        $temporaryPath = $script:ConfigPath + '.' + $PID + '.tmp'
        $backupPath = $script:ConfigPath + '.' + $PID + '.bak'

        try {
            Write-Utf8NoBom -Path $temporaryPath -Content $content

            if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) {
                try {
                    [IO.File]::Replace(
                        $temporaryPath,
                        $script:ConfigPath,
                        $backupPath
                    )
                }
                catch {
                    [IO.File]::Copy(
                        $temporaryPath,
                        $script:ConfigPath,
                        $true
                    )
                }
            }
            else {
                [IO.File]::Move($temporaryPath, $script:ConfigPath)
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }

            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Remove-Item -LiteralPath $backupPath -Force
            }
        }

        $script:ConfigDocument = Read-IniDocument -Path $script:ConfigPath
        $script:LoadedCustomEffectOrderSnapshot = @(Get-EffectOrderKeys)
        $script:OwnCustomEffectOrderSnapshot = $null
        $script:InitialStateSignature = Get-EditorStateSignature
        $script:IsDirty = $false
        $script:SaveOccurred = $true

        $startupShortcutResult = Sync-LaunchOnStartupShortcut `
            -Enabled ([bool]$script:LaunchOnStartupToggle.IsChecked)

        if ($RestartAhk) {
            $restartResult = Restart-AhkScriptFromEditor

            if ($restartResult.Success) {
                if ($startupShortcutResult.Success) {
                    Set-SavedStatus
                }
                else {
                    Set-Status -Text $startupShortcutResult.Message -Kind Error
                }
            }
            else {
                Set-Status -Text $restartResult.Message -Kind Error
            }
        }
        else {
            if ($startupShortcutResult.Success) {
                Set-SavedStatus
            }
            else {
                Set-Status -Text $startupShortcutResult.Message -Kind Error
            }
        }

        return $true
    }
    catch {
        Set-Status `
            -Text ('Save failed: ' + $_.Exception.Message) `
            -Kind Error
        return $false
    }
}

function Invoke-InventoryUpdateFromEditor {
    if ($script:IsDirty -and -not (Save-Configuration)) {
        return
    }

    $updaterText = ([string]$script:UpdaterScriptTextBox.Text).Trim()

    if ([string]::IsNullOrWhiteSpace($updaterText)) {
        $updaterText = 'scripts\inventory-creator-updater.ps1'
    }

    $updaterPath = Resolve-ProjectPath $updaterText

    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        Set-Status `
            -Text ('Inventory updater not found: ' + $updaterText) `
            -Kind Error
        return
    }

    Set-Status -Text 'Updating inventory...' -Kind Accent
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait

    try {
        if (-not (Invoke-InventoryUpdaterProcess -UpdaterPath $updaterPath)) {
            return
        }

        Reload-EditorData
        Set-Status -Text 'Inventory updated' -Kind Accent
    }
    catch {
        Set-Status `
            -Text ('Inventory update failed: ' + $_.Exception.Message) `
            -Kind Error
    }
    finally {
        $script:IsInitializing = $false
        $script:Window.Cursor = $null
    }
}

function Invoke-InventoryUpdaterProcess {
    param(
        [Parameter(Mandatory)]
        [string]$UpdaterPath
    )

    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = 'powershell.exe'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.WorkingDirectory = $script:ProjectRoot

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $UpdaterPath,
        '-OutputFolder',
        $script:ProjectRoot,
        '-NonInteractive',
        '-Quiet'
    )

    $process.StartInfo.Arguments = (
        $arguments |
            ForEach-Object {
                ConvertTo-ProcessArgument ([string]$_)
            }
    ) -join ' '

    [void]$process.Start()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -eq 0) {
        return $true
    }

    $message = if (-not [string]::IsNullOrWhiteSpace($standardError)) {
        $standardError.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($standardOutput)) {
        $standardOutput.Trim()
    }
    else {
        'Inventory updater exited with code ' + $process.ExitCode
    }

    Set-Status -Text $message -Kind Error
    return $false
}

function Reload-EditorData {
    $script:IsInitializing = $true

    try {
        Initialize-Models
        Initialize-ControlValues
        Refresh-LayoutsView
        Refresh-EffectsView
        $script:InitialStateSignature = Get-EditorStateSignature
        $script:IsDirty = $false
    }
    finally {
        $script:IsInitializing = $false
    }
}

function ConvertTo-ProcessArgument {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Show-ThemedChoiceDialog {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [object[]]$Buttons,

        [string]$AccentButton = ''
    )

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="360"
        SizeToContent="Height"
        WindowStyle="None"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0E0E12"
        Foreground="#F4F1FB"
        FontFamily="Segoe UI"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="DialogTextBrush" Color="#F4F1FB" />
        <SolidColorBrush x:Key="DialogRaisedBrush" Color="#1E1E26" />
        <SolidColorBrush x:Key="DialogHoverBrush" Color="#272631" />
        <SolidColorBrush x:Key="DialogBorderBrush" Color="#363440" />
        <SolidColorBrush x:Key="DialogAccentBrush" Color="#6253EC" />
        <SolidColorBrush x:Key="DialogAccentHoverBrush" Color="#7A6FFF" />
        <Style x:Key="DialogButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource DialogTextBrush}" />
            <Setter Property="Background" Value="{StaticResource DialogRaisedBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource DialogBorderBrush}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="12,7" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border
                            x:Name="ButtonBorder"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="5"
                            Padding="{TemplateBinding Padding}">
                            <ContentPresenter
                                HorizontalAlignment="Center"
                                VerticalAlignment="Center"
                                RecognizesAccessKey="True" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{StaticResource DialogAccentBrush}" />
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.82" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{StaticResource DialogHoverBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource DialogAccentBrush}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="DialogPrimaryButtonStyle" TargetType="Button" BasedOn="{StaticResource DialogButtonStyle}">
            <Setter Property="Background" Value="{StaticResource DialogAccentBrush}" />
            <Setter Property="BorderBrush" Value="{StaticResource DialogAccentBrush}" />
            <Setter Property="Foreground" Value="#FFFFFF" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{StaticResource DialogAccentHoverBrush}" />
                    <Setter Property="BorderBrush" Value="{StaticResource DialogAccentHoverBrush}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="DialogDangerButtonStyle" TargetType="Button" BasedOn="{StaticResource DialogButtonStyle}">
            <Setter Property="Background" Value="#8F2638" />
            <Setter Property="BorderBrush" Value="#B0334B" />
            <Setter Property="Foreground" Value="#FFFFFF" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#B0334B" />
                    <Setter Property="BorderBrush" Value="#CC4961" />
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Border Background="#17171D" BorderBrush="#363440" BorderThickness="1" CornerRadius="6">
        <Grid Margin="16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>
            <TextBlock x:Name="DialogTitle" FontSize="15" FontWeight="SemiBold" Foreground="#F4F1FB" />
            <TextBlock x:Name="DialogMessage" Grid.Row="1" Margin="0,10,0,18"
                       FontSize="12" Foreground="#C8C2D4" TextWrapping="Wrap" />
            <StackPanel x:Name="DialogButtons" Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" />
        </Grid>
    </Border>
</Window>
'@

    $dialog = ConvertFrom-XamlString -Xaml $xaml
    $dialog.Owner = $script:Window
    $dialog.Title = $Title

    $titleText = $dialog.FindName('DialogTitle')
    $messageText = $dialog.FindName('DialogMessage')
    $buttonPanel = $dialog.FindName('DialogButtons')
    $titleText.Text = $Title
    $messageText.Text = $Message

    $result = $null

    foreach ($buttonSpec in $Buttons) {
        $button = [Windows.Controls.Button]::new()
        $button.Content = [string]$buttonSpec.Label
        $button.Tag = [string]$buttonSpec.Value
        $button.Margin = [Windows.Thickness]::new(7, 0, 0, 0)
        $button.Padding = [Windows.Thickness]::new(12, 7, 12, 7)
        $button.FontSize = 12
        $button.FontWeight = [Windows.FontWeights]::SemiBold
        $button.Cursor = [Windows.Input.Cursors]::Hand
        $button.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')

        if ([string]$buttonSpec.Value -eq $AccentButton) {
            $button.Style = $dialog.FindResource('DialogPrimaryButtonStyle')
        }
        elseif ($buttonSpec.PSObject.Properties.Name -contains 'Danger' -and $buttonSpec.Danger) {
            $button.Style = $dialog.FindResource('DialogDangerButtonStyle')
        }
        else {
            $button.Style = $dialog.FindResource('DialogButtonStyle')
        }

        [void]$buttonPanel.Children.Add($button)
        $button.Add_Click({
            param($sender)
            $dialog.Tag = [string]$sender.Tag
            try {
                $dialog.DialogResult = $true
            }
            catch {
            }
            $dialog.Close()
        }.GetNewClosure())
    }

    [void]$dialog.ShowDialog()
    $result = [string]$dialog.Tag

    return $result
}

function Export-ConfigFromEditor {
    if ($script:IsDirty) {
        $choice = Show-ThemedChoiceDialog `
            -Title 'Save before export?' `
            -Message 'You have unsaved changes. Save them before exporting this config?' `
            -Buttons @(
                [pscustomobject]@{ Label = 'Cancel'; Value = 'Cancel' },
                [pscustomobject]@{ Label = 'Save and export'; Value = 'Save' }
            ) `
            -AccentButton 'Save'

        if ($choice -ne 'Save') {
            return
        }

        if (-not (Save-Configuration -RestartAhk)) {
            return
        }
    }

    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'Export config'
    $dialog.Filter = 'INI files (*.ini)|*.ini|All files (*.*)|*.*'
    $dialog.DefaultExt = '.ini'
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    $dialog.InitialDirectory = $script:ProjectRoot
    $dialog.FileName = 'SignalRGB-Pro-Switcher-config.ini'

    if ($dialog.ShowDialog($script:Window) -ne $true) {
        return
    }

    try {
        [IO.File]::Copy(
            $script:ConfigPath,
            $dialog.FileName,
            $true
        )
        Set-Status -Text 'Config exported' -Kind Accent
    }
    catch {
        Set-Status `
            -Text ('Export failed: ' + $_.Exception.Message) `
            -Kind Error
    }
}

function Import-ConfigFromEditor {
    if ($script:IsDirty) {
        $choice = Show-ThemedChoiceDialog `
            -Title 'Import config?' `
            -Message 'Importing a config will replace the current config.ini and discard unsaved editor changes.' `
            -Buttons @(
                [pscustomobject]@{ Label = 'Cancel'; Value = 'Cancel' },
                [pscustomobject]@{ Label = 'Discard and import'; Value = 'Import'; Danger = $true }
            ) `
            -AccentButton ''

        if ($choice -ne 'Import') {
            return
        }
    }

    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Import config'
    $dialog.Filter = 'INI files (*.ini)|*.ini|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    $dialog.InitialDirectory = $script:ProjectRoot

    if ($dialog.ShowDialog($script:Window) -ne $true) {
        return
    }

    try {
        $selectedPath = [IO.Path]::GetFullPath($dialog.FileName)
        $targetPath = [IO.Path]::GetFullPath($script:ConfigPath)

        if (-not (Test-SameText $selectedPath $targetPath)) {
            [IO.File]::Copy(
                $selectedPath,
                $targetPath,
                $true
            )
        }

        Reload-EditorData
        $script:SaveOccurred = $true

        $restartResult = Restart-AhkScriptFromEditor

        if ($restartResult.Success) {
            Set-Status -Text 'Config imported' -Kind Accent
        }
        else {
            Set-Status `
                -Text ('Imported, but ' + $restartResult.Message) `
                -Kind Error
        }
    }
    catch {
        Set-Status `
            -Text ('Import failed: ' + $_.Exception.Message) `
            -Kind Error
    }
}

function Reset-ConfigurationFromEditor {
    $result = Show-ThemedChoiceDialog `
        -Title 'Reset config?' `
        -Message (
            "This will reset config.ini back to defaults and remove your custom configuration, including effect order, preset order, ignored items, favorites, assigned layouts, cycling, hotkeys, and settings.`n`nInventory files will be regenerated after the reset."
        ) `
        -Buttons @(
            [pscustomobject]@{ Label = 'Cancel'; Value = 'Cancel' },
            [pscustomobject]@{ Label = 'Reset config'; Value = 'Reset'; Danger = $true }
        ) `
        -AccentButton ''

    if ($result -ne 'Reset') {
        return
    }

    $updaterPath = Resolve-ProjectPath 'scripts\inventory-creator-updater.ps1'

    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        Set-Status `
            -Text 'Reset failed: inventory updater was not found.' `
            -Kind Error
        return
    }

    Set-Status -Text 'Resetting config...' -Kind Accent
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait

    try {
        Write-Utf8NoBom `
            -Path $script:ConfigPath `
            -Content ((New-DefaultConfigText).Trim() + "`r`n")

        if (-not (Invoke-InventoryUpdaterProcess -UpdaterPath $updaterPath)) {
            return
        }

        Reload-EditorData
        $script:SaveOccurred = $true
        Set-Status -Text 'Config reset' -Kind Accent
    }
    catch {
        Set-Status `
            -Text ('Reset failed: ' + $_.Exception.Message) `
            -Kind Error
    }
    finally {
        $script:Window.Cursor = $null
    }
}

function Reset-InventoryFromEditor {
    if (
        -not (
            Confirm-EditorReset `
                -Title 'Reset inventory?' `
                -Message (
                    "This deletes the generated inventory files and rebuilds them from SignalRGB.`n`nYour config.ini customizations (order, ignores, favorites, settings) are kept."
                ) `
                -ConfirmLabel 'Reset inventory'
        )
    ) {
        return
    }

    $updaterPath = Resolve-ProjectPath 'scripts\inventory-creator-updater.ps1'

    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        Set-Status `
            -Text 'Reset failed: inventory updater was not found.' `
            -Kind Error
        return
    }

    Set-Status -Text 'Resetting inventory...' -Kind Accent
    $script:Window.Cursor = [Windows.Input.Cursors]::Wait

    try {
        foreach ($generatedPath in @(
            $script:InventoryPath,
            (Join-Path $script:ProjectRoot 'data\inventory.md')
        )) {
            if (
                -not [string]::IsNullOrWhiteSpace($generatedPath) -and
                (Test-Path -LiteralPath $generatedPath -PathType Leaf)
            ) {
                Remove-Item -LiteralPath $generatedPath -Force
            }
        }

        if (-not (Invoke-InventoryUpdaterProcess -UpdaterPath $updaterPath)) {
            return
        }

        Reload-EditorData
        $script:SaveOccurred = $true

        $restartResult = Restart-AhkScriptFromEditor

        if ($restartResult.Success) {
            Set-Status -Text 'Inventory reset' -Kind Accent
        }
        else {
            Set-Status `
                -Text ('Inventory reset, but ' + $restartResult.Message) `
                -Kind Error
        }
    }
    catch {
        Set-Status `
            -Text ('Inventory reset failed: ' + $_.Exception.Message) `
            -Kind Error
    }
    finally {
        $script:Window.Cursor = $null
    }
}

function Reset-EffectsTabFromEditor {
    if (
        -not (
            Confirm-EditorReset `
                -Title 'Reset effects tab?' `
                -Message (
                    "This resets the Effects tab custom order, ignores, and favorites, including presets. Assigned layouts on this tab are also cleared.`n`nThis is saved immediately."
                ) `
                -ConfirmLabel 'Reset effects'
        )
    ) {
        return
    }

    foreach ($effect in $script:Effects) {
        $effect.Ignored = $false
        $effect.Favorite = $false
        $effect.Layout = ''
        $effect.IsExpanded = $false

        foreach ($preset in $effect.Presets) {
            $preset.Ignored = $false
            $preset.Favorite = $false
        }

        $orderedPresets = @($effect.Presets | Sort-Object -Property Name)
        $effect.Presets.Clear()

        foreach ($preset in $orderedPresets) {
            $effect.Presets.Add($preset)
        }
    }

    $orderedEffects = @($script:Effects | Sort-Object -Property Name)
    $script:Effects.Clear()

    foreach ($effect in $orderedEffects) {
        $script:Effects.Add($effect)
    }

    $script:EffectsFilterSort = 'CustomOrder'
    Set-EffectsAssignmentFilterMode -Mode Off
    $script:EffectsFilterFavorites = $false
    $script:EffectsFilterIgnoredPlacement = ''
    $script:OwnCustomEffectOrderSnapshot = $null
    Update-EffectsFilterPanel
    Refresh-EffectsView
    Complete-EditorResetSave -SuccessText 'Effects tab reset'
}

function Reset-LayoutsTabFromEditor {
    if (
        -not (
            Confirm-EditorReset `
                -Title 'Reset layouts tab?' `
                -Message (
                    "This resets the Layouts tab custom order, ignores, and favorites.`n`nThis is saved immediately."
                ) `
                -ConfirmLabel 'Reset layouts'
        )
    ) {
        return
    }

    foreach ($layout in $script:Layouts) {
        $layout.Ignored = $false
        $layout.Favorite = $false
    }

    $orderedLayouts = @($script:Layouts | Sort-Object -Property Name)
    $script:Layouts.Clear()

    foreach ($layout in $orderedLayouts) {
        $script:Layouts.Add($layout)
    }

    Refresh-LayoutsView
    Complete-EditorResetSave -SuccessText 'Layouts tab reset'
}

function Reset-HotkeysFromEditor {
    if (
        -not (
            Confirm-EditorReset `
                -Title 'Reset hotkeys?' `
                -Message (
                    "This restores the default hotkeys.`n`nThis is saved immediately."
                ) `
                -ConfirmLabel 'Reset hotkeys'
        )
    ) {
        return
    }

    $controls = Get-HotkeyControls

    foreach ($key in $controls.Keys) {
        Set-HotkeyControlValue `
            -Control $controls[$key] `
            -AhkHotkey $script:HotkeyDefaults[$key]
    }

    [void](Update-HotkeyValidationMessage)
    Complete-EditorResetSave -SuccessText 'Hotkeys reset'
}

function Reset-SettingsFromEditor {
    if (
        -not (
            Confirm-EditorReset `
                -Title 'Reset settings?' `
                -Message (
                    "This restores the default Settings tab values.`n`nThis is saved immediately."
                ) `
                -ConfirmLabel 'Reset settings'
        )
    ) {
        return
    }

    $script:LaunchOnStartupToggle.IsChecked = $false
    $script:AutoUpdateInventoryToggle.IsChecked = $false
    Set-DurationTextBoxValue `
        -Control $script:AutoUpdateInventoryIntervalTextBox `
        -Value '0h 2m 30s'
    $script:ShowHotkeyNotificationsToggle.IsChecked = $true
    $script:LoggingToggle.IsChecked = $false
    $script:WatchExternalEffectChangesToggle.IsChecked = $true
    $script:ApplyPoliciesOnStartupToggle.IsChecked = $true
    $script:RememberLastActiveEffectPresetToggle.IsChecked = $true
    $script:ExcludeFromPickersToggle.IsChecked = $false
    $script:ExcludeFromNextHotkeysToggle.IsChecked = $true
    $script:ExcludeFromCyclingToggle.IsChecked = $true
    $script:PresetLastUsedRadio.IsChecked = $true
    $script:KeepCurrentLayoutRadio.IsChecked = $true
    $script:DefaultLayoutComboBox.SelectedIndex = 0
    $script:InventoryFileTextBox.Text = 'data\inventory.ini'
    $script:UpdaterScriptTextBox.Text = 'scripts\inventory-creator-updater.ps1'
    Update-EffectsFilterPanel

    Complete-EditorResetSave -SuccessText 'Settings reset'
}

function Reset-CyclingTabFromEditor {
    if (
        -not (
            Confirm-EditorReset `
                -Title 'Reset cycling tab?' `
                -Message (
                    "This restores the default Cycling tab values.`n`nThis is saved immediately."
                ) `
                -ConfirmLabel 'Reset cycling'
        )
    ) {
        return
    }

    $script:EffectCyclingEnabledToggle.IsChecked = $false
    Set-SelectedEffectCyclingMode 'Order'
    $script:CycleEffectOnceAllPresetsElapsedToggle.IsChecked = $false
    Set-DurationTextBoxValue `
        -Control $script:EffectCyclingIntervalTextBox `
        -Value '0h 15m 0s'
    $script:PresetCyclingEnabledToggle.IsChecked = $false
    Set-SelectedPresetCyclingMode 'Order'
    Set-DurationTextBoxValue `
        -Control $script:PresetCyclingIntervalTextBox `
        -Value '0h 15m 0s'
    Update-CyclingControlState
    Complete-EditorResetSave -SuccessText 'Cycling tab reset'
}

function Initialize-UiReferences {
    $script:MainTabs = Get-UiElement 'MainTabs'
    $script:StatusText = Get-UiElement 'StatusText'
    $script:ActiveEffectValueText = Get-UiElement 'ActiveEffectValueText'
    $script:ActivePresetValueText = Get-UiElement 'ActivePresetValueText'
    $script:ActiveLayoutValueText = Get-UiElement 'ActiveLayoutValueText'
    $script:EffectsCountText = Get-UiElement 'EffectsCountText'
    $script:LayoutsCountText = Get-UiElement 'LayoutsCountText'
    $script:EffectsPanel = Get-UiElement 'EffectsPanel'
    $script:LayoutsPanel = Get-UiElement 'LayoutsPanel'
    $script:EffectsFilterButton = Get-UiElement 'EffectsFilterButton'
    $script:EffectsFilterDismissLayer = Get-UiElement 'EffectsFilterDismissLayer'
    $script:EffectsFilterPanel = Get-UiElement 'EffectsFilterPanel'
    $script:EffectsFilterCustomOrderCheck = Get-UiElement 'EffectsFilterCustomOrderCheck'
    $script:EffectsFilterAzCheck = Get-UiElement 'EffectsFilterAzCheck'
    $script:EffectsFilterMostPresetsCheck = Get-UiElement 'EffectsFilterMostPresetsCheck'
    $script:EffectsFilterLeastPresetsCheck = Get-UiElement 'EffectsFilterLeastPresetsCheck'
    $script:EffectsFilterAssignedLayoutsCheck = Get-UiElement 'EffectsFilterAssignedLayoutsCheck'
    $script:EffectsFilterSpecificLayoutCheck = Get-UiElement 'EffectsFilterSpecificLayoutCheck'
    $script:EffectsFilterSpecificLayoutComboBox = Get-UiElement 'EffectsFilterSpecificLayoutComboBox'
    $script:EffectsFilterNoAssignedLayoutsCheck = Get-UiElement 'EffectsFilterNoAssignedLayoutsCheck'
    $script:EffectsFilterFavoritesCheck = Get-UiElement 'EffectsFilterFavoritesCheck'
    $script:EffectsFilterIgnoredLastCheck = Get-UiElement 'EffectsFilterIgnoredLastCheck'
    $script:EffectsFilterIgnoredFirstCheck = Get-UiElement 'EffectsFilterIgnoredFirstCheck'
    $script:EffectsFilterSetOrderButton = Get-UiElement 'EffectsFilterSetOrderButton'
    $script:EffectsFilterRevertOrderButton = Get-UiElement 'EffectsFilterRevertOrderButton'
    $script:EffectsScrollViewer = Get-UiElement 'EffectsScrollViewer'
    $script:LayoutsScrollViewer = Get-UiElement 'LayoutsScrollViewer'
    $script:SettingsScrollViewer = Get-UiElement 'SettingsScrollViewer'

    $script:EffectCyclingEnabledToggle = Get-UiElement 'EffectCyclingEnabledToggle'
    $script:EffectCyclingOrderRadio = Get-UiElement 'EffectCyclingOrderRadio'
    $script:EffectCyclingRandomRadio = Get-UiElement 'EffectCyclingRandomRadio'
    $script:CycleEffectOnceAllPresetsElapsedToggle = Get-UiElement 'CycleEffectOnceAllPresetsElapsedToggle'
    $script:EffectCyclingIntervalValidationText = Get-UiElement 'EffectCyclingIntervalValidationText'
    $script:EffectCyclingIntervalTextBox = Get-UiElement 'EffectCyclingIntervalTextBox'
    $script:PresetCyclingEnabledToggle = Get-UiElement 'PresetCyclingEnabledToggle'
    $script:PresetCyclingOrderRadio = Get-UiElement 'PresetCyclingOrderRadio'
    $script:PresetCyclingRandomRadio = Get-UiElement 'PresetCyclingRandomRadio'
    $script:PresetCyclingIntervalValidationText = Get-UiElement 'PresetCyclingIntervalValidationText'
    $script:PresetCyclingIntervalTextBox = Get-UiElement 'PresetCyclingIntervalTextBox'

    $script:NextPresetTextBox = Get-UiElement 'NextPresetTextBox'
    $script:NextEffectTextBox = Get-UiElement 'NextEffectTextBox'
    $script:NextLayoutTextBox = Get-UiElement 'NextLayoutTextBox'
    $script:ShowStatusTextBox = Get-UiElement 'ShowStatusTextBox'
    $script:PickPresetTextBox = Get-UiElement 'PickPresetTextBox'
    $script:PickEffectTextBox = Get-UiElement 'PickEffectTextBox'
    $script:PickLayoutTextBox = Get-UiElement 'PickLayoutTextBox'
    $script:OpenPickerMenuTextBox = Get-UiElement 'OpenPickerMenuTextBox'
    $script:HotkeyWarningText = Get-UiElement 'HotkeyWarningText'

    $script:AutoUpdateInventoryToggle = Get-UiElement 'AutoUpdateInventoryToggle'
    $script:LaunchOnStartupToggle = Get-UiElement 'LaunchOnStartupToggle'
    $script:AutoUpdateInventoryIntervalValidationText = Get-UiElement 'AutoUpdateInventoryIntervalValidationText'
    $script:AutoUpdateInventoryIntervalTextBox = Get-UiElement 'AutoUpdateInventoryIntervalTextBox'
    $script:ShowHotkeyNotificationsToggle = Get-UiElement 'ShowHotkeyNotificationsToggle'
    $script:WatchExternalEffectChangesToggle = Get-UiElement 'WatchExternalEffectChangesToggle'
    $script:ExcludeFromPickersToggle = Get-UiElement 'ExcludeFromPickersToggle'
    $script:RememberLastActiveEffectPresetToggle = Get-UiElement 'RememberLastActiveEffectPresetToggle'
    $script:ExcludeFromNextHotkeysToggle = Get-UiElement 'ExcludeFromNextHotkeysToggle'
    $script:ExcludeFromCyclingToggle = Get-UiElement 'ExcludeFromCyclingToggle'
    $script:PresetLastUsedRadio = Get-UiElement 'PresetLastUsedRadio'
    $script:PresetPreferredRadio = Get-UiElement 'PresetPreferredRadio'
    $script:PresetActivationOverrideText = Get-UiElement 'PresetActivationOverrideText'
    $script:ApplyPoliciesOnStartupToggle = Get-UiElement 'ApplyPoliciesOnStartupToggle'
    $script:KeepCurrentLayoutRadio = Get-UiElement 'KeepCurrentLayoutRadio'
    $script:UseDefaultLayoutRadio = Get-UiElement 'UseDefaultLayoutRadio'
    $script:DefaultLayoutComboBox = Get-UiElement 'DefaultLayoutComboBox'
    $script:LoggingToggle = Get-UiElement 'LoggingToggle'
    $script:InventoryFileTextBox = Get-UiElement 'InventoryFileTextBox'
    $script:UpdaterScriptTextBox = Get-UiElement 'UpdaterScriptTextBox'
    $script:ImportConfigButton = Get-UiElement 'ImportConfigButton'
    $script:ExportConfigButton = Get-UiElement 'ExportConfigButton'
    $script:AdvancedSettingsPanel = Get-UiElement 'AdvancedSettingsPanel'
    $script:AdvancedToggleArrow = Get-UiElement 'AdvancedToggleArrow'
    $script:ResetEffectsButton = Get-UiElement 'ResetEffectsButton'
    $script:ResetLayoutsButton = Get-UiElement 'ResetLayoutsButton'
    $script:ResetCyclingButton = Get-UiElement 'ResetCyclingButton'
    $script:ResetHotkeysButton = Get-UiElement 'ResetHotkeysButton'
    $script:ResetSettingsButton = Get-UiElement 'ResetSettingsButton'
    $script:ResetConfigButton = Get-UiElement 'ResetConfigButton'

    $script:AccentBrush = $script:Window.FindResource('AccentBrush')
    $script:AccentHoverBrush = $script:Window.FindResource('AccentHoverBrush')
    $script:ErrorBrush = $script:Window.FindResource('ErrorBrush')
    $script:BorderBrush = $script:Window.FindResource('BorderBrush')
    $script:SurfaceBrush = $script:Window.FindResource('SurfaceBrush')
    $script:RaisedBrush = $script:Window.FindResource('RaisedBrush')
    $script:HoverBrush = $script:Window.FindResource('HoverBrush')
    $script:TextBrush = $script:Window.FindResource('TextBrush')
    $script:MutedBrush = $script:Window.FindResource('MutedBrush')
    $script:DimBrush = $script:Window.FindResource('DimBrush')
    $script:TransparentBrush = $script:Window.FindResource('TransparentBrush')

    Register-DurationTextBox `
        -Control $script:AutoUpdateInventoryIntervalTextBox `
        -ValidationText $script:AutoUpdateInventoryIntervalValidationText `
        -Label 'Auto-update interval' `
        -Default '0h 2m 30s' `
        -TabIndex 4
    Register-DurationTextBox `
        -Control $script:EffectCyclingIntervalTextBox `
        -ValidationText $script:EffectCyclingIntervalValidationText `
        -Label 'Effect cycling interval' `
        -Default '0h 15m 0s' `
        -TabIndex 2
    Register-DurationTextBox `
        -Control $script:PresetCyclingIntervalTextBox `
        -ValidationText $script:PresetCyclingIntervalValidationText `
        -Label 'Preset cycling interval' `
        -Default '0h 15m 0s' `
        -TabIndex 2
}

function Initialize-ControlValues {
    $script:DefaultLayoutComboBox.Items.Clear()
    $script:EffectsFilterSpecificLayoutComboBox.Items.Clear()

    foreach ($key in (Get-HotkeyControls).Keys) {
        Set-HotkeyControlValue `
            -Control (Get-HotkeyControls)[$key] `
            -AhkHotkey (Get-IniValue `
            -Document $script:ConfigDocument `
            -Section 'Hotkeys' `
            -Key ([string]$key) `
            -Default $script:HotkeyDefaults[$key])
    }

    $script:AutoUpdateInventoryToggle.IsChecked = Test-IniTrue `
        -Value (
            Get-IniValue `
                $script:ConfigDocument `
                'Behavior' `
                'AutoUpdateInventory' `
                (
                    Get-IniValue `
                        $script:ConfigDocument `
                        'Integration' `
                        'AutoUpdateInventory' `
                        'false'
                )
        ) `
        -Default $false

    $script:LaunchOnStartupToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'LaunchOnStartup' 'false') `
        -Default $false

    Set-DurationTextBoxValue `
        -Control $script:AutoUpdateInventoryIntervalTextBox `
        -Value (Get-IniValue `
            $script:ConfigDocument `
            'Behavior' `
            'AutoUpdateInventoryInterval' `
            '0h 2m 30s')

    $script:ShowHotkeyNotificationsToggle.IsChecked = Test-IniTrue `
        -Value (
            Get-IniValue `
                $script:ConfigDocument `
                'Behavior' `
                'ShowHotkeyNotifications' `
                'true'
        ) `
        -Default $true

    $script:LoggingToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'Logging' 'false') `
        -Default $false

    $script:WatchExternalEffectChangesToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'WatchExternalEffectChanges' 'true') `
        -Default $true

    $script:ExcludeFromPickersToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'ExcludeFromPickers' 'false') `
        -Default $false

    $script:ExcludeFromNextHotkeysToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'ExcludeFromNextHotkeys' 'true') `
        -Default $true

    $script:ExcludeFromCyclingToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'ExcludeFromCycling' 'true') `
        -Default $true

    $script:ApplyPoliciesOnStartupToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'ApplyPoliciesOnStartup' 'true') `
        -Default $true

    $script:RememberLastActiveEffectPresetToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Behavior' 'RememberLastActiveEffectPreset' 'true') `
        -Default $true

    $script:EffectCyclingEnabledToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Cycling' 'EffectCyclingEnabled' 'false') `
        -Default $false
    $loadedEffectCyclingMode = Get-IniValue $script:ConfigDocument 'Cycling' 'EffectCyclingMode' 'Order'
    $cycleEffectOnceAllPresetsElapsed = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Cycling' 'CycleEffectOnceAllPresetsElapsed' 'false') `
        -Default $false
    if ($loadedEffectCyclingMode -match '^(?i:afterpreset|afterpresets|afterpresetselapsed|presetelapsed)$') {
        $cycleEffectOnceAllPresetsElapsed = $true
        $loadedEffectCyclingMode = 'Order'
    }
    Set-SelectedEffectCyclingMode $loadedEffectCyclingMode
    $script:CycleEffectOnceAllPresetsElapsedToggle.IsChecked = $cycleEffectOnceAllPresetsElapsed
    Set-DurationTextBoxValue `
        -Control $script:EffectCyclingIntervalTextBox `
        -Value (Get-IniValue `
            $script:ConfigDocument `
            'Cycling' `
            'EffectCyclingInterval' `
            '0h 15m 0s')

    $script:PresetCyclingEnabledToggle.IsChecked = Test-IniTrue `
        -Value (Get-IniValue $script:ConfigDocument 'Cycling' 'PresetCyclingEnabled' 'false') `
        -Default $false
    Set-SelectedPresetCyclingMode (
        Get-IniValue $script:ConfigDocument 'Cycling' 'PresetCyclingMode' 'Order'
    )
    Set-DurationTextBoxValue `
        -Control $script:PresetCyclingIntervalTextBox `
        -Value (Get-IniValue `
            $script:ConfigDocument `
            'Cycling' `
            'PresetCyclingInterval' `
            '0h 15m 0s')
    Update-CyclingControlState

    $presetMode = Get-IniValue `
        $script:ConfigDocument `
        'Behavior' `
        'PresetOnEffectActivation' `
        'LastUsed'

    if (Test-SameText $presetMode 'Preferred') {
        $script:PresetPreferredRadio.IsChecked = $true
    }
    else {
        $script:PresetLastUsedRadio.IsChecked = $true
    }

    Update-CyclingControlState

    $unassignedLayoutMode = Get-IniValue `
        $script:ConfigDocument `
        'Behavior' `
        'UnassignedEffectLayoutMode' `
        'Current'

    if (
        (Test-SameText $unassignedLayoutMode 'DefaultLayout') -or
        (Test-SameText $unassignedLayoutMode 'Preferred') -or
        (Test-SameText $unassignedLayoutMode 'Default')
    ) {
        $script:UseDefaultLayoutRadio.IsChecked = $true
    }
    else {
        $script:KeepCurrentLayoutRadio.IsChecked = $true
    }

    [void]$script:DefaultLayoutComboBox.Items.Add('(No default layout)')

    foreach ($layout in $script:Layouts) {
        [void]$script:DefaultLayoutComboBox.Items.Add($layout.Name)
    }

    $defaultLayout = Get-IniValue `
        $script:ConfigDocument `
        'Behavior' `
        'DefaultLayout' `
        ''

    $defaultLayoutIndex = 0

    if (-not [string]::IsNullOrWhiteSpace($defaultLayout)) {
        for (
            $index = 1;
            $index -lt $script:DefaultLayoutComboBox.Items.Count;
            $index++
        ) {
            if (Test-SameText $script:DefaultLayoutComboBox.Items[$index] $defaultLayout) {
                $defaultLayoutIndex = $index
                break
            }
        }

        if ($defaultLayoutIndex -eq 0) {
            [void]$script:DefaultLayoutComboBox.Items.Add($defaultLayout)
            $defaultLayoutIndex = $script:DefaultLayoutComboBox.Items.Count - 1
        }
    }

    $script:DefaultLayoutComboBox.SelectedIndex = $defaultLayoutIndex

    [void]$script:EffectsFilterSpecificLayoutComboBox.Items.Add('(Choose layout)')

    foreach ($layout in $script:Layouts) {
        [void]$script:EffectsFilterSpecificLayoutComboBox.Items.Add($layout.Name)
    }

    $script:EffectsFilterSpecificLayoutComboBox.SelectedIndex = 0
    $script:EffectsFilterSort = 'CustomOrder'
    $script:EffectsFilterAssignedLayouts = $false
    $script:EffectsFilterSpecificLayout = ''
    $script:EffectsFilterNoAssignedLayouts = $false
    $script:EffectsFilterIgnoredPlacement = ''
    $script:InventoryFileTextBox.Text = Get-IniValue `
        $script:ConfigDocument `
        'Assets' `
        'InventoryFile' `
        (
            Get-IniValue `
                $script:ConfigDocument `
                'Integration' `
                'InventoryFile' `
                'data\inventory.ini'
        )
    $script:UpdaterScriptTextBox.Text = Get-IniValue `
        $script:ConfigDocument `
        'Assets' `
        'UpdaterScript' `
        (
            Get-IniValue `
                $script:ConfigDocument `
                'Integration' `
                'UpdaterScript' `
                'scripts\inventory-creator-updater.ps1'
        )
}

function Test-IsInsideButton {
    param([AllowNull()]$Element)

    $current = $Element

    while ($null -ne $current) {
        if ($current -is [Windows.Controls.Primitives.ButtonBase]) {
            return $true
        }

        if ($current -eq $script:Window) {
            break
        }

        try {
            $current = [Windows.Media.VisualTreeHelper]::GetParent($current)
        }
        catch {
            break
        }
    }

    return $false
}

function Test-IsElementWithin {
    param(
        [AllowNull()]$Element,
        [AllowNull()]$Ancestor
    )

    if ($null -eq $Element -or $null -eq $Ancestor) {
        return $false
    }

    $current = $Element

    while ($null -ne $current) {
        if ($current -eq $Ancestor) {
            return $true
        }

        if ($current -eq $script:Window) {
            break
        }

        try {
            $current = [Windows.Media.VisualTreeHelper]::GetParent($current)
        }
        catch {
            break
        }
    }

    return $false
}

function Register-DirtyEvents {
    foreach ($textBox in @(
        $script:AutoUpdateInventoryIntervalTextBox,
        $script:EffectCyclingIntervalTextBox,
        $script:PresetCyclingIntervalTextBox,
        $script:InventoryFileTextBox,
        $script:UpdaterScriptTextBox
    )) {
        $textBox.Add_TextChanged({
            param($sender)
            if ($null -ne $sender.Tag -and $null -ne $sender.Tag.ValidationText) {
                Clear-AllDurationValidation
            }
            else {
                $sender.BorderBrush = $script:BorderBrush
            }
            Set-Dirty
        })
    }

    foreach ($durationTextBox in @(
        $script:AutoUpdateInventoryIntervalTextBox,
        $script:EffectCyclingIntervalTextBox,
        $script:PresetCyclingIntervalTextBox
    )) {
        $durationTextBox.Add_GotKeyboardFocus({
            param($sender)
            Clear-AllDurationValidation
        })
        $durationTextBox.Add_PreviewMouseLeftButtonDown({
            param($sender)
            Clear-AllDurationValidation
        })
        $durationTextBox.Add_LostFocus({
            param($sender)
            Confirm-DurationTextBox -Control $sender
        })
    }

    foreach ($toggle in @(
        $script:AutoUpdateInventoryToggle,
        $script:LaunchOnStartupToggle,
        $script:ShowHotkeyNotificationsToggle,
        $script:WatchExternalEffectChangesToggle,
        $script:ExcludeFromPickersToggle,
        $script:ExcludeFromNextHotkeysToggle,
        $script:ExcludeFromCyclingToggle,
        $script:RememberLastActiveEffectPresetToggle,
        $script:EffectCyclingEnabledToggle,
        $script:PresetCyclingEnabledToggle,
        $script:CycleEffectOnceAllPresetsElapsedToggle,
        $script:ApplyPoliciesOnStartupToggle,
        $script:LoggingToggle
    )) {
        $toggle.Add_Checked({
            Update-CyclingControlState
            Set-Dirty
        })
        $toggle.Add_Unchecked({
            Update-CyclingControlState
            Set-Dirty
        })
    }

    foreach ($radio in @(
        $script:PresetLastUsedRadio,
        $script:PresetPreferredRadio,
        $script:KeepCurrentLayoutRadio,
        $script:UseDefaultLayoutRadio,
        $script:EffectCyclingOrderRadio,
        $script:EffectCyclingRandomRadio,
        $script:PresetCyclingOrderRadio,
        $script:PresetCyclingRandomRadio
    )) {
        $radio.Add_Checked({
            Update-CyclingControlState
            Set-Dirty
        })
    }

    $script:DefaultLayoutComboBox.Add_SelectionChanged({ Set-Dirty })
    Register-HotkeyCaptureEvents
}

function Register-TextBoxWheelGuards {
    $script:AutoUpdateInventoryIntervalTextBox.Add_PreviewMouseWheel({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
    })
    $script:EffectCyclingIntervalTextBox.Add_PreviewMouseWheel({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
    })
    $script:PresetCyclingIntervalTextBox.Add_PreviewMouseWheel({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
    })
}

function Register-EffectsFilterEvents {
    $script:EffectsFilterCustomOrderCheck.Add_Click({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        $script:EffectsFilterSort = 'CustomOrder'
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterAzCheck.Add_Click({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        $script:EffectsFilterSort = 'A-Z'
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterMostPresetsCheck.Add_Click({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        $script:EffectsFilterSort = 'MostPresets'
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterLeastPresetsCheck.Add_Click({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        $script:EffectsFilterSort = 'LeastPresets'
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterAssignedLayoutsCheck.Add_Checked({
        if ($script:IsUpdatingEffectsFilterUi) { return }
        Set-EffectsAssignmentFilterMode -Mode Assigned
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })
    $script:EffectsFilterAssignedLayoutsCheck.Add_Unchecked({
        if ($script:IsUpdatingEffectsFilterUi) { return }
        if ($script:EffectsFilterAssignedLayouts) {
            Set-EffectsAssignmentFilterMode -Mode Off
        }
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterSpecificLayoutCheck.Add_Checked({
        if ($script:IsUpdatingEffectsFilterUi) { return }
        Set-EffectsAssignmentFilterMode -Mode Specific
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })
    $script:EffectsFilterSpecificLayoutCheck.Add_Unchecked({
        if ($script:IsUpdatingEffectsFilterUi) { return }
        if (-not [string]::IsNullOrWhiteSpace($script:EffectsFilterSpecificLayout)) {
            Set-EffectsAssignmentFilterMode -Mode Off
        }
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterSpecificLayoutComboBox.Add_SelectionChanged({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        if ($script:EffectsFilterSpecificLayoutComboBox.SelectedIndex -gt 0) {
            Set-EffectsAssignmentFilterMode -Mode Specific
        }
        else {
            Set-EffectsAssignmentFilterMode -Mode Off
        }

        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterNoAssignedLayoutsCheck.Add_Checked({
        if ($script:IsUpdatingEffectsFilterUi) { return }
        Set-EffectsAssignmentFilterMode -Mode None
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })
    $script:EffectsFilterNoAssignedLayoutsCheck.Add_Unchecked({
        if ($script:IsUpdatingEffectsFilterUi) { return }
        if ($script:EffectsFilterNoAssignedLayouts) {
            Set-EffectsAssignmentFilterMode -Mode Off
        }
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterFavoritesCheck.Add_Click({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        $script:EffectsFilterFavorites = [bool]$script:EffectsFilterFavoritesCheck.IsChecked
        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterIgnoredLastCheck.Add_Click({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        if (Test-SameText $script:EffectsFilterIgnoredPlacement 'Last') {
            $script:EffectsFilterIgnoredPlacement = ''
        }
        else {
            $script:EffectsFilterIgnoredPlacement = 'Last'
        }

        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterIgnoredFirstCheck.Add_Click({
        if ($script:IsUpdatingEffectsFilterUi) {
            return
        }

        if (Test-SameText $script:EffectsFilterIgnoredPlacement 'First') {
            $script:EffectsFilterIgnoredPlacement = ''
        }
        else {
            $script:EffectsFilterIgnoredPlacement = 'First'
        }

        Update-EffectsFilterState -AffectsSavedOrder:$true
    })

    $script:EffectsFilterSetOrderButton.Add_Click({
        $script:OwnCustomEffectOrderSnapshot = @(Get-EffectOrderKeys)
        Apply-EffectFilterOrderIfNeeded
        Set-Dirty
        Update-EffectsFilterPanel
        Refresh-EffectsView
    })

    $script:EffectsFilterRevertOrderButton.Add_Click({
        $revertKeys = if ($null -ne $script:OwnCustomEffectOrderSnapshot) {
            @($script:OwnCustomEffectOrderSnapshot)
        }
        else {
            @($script:LoadedCustomEffectOrderSnapshot)
        }

        $script:EffectsFilterSort = 'CustomOrder'
        Set-EffectsAssignmentFilterMode -Mode Off
        $script:EffectsFilterFavorites = $false
        $script:EffectsFilterIgnoredPlacement = ''

        if (
            $revertKeys.Count -gt 0 -and
            -not (Test-EffectOrderMatchesKeys -Keys $revertKeys)
        ) {
            Restore-EffectsOrderByKeys -Keys $revertKeys
            Set-Dirty
        }

        $script:OwnCustomEffectOrderSnapshot = $null
        Update-EffectsFilterPanel
        Refresh-EffectsView
    })
}

function Request-EditorClose {
    if ($script:ClosePromptActive) {
        return
    }

    if (-not $script:IsDirty) {
        $script:AllowClose = $true
        $script:Window.Close()
        return
    }

    $script:ClosePromptActive = $true

    try {
        $choice = Show-ThemedChoiceDialog `
            -Title 'Unsaved changes' `
            -Message 'You have unsaved config changes. What do you want to do before closing?' `
            -Buttons @(
                [pscustomobject]@{ Label = 'Cancel'; Value = 'Cancel' },
                [pscustomobject]@{ Label = 'Discard'; Value = 'Discard'; Danger = $true },
                [pscustomobject]@{ Label = 'Save and close'; Value = 'Save' }
            ) `
            -AccentButton 'Save'

        switch ($choice) {
            'Save' {
                if (Save-Configuration -RestartAhk) {
                    $script:AllowClose = $true
                    $script:Window.Close()
                }
            }
            'Discard' {
                $script:AllowClose = $true
                $script:Window.Close()
            }
        }
    }
    finally {
        $script:ClosePromptActive = $false
    }
}

function Save-WindowSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $script:Window.UpdateLayout()
    $width = [Math]::Max(1, [int][Math]::Ceiling($script:Window.ActualWidth))
    $height = [Math]::Max(1, [int][Math]::Ceiling($script:Window.ActualHeight))
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        $width,
        $height,
        96,
        96,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($script:Window)

    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    [void]$encoder.Frames.Add(
        [Windows.Media.Imaging.BitmapFrame]::Create($bitmap)
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath

    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }

    $stream = [IO.File]::Create($fullPath)

    try {
        $encoder.Save($stream)
    }
    finally {
        $stream.Dispose()
    }
}

function Register-StaticEvents {
    $windowDragArea = Get-UiElement 'WindowDragArea'
    $titleCloseButton = Get-UiElement 'TitleCloseButton'
    $updateInventoryButton = Get-UiElement 'UpdateInventoryButton'
    $saveButton = Get-UiElement 'SaveButton'
    $toggleAllEffectsButton = Get-UiElement 'ToggleAllEffectsButton'
    $effectsFilterButton = Get-UiElement 'EffectsFilterButton'
    $advancedToggleButton = Get-UiElement 'AdvancedToggleButton'
    $advancedToggleArrow = Get-UiElement 'AdvancedToggleArrow'
    $importConfigButton = Get-UiElement 'ImportConfigButton'
    $exportConfigButton = Get-UiElement 'ExportConfigButton'
    $resetInventoryButton = Get-UiElement 'ResetInventoryButton'
    $resetEffectsButton = Get-UiElement 'ResetEffectsButton'
    $resetLayoutsButton = Get-UiElement 'ResetLayoutsButton'
    $resetCyclingButton = Get-UiElement 'ResetCyclingButton'
    $resetHotkeysButton = Get-UiElement 'ResetHotkeysButton'
    $resetSettingsButton = Get-UiElement 'ResetSettingsButton'
    $resetConfigButton = Get-UiElement 'ResetConfigButton'
    $advancedSettingsPanel = [Windows.Controls.StackPanel](
        Get-UiElement 'AdvancedSettingsPanel'
    )

    $windowDragArea.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)

        if (
            $eventArgs.ChangedButton -eq [Windows.Input.MouseButton]::Left -and
            -not (Test-IsInsideButton $eventArgs.OriginalSource)
        ) {
            try {
                $script:Window.DragMove()
            }
            catch {
            }
        }
    })

    $titleCloseButton.Add_Click({ Request-EditorClose })
    $updateInventoryButton.Add_Click({ Invoke-InventoryUpdateFromEditor })
    $saveButton.Add_Click({ [void](Save-Configuration -RestartAhk) })
    $importConfigButton.Add_Click({ Import-ConfigFromEditor })
    $exportConfigButton.Add_Click({ Export-ConfigFromEditor })
    $resetInventoryButton.Add_Click({ Reset-InventoryFromEditor })
    $resetEffectsButton.Add_Click({ Reset-EffectsTabFromEditor })
    $resetLayoutsButton.Add_Click({ Reset-LayoutsTabFromEditor })
    $resetCyclingButton.Add_Click({ Reset-CyclingTabFromEditor })
    $resetHotkeysButton.Add_Click({ Reset-HotkeysFromEditor })
    $resetSettingsButton.Add_Click({ Reset-SettingsFromEditor })
    $resetConfigButton.Add_Click({ Reset-ConfigurationFromEditor })
    $effectsFilterButton.Add_Click({
        if ($script:EffectsFilterPanel.Visibility -eq [Windows.Visibility]::Visible) {
            Close-EffectsFilterPanel
        }
        else {
            Open-EffectsFilterPanel
        }
    })
    $script:EffectsFilterDismissLayer.Add_PreviewMouseLeftButtonDown({
        param($sender, $eventArgs)

        Close-EffectsFilterPanel
        $eventArgs.Handled = $true
    })
    $script:EffectsFilterDismissLayer.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)

        Close-EffectsFilterPanel
        $eventArgs.Handled = $true
    })

    $toggleAllEffectsButton.Add_Click({
        $visibleEffects = @(Get-VisibleEffects)
        $collapse = (
            $visibleEffects.Count -gt 0 -and
            @($visibleEffects | Where-Object { -not $_.IsExpanded }).Count -eq 0
        )

        foreach ($effect in $script:Effects) {
            $effect.IsExpanded = -not $collapse
        }

        Refresh-EffectsView
    })

    $filterClickAwayHandler = [Windows.Input.MouseButtonEventHandler]{
        param($sender, $eventArgs)

        if (
            $script:EffectsFilterPanel.Visibility -ne
            [Windows.Visibility]::Visible
        ) {
            return
        }

        if (
            (Test-IsElementWithin $eventArgs.OriginalSource $script:EffectsFilterPanel) -or
            (Test-IsElementWithin $eventArgs.OriginalSource $effectsFilterButton)
        ) {
            return
        }

        Close-EffectsFilterPanel
    }.GetNewClosure()

    $script:Window.AddHandler(
        [Windows.UIElement]::PreviewMouseDownEvent,
        $filterClickAwayHandler,
        $true
    )

    $advancedToggleButton.Add_Click({
        $script:AdvancedExpanded = -not $script:AdvancedExpanded

        if ($script:AdvancedExpanded) {
            $advancedSettingsPanel.SetCurrentValue(
                [Windows.UIElement]::VisibilityProperty,
                [Windows.Visibility]::Visible
            )
            $advancedToggleArrow.Text = '^'
        }
        else {
            $advancedSettingsPanel.SetCurrentValue(
                [Windows.UIElement]::VisibilityProperty,
                [Windows.Visibility]::Collapsed
            )
            $advancedToggleArrow.Text = 'v'
        }
    }.GetNewClosure())

    $script:Window.Add_Closing({
        param($sender, $eventArgs)

        if ($script:AllowClose -or -not $script:IsDirty) {
            Stop-ActiveStatusPolling
            return
        }

        $eventArgs.Cancel = $true

        if (-not $script:ClosePromptActive) {
            [void]$script:Window.Dispatcher.BeginInvoke(
                [Action]{ Request-EditorClose }
            )
        }
    })
}

try {
    Initialize-Models
    $script:Window = Import-WindowXaml
    Initialize-UiReferences
    Install-HotkeyClearButtons
    Initialize-ControlValues
    Update-EffectsFilterPanel
    Refresh-LayoutsView
    Refresh-EffectsView
    Register-DirtyEvents
    Register-EffectsFilterEvents
    Register-TextBoxWheelGuards
    Register-DragAutoScrollSupport
    Register-StaticEvents
    Start-ActiveStatusPolling
    $script:IsInitializing = $false
    $script:IsDirty = $false

    if (-not (Test-Path -LiteralPath $script:InventoryPath -PathType Leaf)) {
        Set-Status -Text 'Inventory missing. Run the inventory updater first.' -Kind Error
    }
    else {
        Set-Status -Text 'Showing current' -Kind Normal
    }

    $script:InitialStateSignature = Get-EditorStateSignature

    if (
        -not $ValidateOnly -and
        -not $TestSave -and
        [string]::IsNullOrWhiteSpace($SnapshotPath)
    ) {
        $startupShortcutResult = Sync-LaunchOnStartupShortcut `
            -Enabled ([bool]$script:LaunchOnStartupToggle.IsChecked)

        if (-not $startupShortcutResult.Success) {
            Set-Status -Text $startupShortcutResult.Message -Kind Error
        }
    }

    if ($ValidateOnly) {
        $presetCount = (
            $script:Effects |
            ForEach-Object { $_.Presets } |
            Measure-Object
        ).Count

        Write-Output (
            'GUI validation passed: {0} effects, {1} layouts, {2} presets.' -f
            $script:Effects.Count,
            $script:Layouts.Count,
            $presetCount
        )
        exit 0
    }

    if ($TestSave) {
        if (Save-Configuration) {
            exit 20
        }

        Write-Error $script:StatusText.Text
        exit 1
    }

    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        $snapshotTabIndexes = @{
            Effects = 0
            Layouts = 1
            Cycling = 2
            Hotkeys = 3
            Settings = 4
        }
        $script:MainTabs.SelectedIndex = $snapshotTabIndexes[$SnapshotTab]

        if ($SnapshotExpandFirst -and $script:Effects.Count -gt 0) {
            $effectToExpand = $script:Effects |
                Where-Object { $_.Presets.Count -gt 0 } |
                Select-Object -First 1

            if ($null -ne $effectToExpand) {
                $effectToExpand.IsExpanded = $true
                Refresh-EffectsView
            }
        }

        $script:Window.Add_ContentRendered({
            [void]$script:Window.Dispatcher.BeginInvoke(
                [Action]{
                    Save-WindowSnapshot -Path $SnapshotPath
                    $script:AllowClose = $true
                    $script:Window.Close()
                },
                [Windows.Threading.DispatcherPriority]::ContextIdle
            )
        }.GetNewClosure())
    }

    [void]$script:Window.ShowDialog()

    if ($script:SaveOccurred) {
        exit 20
    }

    exit 0
}
catch {
    $message = 'SignalRGB config editor failed.' + "`n`n" + $_.Exception.Message

    if (
        -not $ValidateOnly -and
        -not $TestSave -and
        $null -ne $script:Window
    ) {
        [void](Show-ThemedChoiceDialog `
            -Title 'SignalRGB Pro Switcher Free' `
            -Message $message `
            -Buttons @(
                [pscustomobject]@{ Label = 'OK'; Value = 'OK' }
            ) `
            -AccentButton 'OK')
    }

    Write-Error $message
    exit 1
}
