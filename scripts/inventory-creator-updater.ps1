#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputFolder = '',
    [switch]$NonInteractive,
    [switch]$Quiet
)

<#
.SYNOPSIS
    Creates config.ini when missing and creates or updates data\inventory.ini
    and data\inventory.md.

.DESCRIPTION
    Reads SignalRGB only. It never changes SignalRGB registry values, effects,
    presets, layouts, or processes. config.ini is user-editable; this updater
    only refreshes inventory-backed order sections and preserves existing user
    choices. data\inventory.ini and data\inventory.md are generated files.
    Each inventory update rewrites data\config.backup.ini with the config.ini
    contents from immediately before that update.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ConfigName = 'config.ini'
$InventoryName = 'inventory.ini'
$ReportName = 'inventory.md'
$UpdaterName = 'scripts\inventory-creator-updater.ps1'

$SignalRoot = 'HKCU:\SOFTWARE\WhirlwindFX\SignalRgb'
$EffectsRoot = Join-Path $SignalRoot 'effects'
$StatesRoot = Join-Path $SignalRoot 'states'
$SelectedEffectPath = Join-Path $EffectsRoot 'selected'
$LayoutsRoot = Join-Path $SignalRoot 'layouts'


function Write-Status {
    param(
        [AllowEmptyString()]
        [string]$Message,

        [ConsoleColor]$Color = 'Gray'
    )

    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}


function Read-ConsoleInput {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    Write-Host -NoNewline $Prompt
    return [Console]::ReadLine()
}


function Resolve-ProjectRoot {
    if (-not [string]::IsNullOrWhiteSpace($OutputFolder)) {
        $root = $OutputFolder.Trim().Trim('"')
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) {
        $scriptFolder = (
            Get-Item `
                -LiteralPath $PSScriptRoot `
                -ErrorAction Stop
        ).FullName

        if (
            (Split-Path -Path $scriptFolder -Leaf) -ieq 'scripts'
        ) {
            $root = Split-Path `
                -Path $scriptFolder `
                -Parent
        }
        else {
            $root = $scriptFolder
        }
    }
    else {
        $root = Join-Path `
            ([Environment]::GetFolderPath('Desktop')) `
            'SignalRGB-Pro-Switcher-Free'
    }

    if (
        -not $NonInteractive -and
        [string]::IsNullOrWhiteSpace($OutputFolder)
    ) {
        Write-Host ''
        Write-Host `
            'Paste the folder path where the SignalRGB-Pro-Switcher.ahk is held:' `
            -ForegroundColor Green

        do {
            $entered = Read-ConsoleInput 'Path> '

            if ($null -ne $entered) {
                $entered = $entered.Trim().Trim('"')
            }

            if ([string]::IsNullOrWhiteSpace($entered)) {
                Write-Host ''
                Write-Host 'A folder path is required.' -ForegroundColor Red
            }
        } while ([string]::IsNullOrWhiteSpace($entered))

        $root = $entered
    }

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $root `
            -Force |
            Out-Null
    }

    return (
        Get-Item `
            -LiteralPath $root `
            -ErrorAction Stop
    ).FullName
}


function Get-RegSubKeys {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return @(
        Get-ChildItem `
            -LiteralPath $Path `
            -ErrorAction SilentlyContinue |
            ForEach-Object {
                $_.PSChildName
            }
    )
}


function Get-RegValueNames {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        return @(
            (
                Get-Item `
                    -LiteralPath $Path `
                    -ErrorAction Stop
            ).GetValueNames()
        )
    }
    catch {
        return @()
    }
}


function Get-RegValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return (
            Get-Item `
                -LiteralPath $Path `
                -ErrorAction Stop
        ).GetValue(
            $Name,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::
                DoNotExpandEnvironmentNames
        )
    }
    catch {
        return $null
    }
}


function Clean {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return (
        (
            [string]$Value
        ).Replace(
            ([char]0).ToString(),
            ''
        ) -replace '[\r\n]+', ' '
    ).Trim()
}


function Get-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)

        return (
            [BitConverter]::ToString(
                $sha.ComputeHash($bytes)
            )
        ).Replace(
            '-',
            ''
        )
    }
    finally {
        $sha.Dispose()
    }
}


function Get-RecordKey {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('P', 'L')]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string]$Identity
    )

    $hash = Get-Sha256 `
        -Text (
            $Identity.ToLowerInvariant()
        )

    return '{0}_{1}' -f `
        $Prefix,
        $hash.Substring(
            0,
            20
        )
}


function Read-Ini {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $sections = @{}
    $section = ''

    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()

        if (
            -not $line -or
            $line.StartsWith(';') -or
            $line.StartsWith('#')
        ) {
            continue
        }

        if ($line -match '^\[(?<Name>[^\]]+)\]$') {
            $section = $Matches.Name.Trim()

            if (-not $sections.ContainsKey($section)) {
                $sections[$section] = @{}
            }

            continue
        }

        if (-not $section) {
            continue
        }

        $at = $line.IndexOf('=')

        if ($at -lt 0) {
            $key = $line
            $value = 'true'
        }
        else {
            $key = $line.Substring(
                0,
                $at
            ).Trim()

            $value = $line.Substring(
                $at + 1
            ).Trim()
        }

        if ($key) {
            $sections[$section][$key] = $value
        }
    }

    return $sections
}


function Get-ConfigSectionRange {
    param(
        [Parameter(Mandatory)]
        [object[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $start = -1
    $nextSection = $Lines.Count

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = ([string]$Lines[$i]).Trim()

        if ($line -match '^\[(?<Name>[^\]]+)\]$') {
            if ($start -ge 0) {
                $nextSection = $i
                break
            }

            if ($Matches.Name.Trim() -ieq $Name) {
                $start = $i
            }
        }
    }

    if ($start -lt 0) {
        return [pscustomobject]@{
            Start = -1
            End = -1
        }
    }

    $end = $nextSection
    $scan = $nextSection - 1

    while (
        $scan -gt $start -and
        [string]::IsNullOrWhiteSpace([string]$Lines[$scan])
    ) {
        $scan--
    }

    if (
        $scan -gt $start -and
        ([string]$Lines[$scan]).Trim() -match '^;\s*-{3,}\s*$'
    ) {
        $end = $scan
    }

    return [pscustomobject]@{
        Start = $start
        End = $end
    }
}


function Insert-ConfigLines {
    param(
        [Parameter(Mandatory)]
        [System.Collections.ArrayList]$Lines,

        [Parameter(Mandatory)]
        [int]$Index,

        [Parameter(Mandatory)]
        [object[]]$NewLines
    )

    for ($i = $NewLines.Count - 1; $i -ge 0; $i--) {
        $Lines.Insert(
            $Index,
            [string]$NewLines[$i]
        )
    }
}


function Set-ConfigSectionLines {
    param(
        [Parameter(Mandatory)]
        [System.Collections.ArrayList]$Lines,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string[]]$BodyLines = @(),

        [Parameter()]
        [string]$InsertBeforeSection = ''
    )

    $sectionLines = New-Object `
        System.Collections.ArrayList

    [void]$sectionLines.Add(
        '[' + $Name + ']'
    )

    foreach ($line in @($BodyLines)) {
        [void]$sectionLines.Add(
            [string]$line
        )
    }

    [void]$sectionLines.Add('')

    $range = Get-ConfigSectionRange `
        -Lines @($Lines.ToArray()) `
        -Name $Name

    if ($range.Start -ge 0) {
        $removeCount = $range.End - $range.Start

        if ($removeCount -gt 0) {
            $Lines.RemoveRange(
                $range.Start,
                $removeCount
            )
        }

        Insert-ConfigLines `
            -Lines $Lines `
            -Index $range.Start `
            -NewLines @($sectionLines.ToArray())

        return
    }

    $insertIndex = $Lines.Count

    if (-not [string]::IsNullOrWhiteSpace($InsertBeforeSection)) {
        $beforeRange = Get-ConfigSectionRange `
            -Lines @($Lines.ToArray()) `
            -Name $InsertBeforeSection

        if ($beforeRange.Start -ge 0) {
            $insertIndex = $beforeRange.Start
        }
    }

    if (
        $insertIndex -eq $Lines.Count -and
        $Lines.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$Lines[$Lines.Count - 1])
    ) {
        [void]$Lines.Add('')
        $insertIndex = $Lines.Count
    }

    Insert-ConfigLines `
        -Lines $Lines `
        -Index $insertIndex `
        -NewLines @($sectionLines.ToArray())
}


function Remove-ConfigSection {
    param(
        [Parameter(Mandatory)]
        [System.Collections.ArrayList]$Lines,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $range = Get-ConfigSectionRange `
        -Lines @($Lines.ToArray()) `
        -Name $Name

    if ($range.Start -lt 0) {
        return
    }

    $removeCount = $range.End - $range.Start

    if ($removeCount -gt 0) {
        $Lines.RemoveRange(
            $range.Start,
            $removeCount
        )
    }
}


function Get-OrderedConfigValues {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Sections,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $section = Get-Section `
        -Sections $Sections `
        -Name $Name

    $values = New-Object `
        System.Collections.ArrayList

    foreach ($entryKey in @($section.Keys | Sort-Object)) {
        $value = ([string]$section[$entryKey]).Trim()

        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        [void]$values.Add($value)
    }

    return @($values.ToArray())
}


function New-NormalizedLookup {
    param(
        [Parameter()]
        [object[]]$Values = @()
    )

    $lookup = @{}

    foreach ($value in @($Values)) {
        $text = ([string]$value).Trim()

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $lookup[$text.ToLowerInvariant()] = $text
    }

    return $lookup
}


function Merge-OrderedValues {
    param(
        [Parameter()]
        [object[]]$ExistingValues = @(),

        [Parameter()]
        [object[]]$DetectedValues = @()
    )

    $detectedLookup = New-NormalizedLookup `
        -Values @($DetectedValues)

    $seen = @{}
    $result = New-Object `
        System.Collections.ArrayList

    foreach ($value in @($ExistingValues)) {
        $text = ([string]$value).Trim()

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $normalized = $text.ToLowerInvariant()

        if ($seen.ContainsKey($normalized)) {
            continue
        }

        if ($detectedLookup.ContainsKey($normalized)) {
            [void]$result.Add($detectedLookup[$normalized])
        }
        else {
            [void]$result.Add($text)
        }

        $seen[$normalized] = $true
    }

    foreach ($value in @($DetectedValues)) {
        $text = ([string]$value).Trim()

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $normalized = $text.ToLowerInvariant()

        if ($seen.ContainsKey($normalized)) {
            continue
        }

        [void]$result.Add($text)
        $seen[$normalized] = $true
    }

    return @($result.ToArray())
}


function New-OrderSectionBody {
    param(
        [Parameter(Mandatory)]
        [string]$Format,

        [Parameter()]
        [string]$Note = '',

        [Parameter()]
        [object[]]$Values = @(),

        [Parameter()]
        [hashtable]$PresentLookup = @{},

        [Parameter()]
        [string[]]$FooterLines = @()
    )

    $lines = New-Object `
        System.Collections.ArrayList

    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        [void]$lines.Add(
            '; ' + $Note
        )
    }

    [void]$lines.Add(
        '; Format: ' + $Format
    )

    $index = 1

    foreach ($value in @($Values)) {
        $text = ([string]$value).Trim()

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if (
            $PresentLookup.Count -gt 0 -and
            -not $PresentLookup.ContainsKey($text.ToLowerInvariant())
        ) {
            [void]$lines.Add(
                '; No Longer Found'
            )
        }

        [void]$lines.Add(
            ('{0:D3}={1}' -f $index, $text)
        )

        $index++
    }

    foreach ($line in @($FooterLines)) {
        [void]$lines.Add(
            [string]$line
        )
    }

    return @($lines.ToArray())
}


function Test-UsableEffectRecord {
    param(
        [Parameter(Mandatory)]
        $Record
    )

    $name = ([string]$Record.Name).Trim()
    $normalizedName = $name.ToLowerInvariant()

    return (
        $Record.Status -eq 'Present' -and
        -not [string]::IsNullOrWhiteSpace($name) -and
        -not $normalizedName.StartsWith('[unusable effect ') -and
        -not $normalizedName.StartsWith('[unresolved effect ')
    )
}


function Update-ConfigInventorySections {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigText,

        [Parameter(Mandatory)]
        $Merged
    )

    $sections = Read-Ini $ConfigText

    $lines = New-Object `
        System.Collections.ArrayList

    foreach ($line in ($ConfigText -split "`r?`n")) {
        [void]$lines.Add($line)
    }

    while (
        $lines.Count -gt 0 -and
        [string]::IsNullOrWhiteSpace([string]$lines[$lines.Count - 1])
    ) {
        $lines.RemoveAt($lines.Count - 1)
    }

    $presentEffects = @(
        $Merged.Effects.Values |
            Where-Object {
                Test-UsableEffectRecord -Record $_
            } |
            Sort-Object Name, Id
    )

    $presentEffectNames = @(
        $presentEffects |
            ForEach-Object {
                [string]$_.Name
            }
    )

    $effectOrder = Merge-OrderedValues `
        -ExistingValues (
            Get-OrderedConfigValues `
                -Sections $sections `
                -Name 'EffectOrder' |
                Where-Object {
                    -not (Test-EffectId ([string]$_))
                }
        ) `
        -DetectedValues $presentEffectNames

    $effectLookup = New-NormalizedLookup `
        -Values $presentEffectNames

    Set-ConfigSectionLines `
        -Lines $lines `
        -Name 'EffectOrder' `
        -BodyLines (
            New-OrderSectionBody `
                -Format '001=Effect Name' `
                -Note 'The order for pickers, go-to-next hotkeys, and cycling' `
                -Values $effectOrder `
                -PresentLookup $effectLookup `
                -FooterLines @(
                    '',
                    '; [PresetOrder.<Effect Name>]',
                    '; The order for pickers, go-to-next hotkeys, and cycling.',
                    '; Format: 001=Preset Name'
                )
        )

    $unusableEffects = @(
        $Merged.Effects.Values |
            Where-Object {
                $_.Status -eq 'Present-Unusable'
            }
    )

    foreach ($effect in $unusableEffects) {
        Remove-ConfigSection `
            -Lines $lines `
            -Name ('PresetOrder.' + $effect.Id)

        Remove-ConfigSection `
            -Lines $lines `
            -Name ('PresetOrder.' + $effect.Name)
    }

    foreach ($effect in $presentEffects) {
        if (-not $Merged.Presets.ContainsKey($effect.Id)) {
            continue
        }

        $presetNames = @(
            $Merged.Presets[$effect.Id].Values |
                Where-Object {
                    $_.Status -eq 'Present'
                } |
                Sort-Object Name |
                ForEach-Object {
                    [string]$_.Name
                }
        )

        if (-not $presetNames.Count) {
            continue
        }

        $sectionName = 'PresetOrder.' + $effect.Name

        $presetOrder = Merge-OrderedValues `
            -ExistingValues (
                Get-OrderedConfigValues `
                    -Sections $sections `
                    -Name $sectionName
            ) `
            -DetectedValues $presetNames

        $presetLookup = New-NormalizedLookup `
            -Values $presetNames

        Set-ConfigSectionLines `
            -Lines $lines `
            -Name $sectionName `
            -BodyLines (
                New-OrderSectionBody `
                    -Format '001=Preset Name' `
                    -Values $presetOrder `
                    -PresentLookup $presetLookup
            ) `
            -InsertBeforeSection 'LayoutOrder'

        Remove-ConfigSection `
            -Lines $lines `
            -Name ('PresetOrder.' + $effect.Id)
    }

    $layoutNames = @(
        $Merged.Layouts.Values |
            Where-Object {
                $_.Status -eq 'Present'
            } |
            Sort-Object Name |
            ForEach-Object {
                [string]$_.Name
            }
    )

    $layoutOrder = Merge-OrderedValues `
        -ExistingValues (
            Get-OrderedConfigValues `
                -Sections $sections `
                -Name 'LayoutOrder'
        ) `
        -DetectedValues $layoutNames

    $layoutLookup = New-NormalizedLookup `
        -Values $layoutNames

    Set-ConfigSectionLines `
        -Lines $lines `
        -Name 'LayoutOrder' `
        -BodyLines (
            New-OrderSectionBody `
                -Format '001=Layout Name' `
                -Note 'The order for pickers, go-to-next hotkeys, and cycling' `
                -Values $layoutOrder `
                -PresentLookup $layoutLookup
        )

    return (
        (@($lines.ToArray()) -join "`r`n").TrimEnd() +
        "`r`n"
    )
}


function Get-Section {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Sections,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Sections.ContainsKey($Name)) {
        return $Sections[$Name]
    }

    return @{}
}


function Get-PreviousInventory {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Sections
    )

    $effects = @{}

    $effectNames = Get-Section `
        -Sections $Sections `
        -Name 'Effects'

    $effectStatus = Get-Section `
        -Sections $Sections `
        -Name 'EffectInventoryStatus'

    foreach ($id in $effectNames.Keys) {
        $status = if ($effectStatus.ContainsKey($id)) {
            [string]$effectStatus[$id]
        }
        else {
            'Present'
        }

        $name = [string]$effectNames[$id]

        if (
            $name.Trim().ToLowerInvariant().StartsWith('[unusable effect ')
        ) {
            $status = 'Present-Unusable'
        }

        $effects[$id] = [pscustomobject]@{
            Id = $id
            Name = $name
            Status = $status
        }
    }

    $presets = @{}

    foreach ($sectionName in $Sections.Keys) {
        if (
            -not $sectionName.StartsWith(
                'Presets.',
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            continue
        }

        $id = $sectionName.Substring(8)

        $names = Get-Section `
            -Sections $Sections `
            -Name $sectionName

        $statuses = Get-Section `
            -Sections $Sections `
            -Name (
                'PresetInventoryStatus.' +
                $id
            )

        $records = @{}

        foreach ($key in $names.Keys) {
            $status = if ($statuses.ContainsKey($key)) {
                [string]$statuses[$key]
            }
            else {
                'Present'
            }

            $records[$key] = [pscustomobject]@{
                Key = $key
                Name = [string]$names[$key]
                Status = $status
            }
        }

        $presets[$id] = $records
    }

    $layouts = @{}

    $layoutNames = Get-Section `
        -Sections $Sections `
        -Name 'Layouts'

    $layoutStatus = Get-Section `
        -Sections $Sections `
        -Name 'LayoutInventoryStatus'

    foreach ($key in $layoutNames.Keys) {
        $status = if ($layoutStatus.ContainsKey($key)) {
            [string]$layoutStatus[$key]
        }
        else {
            'Present'
        }

        $layouts[$key] = [pscustomobject]@{
            Key = $key
            Name = [string]$layoutNames[$key]
            Status = $status
        }
    }

    return [pscustomobject]@{
        Effects = $effects
        Presets = $presets
        Layouts = $layouts

        Meta = Get-Section `
            -Sections $Sections `
            -Name 'InventoryMeta'
    }
}


function Convert-PreviousInventoryToCurrent {
    param(
        [Parameter(Mandatory)]
        $Previous
    )

    $effects = @{}

    foreach ($id in $Previous.Effects.Keys) {
        $old = $Previous.Effects[$id]

        if (
            $old.Status -ne 'Present' -and
            $old.Status -ne 'Present-Unusable'
        ) {
            continue
        }

        $effects[$id] = [pscustomobject]@{
            Id = $id
            Name = $old.Name
            Status = $old.Status
            Source = 'Previous generated inventory'
        }
    }

    $presets = @{}

    foreach ($id in $Previous.Presets.Keys) {
        $names = @(
            $Previous.Presets[$id].Values |
                Where-Object {
                    $_.Status -eq 'Present'
                } |
                Sort-Object Name |
                ForEach-Object {
                    [string]$_.Name
                }
        )

        if ($names.Count) {
            $presets[$id] = $names
        }
    }

    $layouts = @(
        $Previous.Layouts.Values |
            Where-Object {
                $_.Status -eq 'Present'
            } |
            Sort-Object Name |
            ForEach-Object {
                [string]$_.Name
            }
    )

    return [pscustomobject]@{
        Effects = $effects
        Presets = $presets
        Layouts = $layouts
        Roots = @()
        LiveRegistryAvailable = $false

        Current = [pscustomobject]@{
            EffectId = ''
            EffectName = ''
            Preset = ''
            Layout = ''
        }
    }
}


function Test-EffectId {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return (
        $Value -match '^-[A-Za-z0-9_-]{10,}$' -or
        $Value -match (
            '^[0-9a-fA-F]{8}-' +
            '[0-9a-fA-F]{4}-' +
            '[0-9a-fA-F]{4}-' +
            '[0-9a-fA-F]{4}-' +
            '[0-9a-fA-F]{12}$'
        ) -or
        $Value -match '(?i)\.html?$'
    )
}


function Add-EffectCandidate {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$List,

        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$Confidence,

        [Parameter(Mandatory)]
        [string]$Source
    )

    $Id = Clean $Id
    $Name = Clean $Name

    if (
        -not $Id -or
        -not $Name -or
        -not (Test-EffectId $Id)
    ) {
        return
    }

    [void]$List.Add(
        [pscustomobject]@{
            Id = $Id
            Name = $Name
            Confidence = $Confidence
            Source = $Source
        }
    )
}


function Remove-SuspiciousCandidates {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Candidates
    )

    $remove = New-Object `
        System.Collections.ArrayList

    $groups = @(
        $Candidates |
            Group-Object {
                (
                    [string]$_.Source
                ).ToLowerInvariant() +
                [char]0 +
                (
                    [string]$_.Name
                ).ToLowerInvariant()
            }
    )

    foreach ($group in $groups) {
        $ids = @(
            $group.Group |
                ForEach-Object {
                    $_.Id
                } |
                Sort-Object -Unique
        )

        if ($ids.Count -le 3) {
            continue
        }

        foreach ($candidate in $group.Group) {
            if ($candidate.Confidence -lt 95) {
                [void]$remove.Add($candidate)
            }
        }
    }

    foreach ($candidate in $remove) {
        [void]$Candidates.Remove($candidate)
    }
}


function Get-ScalarProperty {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties |
            Where-Object {
                $_.Name -ieq $name
            } |
            Select-Object -First 1

        if (
            -not $property -or
            $null -eq $property.Value
        ) {
            continue
        }

        if (
            $property.Value -is
                [System.Collections.IDictionary] -or
            $property.Value -is
                [pscustomobject] -or
            (
                $property.Value -is
                    [System.Collections.IEnumerable] -and
                $property.Value -isnot
                    [string]
            )
        ) {
            continue
        }

        $value = Clean $property.Value

        if ($value) {
            return $value
        }
    }

    return ''
}


function Find-JsonEffects {
    param(
        [Parameter(Mandatory)]
        $Node,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Results,

        [Parameter(Mandatory)]
        [string]$Source,

        [int]$Depth = 0
    )

    if (
        $Depth -gt 20 -or
        $null -eq $Node -or
        $Node -is [string] -or
        $Node -is [ValueType]
    ) {
        return
    }

    $objectNode = if (
        $Node -is [System.Collections.IDictionary]
    ) {
        [pscustomobject]$Node
    }
    else {
        $Node
    }

    if (
        $objectNode -isnot
            [System.Collections.IEnumerable] -or
        $objectNode -is
            [pscustomobject]
    ) {
        $id = Get-ScalarProperty `
            -Object $objectNode `
            -Names @(
                'effectId',
                'effect_id',
                'id',
                'uuid',
                'guid'
            )

        $name = Get-ScalarProperty `
            -Object $objectNode `
            -Names @(
                'effectName',
                'effect_name',
                'displayName',
                'display_name',
                'title',
                'name'
            )

        if ($id -and $name) {
            Add-EffectCandidate `
                -List $Results `
                -Id $id `
                -Name $name `
                -Confidence 90 `
                -Source $Source
        }
    }

    if (
        $Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [string]
    ) {
        foreach ($child in $Node) {
            Find-JsonEffects `
                -Node $child `
                -Results $Results `
                -Source $Source `
                -Depth (
                    $Depth + 1
                )
        }

        return
    }

    foreach ($property in $objectNode.PSObject.Properties) {
        if ($null -ne $property.Value) {
            Find-JsonEffects `
                -Node $property.Value `
                -Results $Results `
                -Source $Source `
                -Depth (
                    $Depth + 1
                )
        }
    }
}


function Get-StrongName {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $patterns = @(
        (
            '(?im)["'']?' +
            '(?:effectName|effect_name|' +
            'displayName|display_name|title)' +
            '["'']?\s*[:=]\s*["'']' +
            '(?<Name>[^"'']{1,200})["'']'
        ),

        (
            '(?is)<title[^>]*>\s*' +
            '(?<Name>[^<]{1,200})\s*</title>'
        ),

        (
            '(?im)export\s+function\s+' +
            '(?:Name|EffectName|DisplayName)' +
            '\s*\([^)]*\)\s*\{[^}]*?' +
            'return\s+["'']' +
            '(?<Name>[^"'']{1,200})["'']'
        )
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match(
            $Text,
            $pattern
        )

        if ($match.Success) {
            $name = Clean `
                $match.Groups['Name'].Value

            if ($name) {
                return $name
            }
        }
    }

    return ''
}


function Scan-EffectFile {
    param(
        [Parameter(Mandatory)]
        [IO.FileInfo]$File,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Candidates,

        [Parameter(Mandatory)]
        [hashtable]$Ids
    )

    if ($File.Length -gt 12MB) {
        return
    }

    if (
        @(
            '.json',
            '.html',
            '.htm',
            '.js',
            '.mjs',
            '.cjs',
            '.txt',
            '.effect',
            '.manifest'
        ) -notcontains
            $File.Extension.ToLowerInvariant()
    ) {
        return
    }

    try {
        $text = [IO.File]::ReadAllText(
            $File.FullName
        )
    }
    catch {
        return
    }

    if (-not $text) {
        return
    }

    if ($File.Extension -ieq '.json') {
        try {
            $json = $text |
                ConvertFrom-Json `
                    -ErrorAction Stop

            Find-JsonEffects `
                -Node $json `
                -Results $Candidates `
                -Source $File.FullName
        }
        catch {
        }
    }

    $foundIds = @{}

    $matches = [regex]::Matches(
        $text,
        (
            '(?im)["'']?' +
            '(?:effectId|effect_id)' +
            '["'']?\s*[:=]\s*["'']' +
            '(?<Id>' +
            '-[A-Za-z0-9_-]{10,}|' +
            '[0-9a-fA-F-]{36}|' +
            '[^"'']+\.html?' +
            ')["'']'
        )
    )

    foreach ($match in $matches) {
        $id = Clean `
            $match.Groups['Id'].Value

        if (Test-EffectId $id) {
            $foundIds[$id] = $true
            $Ids[$id] = $true
        }
    }

    $pathId = ''

    foreach (
        $part in @(
            $File.Directory.Name,
            $File.BaseName,
            $File.Name
        )
    ) {
        if (
            $part -and
            (Test-EffectId $part)
        ) {
            $pathId = $part
            $Ids[$part] = $true
            break
        }
    }

    $name = Get-StrongName $text

    if (
        $name -and
        $foundIds.Count -eq 1
    ) {
        Add-EffectCandidate `
            -List $Candidates `
            -Id (
                $foundIds.Keys |
                    Select-Object -First 1
            ) `
            -Name $name `
            -Confidence 85 `
            -Source $File.FullName
    }
    elseif ($name -and $pathId) {
        Add-EffectCandidate `
            -List $Candidates `
            -Id $pathId `
            -Name $name `
            -Confidence 82 `
            -Source $File.FullName
    }

    if (
        $File.Extension -match '(?i)^\.html?$' -and
        -not $pathId
    ) {
        Add-EffectCandidate `
            -List $Candidates `
            -Id $File.Name `
            -Name $File.BaseName `
            -Confidence 60 `
            -Source $File.FullName

        $Ids[$File.Name] = $true
    }
}


function Get-SignalInfo {
    $process = @(
        Get-CimInstance `
            Win32_Process `
            -Filter "Name='SignalRgb.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace(
                    [string]$_.ExecutablePath
                )
            }
    ) |
        Select-Object -First 1

    $path = if ($process) {
        [string]$process.ExecutablePath
    }
    else {
        ''
    }

    if (-not $path) {
        try {
            $processFallback = Get-Process `
                -Name SignalRgb `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$_.Path
                    )
                } |
                Select-Object -First 1

            if ($processFallback) {
                $process = $processFallback
                $path = [string]$processFallback.Path
            }
        }
        catch {
        }
    }

    $version = ''

    if (
        $path -and
        (Test-Path -LiteralPath $path -PathType Leaf)
    ) {
        try {
            $version = [Diagnostics.FileVersionInfo]::
                GetVersionInfo(
                    $path
                ).FileVersion
        }
        catch {
        }
    }

    return [pscustomobject]@{
        Process = $process
        Path = $path
        Version = $version
    }
}


function Get-EffectRoots {
    param(
        [Parameter(Mandatory)]
        $SignalInfo
    )

    $roots = New-Object `
        System.Collections.ArrayList

    $candidates = @(
        (
            Join-Path `
                $env:LOCALAPPDATA `
                'WhirlwindFX\SignalRgb\cache\effects'
        )
    )

    $documentsRoot = [Environment]::GetFolderPath('MyDocuments')

    if (-not [string]::IsNullOrWhiteSpace($documentsRoot)) {
        $candidates += Join-Path `
            $documentsRoot `
            'WhirlwindFX\Effects'
    }

    $profileDocuments = Join-Path `
        $env:USERPROFILE `
        'Documents\WhirlwindFX\Effects'

    if (
        -not [string]::IsNullOrWhiteSpace($profileDocuments) -and
        ($candidates -notcontains $profileDocuments)
    ) {
        $candidates += $profileDocuments
    }

    $userDir = [string](
        Get-RegValue `
            -Path $SignalRoot `
            -Name 'UserDirectory'
    )

    if ($userDir) {
        $candidates += Join-Path `
            $userDir `
            'Effects'
    }

    if ($SignalInfo.Path) {
        $candidates += Join-Path `
            (
                Split-Path `
                    -Parent $SignalInfo.Path
            ) `
            'Effects'
    }

    foreach ($candidate in $candidates) {
        if (
            $candidate -and
            (
                Test-Path `
                    -LiteralPath $candidate `
                    -PathType Container
            )
        ) {
            $full = (
                Get-Item `
                    -LiteralPath $candidate
            ).FullName

            if ($roots -notcontains $full) {
                [void]$roots.Add($full)
            }
        }
    }

    return @(
        $roots |
            ForEach-Object {
                [string]$_
            }
    )
}


function Get-CurrentInventory {
    param(
        [Parameter(Mandatory)]
        $Previous,

        [Parameter(Mandatory)]
        $SignalInfo
    )

    $candidates = New-Object `
        System.Collections.ArrayList

    $ids = @{}

    $selectedId = Clean (
        Get-RegValue `
            -Path $SelectedEffectPath `
            -Name 'id'
    )

    $selectedName = Clean (
        Get-RegValue `
            -Path $SelectedEffectPath `
            -Name 'name'
    )

    if ($selectedId) {
        $ids[$selectedId] = $true

        if ($selectedName) {
            Add-EffectCandidate `
                -List $candidates `
                -Id $selectedId `
                -Name $selectedName `
                -Confidence 100 `
                -Source 'Selected effect registry record'
        }
    }

    $effectKeys = Get-RegSubKeys `
        -Path $EffectsRoot

    $stateKeys = Get-RegSubKeys `
        -Path $StatesRoot

    foreach (
        $id in @(
            $effectKeys +
            $stateKeys |
                Sort-Object -Unique
        )
    ) {
        if (
            $id -ieq 'selected' -or
            -not (Test-EffectId $id)
        ) {
            continue
        }

        $ids[$id] = $true

        $effectPath = Join-Path `
            $EffectsRoot `
            $id

        foreach (
            $valueName in @(
                'name',
                'effectName',
                'effect_name',
                'displayName',
                'display_name',
                'title'
            )
        ) {
            $name = Clean (
                Get-RegValue `
                    -Path $effectPath `
                    -Name $valueName
            )

            if ($name) {
                Add-EffectCandidate `
                    -List $candidates `
                    -Id $id `
                    -Name $name `
                    -Confidence 95 `
                    -Source (
                        $effectPath +
                        '\' +
                        $valueName
                    )

                break
            }
        }

        if ($id -match '(?i)\.html?$') {
            Add-EffectCandidate `
                -List $candidates `
                -Id $id `
                -Name (
                    [IO.Path]::GetFileNameWithoutExtension(
                        $id
                    )
                ) `
                -Confidence 60 `
                -Source 'Registry HTML effect key'
        }
    }

    $roots = Get-EffectRoots `
        -SignalInfo $SignalInfo

    foreach ($root in $roots) {
        Write-Status `
            -Message (
                'Scanning effect metadata: ' +
                $root
            ) `
            -Color DarkGray

        foreach (
            $directory in @(
                Get-ChildItem `
                    -LiteralPath $root `
                    -Directory `
                    -Recurse `
                    -ErrorAction SilentlyContinue
            )
        ) {
            if (Test-EffectId $directory.Name) {
                $ids[$directory.Name] = $true
            }
        }

        foreach (
            $file in @(
                Get-ChildItem `
                    -LiteralPath $root `
                    -File `
                    -Recurse `
                    -ErrorAction SilentlyContinue
            )
        ) {
            Scan-EffectFile `
                -File $file `
                -Candidates $candidates `
                -Ids $ids
        }
    }

    Remove-SuspiciousCandidates `
        -Candidates $candidates

    foreach ($candidate in $candidates) {
        $ids[$candidate.Id] = $true
    }

    foreach ($id in $Previous.Effects.Keys) {
        $old = $Previous.Effects[$id]

        if (
            $old.Name -and
            (Test-UsableEffectRecord -Record $old)
        ) {
            Add-EffectCandidate `
                -List $candidates `
                -Id $id `
                -Name $old.Name `
                -Confidence 70 `
                -Source 'Previous generated inventory'
        }
    }

    $effects = @{}

    foreach ($id in $ids.Keys) {
        $match = @(
            $candidates |
                Where-Object {
                    $_.Id -ieq $id
                } |
                Sort-Object `
                    @{
                        Expression = 'Confidence'
                        Descending = $true
                    },
                    @{
                        Expression = 'Name'
                        Descending = $false
                    }
        ) |
            Select-Object -First 1

        if ($match) {
            $effects[$id] = [pscustomobject]@{
                Id = $id
                Name = $match.Name
                Status = 'Present'
                Source = $match.Source
            }
        }
        else {
            $short = if ($id.Length -gt 12) {
                $id.Substring(
                    0,
                    12
                )
            }
            else {
                $id
            }

            $effects[$id] = [pscustomobject]@{
                Id = $id

                Name = (
                    '[Unusable Effect ' +
                    $short +
                    ']'
                )

                Status = 'Present-Unusable'
                Source = ''
            }
        }
    }

    $presets = @{}

    foreach ($id in $stateKeys) {
        $names = @(
            Get-RegValueNames `
                -Path (
                    Join-Path `
                        $StatesRoot `
                        $id
                ) |
                Where-Object {
                    $_ -and
                    $_ -notin @(
                        'A',
                        'B',
                        'C',
                        'rgb-free-pro-macros'
                    )
                } |
                Sort-Object -Unique
        )

        $presets[$id] = $names

        if (-not $effects.ContainsKey($id)) {
            $effects[$id] = [pscustomobject]@{
                Id = $id

                Name = (
                    '[Unusable Effect ' +
                    $id +
                    ']'
                )

                Status = 'Present-Unusable'
                Source = ''
            }
        }
    }

    $layouts = @(
        Get-RegSubKeys `
            -Path $LayoutsRoot |
            Where-Object {
                $_
            } |
            Sort-Object -Unique
    )

    $liveRegistryAvailable = [bool](
        $selectedId -or
        @($effectKeys).Count -gt 0 -or
        @($stateKeys).Count -gt 0 -or
        @($layouts).Count -gt 0
    )

    $currentPreset = if ($selectedId) {
        Clean (
            Get-RegValue `
                -Path (
                    Join-Path `
                        $EffectsRoot `
                        $selectedId
                ) `
                -Name 'current_preset'
        )
    }
    else {
        ''
    }

    return [pscustomobject]@{
        Effects = $effects
        Presets = $presets
        Layouts = $layouts
        Roots = $roots
        LiveRegistryAvailable = $liveRegistryAvailable

        Current = [pscustomobject]@{
            EffectId = $selectedId
            EffectName = $selectedName
            Preset = $currentPreset

            Layout = Clean (
                Get-RegValue `
                    -Path $LayoutsRoot `
                    -Name 'currentLayout'
            )
        }
    }
}


function Merge-Inventory {
    param(
        [Parameter(Mandatory)]
        $Current,

        [Parameter(Mandatory)]
        $Previous
    )

    $effects = @{}
    $allIds = @{}

    foreach ($id in $Current.Effects.Keys) {
        $allIds[$id] = $true
    }

    foreach ($id in $Previous.Effects.Keys) {
        $allIds[$id] = $true
    }

    foreach ($id in $allIds.Keys) {
        if ($Current.Effects.ContainsKey($id)) {
            $effects[$id] = $Current.Effects[$id]
        }
        else {
            $old = $Previous.Effects[$id]

            $effects[$id] = [pscustomobject]@{
                Id = $id
                Name = $old.Name
                Status = 'Missing'
                Source = 'Previous generated inventory'
            }
        }
    }

    $presets = @{}

    foreach ($id in $allIds.Keys) {
        $records = @{}

        if ($Current.Presets.ContainsKey($id)) {
            foreach ($name in $Current.Presets[$id]) {
                $key = Get-RecordKey `
                    -Prefix P `
                    -Identity (
                        $id +
                        [char]0 +
                        $name
                    )

                $records[$key] = [pscustomobject]@{
                    Key = $key
                    Name = $name
                    Status = 'Present'
                }
            }
        }

        if ($Previous.Presets.ContainsKey($id)) {
            foreach ($key in $Previous.Presets[$id].Keys) {
                if (-not $records.ContainsKey($key)) {
                    $old = $Previous.Presets[$id][$key]

                    $records[$key] = [pscustomobject]@{
                        Key = $key
                        Name = $old.Name
                        Status = 'Missing'
                    }
                }
            }
        }

        if ($records.Count) {
            $presets[$id] = $records
        }
    }

    $layouts = @{}

    foreach ($name in $Current.Layouts) {
        $key = Get-RecordKey `
            -Prefix L `
            -Identity $name

        $layouts[$key] = [pscustomobject]@{
            Key = $key
            Name = $name
            Status = 'Present'
        }
    }

    foreach ($key in $Previous.Layouts.Keys) {
        if (-not $layouts.ContainsKey($key)) {
            $old = $Previous.Layouts[$key]

            $layouts[$key] = [pscustomobject]@{
                Key = $key
                Name = $old.Name
                Status = 'Missing'
            }
        }
    }

    $inventoryIdLines = New-Object `
        System.Collections.ArrayList

    foreach (
        $id in @(
            $Current.Effects.Keys |
                Sort-Object
        )
    ) {
        [void]$inventoryIdLines.Add(
            'E|' +
            $id.ToLowerInvariant()
        )
    }

    foreach (
        $id in @(
            $Current.Presets.Keys |
                Sort-Object
        )
    ) {
        foreach (
            $name in @(
                $Current.Presets[$id] |
                    Sort-Object
            )
        ) {
            [void]$inventoryIdLines.Add(
                'P|' +
                $id.ToLowerInvariant() +
                '|' +
                $name.ToLowerInvariant()
            )
        }
    }

    foreach (
        $name in @(
            $Current.Layouts |
                Sort-Object
        )
    ) {
        [void]$inventoryIdLines.Add(
            'L|' +
            $name.ToLowerInvariant()
        )
    }

    return [pscustomobject]@{
        Effects = $effects
        Presets = $presets
        Layouts = $layouts

        InventoryId = Get-Sha256 `
            -Text (
                (
                    $inventoryIdLines -join "`n"
                ) +
                "`n"
            )
    }
}


function New-DefaultConfig {
    return (
        @(
            '; --------------------------',
            '',
            '; SignalRGB Pro Switcher Free',
            '; by landnthrn',
            '',
            '; The inventory updater won''t overwrite your custom config setup, it''ll just add new detected items.',
            '; If any items are no longer detected, they will remain in this file marked as ''No Longer Found''.',
            '; Highly suggest using the app to configure this file, but if not use the `data/inventory.md` to help you',
            '; Inventory updates rewrite `data\config.backup.ini` with the config''s previous state before latest update.',
            '',
            '; --------------------------',
            '',
            '[Assets]',
            'InventoryFile=data\inventory.ini',
            (
                'UpdaterScript=' +
                $UpdaterName
            ),
            '',
            '; --------------------------',
            '',
            '[Hotkeys]',
            '; Hotkey format uses normal AutoHotkey style',
            '; + = Shift, ^ = Ctrl, ! = Alt, # = Win',
            '; Example: ^!+p = Ctrl+Alt+Shift+P, !s = Alt+S',
            'OpenPickerMenu=^!+m',
            'PickPreset=^!+p',
            'PickEffect=^!+e',
            'PickLayout=^!+l',
            'GoToNextPreset=^!p',
            'GoToNextEffect=^!e',
            'GoToNextLayout=^!l',
            'ShowStatus=^!s',
            '',
            '; --------------------------',
            '',
            '[Behavior]',
            'LaunchOnStartup=false',
            'AutoUpdateInventory=false',
            'AutoUpdateInventoryInterval=0h 2m 30s',
            'ShowHotkeyNotifications=true',
            'Logging=false',
            '',
            '; Watches only for active effect changes made outside the macros.',
            '; When that happens, preset/layout activation rules are applied to the new active effect.',
            'WatchExternalEffectChanges=true',
            '',
            '; Applies preset/layout rules to the currently active effect when the macros start.',
            'ApplyPoliciesOnStartup=true',
            'RememberLastActiveEffectPreset=true',
            '',
            '; Behaviour for Loading preset on effect activation.',
            '; LastUsed or Preferred. Preferred uses the top preset in [PresetOrder.<Effect Name>].',
            'PresetOnEffectActivation=LastUsed',
            '',
            '; Current or DefaultLayout',
            'UnassignedEffectLayoutMode=Current',
            'DefaultLayout=',
            '',
            '; --------------------------',
            '',
            'ExcludeFromPickers=false',
            'ExcludeFromNextHotkeys=true',
            'ExcludeFromCycling=true',
            '',
            '; --------------------------',
            '',
            '[Cycling]',
            '; EffectCyclingMode: Order or Random',
            '; CycleEffectOnceAllPresetsElapsed: when on, effects advance after all presets have elapsed instead of on the effect interval.',
            '; PresetCyclingMode: Order or Random',
            '; If both normal effect cycling and preset cycling are enabled, keep PresetCyclingInterval lower than EffectCyclingInterval.',
            'EffectCyclingEnabled=false',
            'EffectCyclingMode=Order',
            'EffectCyclingInterval=0h 15m 0s',
            'CycleEffectOnceAllPresetsElapsed=false',
            'PresetCyclingEnabled=false',
            'PresetCyclingMode=Order',
            'PresetCyclingInterval=0h 15m 0s',
            '',
            '[IgnoredEffects]',
            '; Exclude effects from pickers, go-to-next hotkeys, and/or cycling',
            '; Format: Effect Name',
            '',
            '[IgnoredPresets]',
            '; Exclude presets from pickers, go-to-next hotkeys, and/or cycling',
            '; Format: Effect Name|Preset Name',
            '',
            '[IgnoredLayouts]',
            '; Exclude layouts from pickers and/or go-to-next hotkeys',
            '; Format: Layout Name',
            '',
            '; --------------------------',
            '',
            '[FavoriteEffects]',
            '; Starred effects in the config editor',
            '; Format: Effect Name',
            '',
            '[FavoritePresets]',
            '; Starred presets in the config editor',
            '; Format: Effect Name|Preset Name',
            '',
            '[FavoriteLayouts]',
            '; Starred layouts in the config editor',
            '; Format: Layout Name',
            '',
            '; --------------------------',
            '',
            '[EffectLayouts]',
            '; Assign layouts to effects.',
            '; Format: Effect Name=Layout Name',
            '',
            '; --------------------------',
            '',
            '[LayoutOrder]',
            '; The order for pickers, go-to-next hotkeys, and cycling',
            '; Format: 001=Layout Name',
            '',
            '; --------------------------',
            '',
            '[EffectOrder]',
            '; The order for pickers, go-to-next hotkeys, and cycling',
            '; Format: 001=Effect Name',
            '',
            '; [PresetOrder.<Effect Name>]',
            '; The order for pickers, go-to-next hotkeys, and cycling.',
            '; Format: 001=Preset Name',
            '',
            '; --------------------------',
            '',
            ''
        ) -join "`r`n"
    ) + "`r`n"
}

function New-InventoryFile {
    param(
        [Parameter(Mandatory)]
        $Merged,

        [Parameter(Mandatory)]
        $SignalInfo
    )

    $lines = New-Object `
        System.Collections.ArrayList

    [void]$lines.Add(
        '; SignalRGB Pro Switcher Free generated inventory'
    )

    [void]$lines.Add(
        '; Maintained automatically. Do not edit this file.'
    )

    [void]$lines.Add(
        '; Effect IDs are real SignalRGB IDs. P_/L_ keys are updater bookkeeping keys only.'
    )

    [void]$lines.Add(
        '; Missing items stay here so user choices are preserved; the AHK will ignore them.'
    )

    [void]$lines.Add('')

    $presentEffects = @(
        $Merged.Effects.Values |
            Where-Object {
                $_.Status -eq 'Present'
            }
    ).Count

    $unusableEffects = @(
        $Merged.Effects.Values |
            Where-Object {
                $_.Status -eq 'Present-Unusable'
            }
    ).Count

    $missingEffects = @(
        $Merged.Effects.Values |
            Where-Object {
                $_.Status -eq 'Missing'
            }
    ).Count

    $presentPresets = 0
    $missingPresets = 0

    foreach ($records in $Merged.Presets.Values) {
        $presentPresets += @(
            $records.Values |
                Where-Object {
                    $_.Status -eq 'Present'
                }
        ).Count

        $missingPresets += @(
            $records.Values |
                Where-Object {
                    $_.Status -eq 'Missing'
                }
        ).Count
    }

    $presentLayouts = @(
        $Merged.Layouts.Values |
            Where-Object {
                $_.Status -eq 'Present'
            }
    ).Count

    $missingLayouts = @(
        $Merged.Layouts.Values |
            Where-Object {
                $_.Status -eq 'Missing'
            }
    ).Count

    [void]$lines.Add('[InventoryMeta]')
    [void]$lines.Add('SchemaVersion=1')

    [void]$lines.Add(
        'GeneratedAt=' +
        (
            Get-Date `
                -Format 'yyyy-MM-dd HH:mm:ss'
        )
    )

    [void]$lines.Add(
        'SignalRGBVersion=' +
        (
            Clean $SignalInfo.Version
        )
    )

    [void]$lines.Add(
        'Inventory-ID=' +
        $Merged.InventoryId
    )

    [void]$lines.Add(
        'PresentEffects=' +
        $presentEffects
    )

    [void]$lines.Add(
        'UnusableEffects=' +
        $unusableEffects
    )

    [void]$lines.Add(
        'MissingEffects=' +
        $missingEffects
    )

    [void]$lines.Add(
        'PresentPresets=' +
        $presentPresets
    )

    [void]$lines.Add(
        'MissingPresets=' +
        $missingPresets
    )

    [void]$lines.Add(
        'PresentLayouts=' +
        $presentLayouts
    )

    [void]$lines.Add(
        'MissingLayouts=' +
        $missingLayouts
    )

    $effects = @(
        $Merged.Effects.Values |
            Sort-Object Name, Id
    )

    [void]$lines.Add('')
    [void]$lines.Add('[Effects]')

    foreach ($effect in $effects) {
        [void]$lines.Add(
            $effect.Id +
            '=' +
            (
                Clean $effect.Name
            )
        )
    }

    [void]$lines.Add('')
    [void]$lines.Add('[EffectInventoryStatus]')

    foreach ($effect in $effects) {
        [void]$lines.Add(
            $effect.Id +
            '=' +
            $effect.Status
        )
    }

    foreach ($effect in $effects) {
        if (-not $Merged.Presets.ContainsKey($effect.Id)) {
            continue
        }

        $records = @(
            $Merged.Presets[$effect.Id].Values |
                Sort-Object Name, Key
        )

        [void]$lines.Add('')

        [void]$lines.Add(
            '[Presets.' +
            $effect.Id +
            ']'
        )

        [void]$lines.Add(
            '; Effect=' +
            (
                Clean $effect.Name
            )
        )

        foreach ($preset in $records) {
            [void]$lines.Add(
                $preset.Key +
                '=' +
                (
                    Clean $preset.Name
                )
            )
        }

        [void]$lines.Add('')

        [void]$lines.Add(
            '[PresetInventoryStatus.' +
            $effect.Id +
            ']'
        )

        foreach ($preset in $records) {
            [void]$lines.Add(
                $preset.Key +
                '=' +
                $preset.Status
            )
        }
    }

    $layouts = @(
        $Merged.Layouts.Values |
            Sort-Object Name, Key
    )

    [void]$lines.Add('')
    [void]$lines.Add('[Layouts]')

    foreach ($layout in $layouts) {
        [void]$lines.Add(
            $layout.Key +
            '=' +
            (
                Clean $layout.Name
            )
        )
    }

    [void]$lines.Add('')
    [void]$lines.Add('[LayoutInventoryStatus]')

    foreach ($layout in $layouts) {
        [void]$lines.Add(
            $layout.Key +
            '=' +
            $layout.Status
        )
    }

    return (
        $lines -join "`r`n"
    ) + "`r`n"
}


function Backup-ConfigBeforeInventoryUpdate {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$BackupPath
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $ConfigPath `
                -PathType Leaf
        )
    ) {
        return
    }

    $backupDirectory = Split-Path `
        -Parent $BackupPath

    if (
        -not (
            Test-Path `
                -LiteralPath $backupDirectory `
                -PathType Container
        )
    ) {
        New-Item `
            -ItemType Directory `
            -Path $backupDirectory `
            -Force |
            Out-Null
    }

    Copy-Item `
        -LiteralPath $ConfigPath `
        -Destination $BackupPath `
        -Force
}


function Write-Utf8 {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $encoding = New-Object `
        System.Text.UTF8Encoding($true)

    [IO.File]::WriteAllText(
        $Path,
        $Content,
        $encoding
    )
}


function ConvertTo-MarkdownText {
    param(
        [AllowNull()]
        $Value
    )

    $text = Clean $Value

    foreach (
        $pair in @(
            @('\', '\\'),
            @('*', '\*'),
            @('_', '\_'),
            @('[', '\['),
            @(']', '\]'),
            @('#', '\#')
        )
    ) {
        $text = $text.Replace(
            $pair[0],
            $pair[1]
        )
    }

    return $text
}


function Is-True {
    param(
        $Value
    )

    return (
        [string]$Value
    ) -match '^(?i:true|1|yes|on)$'
}


function Add-LookupSetValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Lookup,

        [Parameter(Mandatory)]
        [string]$OuterKey,

        [Parameter(Mandatory)]
        [string]$InnerKey
    )

    $normalizedOuter = $OuterKey.Trim().ToLowerInvariant()
    $normalizedInner = $InnerKey.Trim().ToLowerInvariant()

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
        [Parameter(Mandatory)]
        [hashtable]$Sections
    )

    $lookup = @{}
    $ignoredPresets = Get-Section `
        -Sections $Sections `
        -Name 'IgnoredPresets'

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
        elseif (Is-True $right) {
            Add-LookupSetValue `
                -Lookup $lookup `
                -OuterKey '*' `
                -InnerKey $left
        }
        elseif (-not [string]::IsNullOrWhiteSpace($right)) {
            Add-LookupSetValue `
                -Lookup $lookup `
                -OuterKey $left `
                -InnerKey $right
        }
    }

    return $lookup
}


function Test-IgnoredPreset {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Lookup,

        [Parameter(Mandatory)]
        [string]$EffectName,

        [Parameter(Mandatory)]
        [string]$PresetName
    )

    $normalizedEffectName = $EffectName.Trim().ToLowerInvariant()
    $normalizedPresetName = $PresetName.Trim().ToLowerInvariant()

    return (
        $Lookup.ContainsKey($normalizedEffectName) -and
        $Lookup[$normalizedEffectName].ContainsKey($normalizedPresetName)
    ) -or (
        $Lookup.ContainsKey('*') -and
        $Lookup['*'].ContainsKey($normalizedPresetName)
    )
}


function Get-FirstOrderedPreset {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Sections,

        [Parameter(Mandatory)]
        [string]$EffectName,

        [Parameter(Mandatory)]
        $Records
    )

    $order = Get-Section `
        -Sections $Sections `
        -Name (
            'PresetOrder.' +
            $EffectName
        )

    if (-not $order.Count) {
        return ''
    }

    foreach ($entryKey in @($order.Keys | Sort-Object)) {
        $configuredName = [string]$order[$entryKey]

        foreach ($record in $Records) {
            if (
                $record.Status -eq 'Present' -and
                $record.Name -ieq $configuredName
            ) {
                return $record.Name
            }
        }
    }

    return ''
}


function New-Markdown {
    param(
        [Parameter(Mandatory)]
        $Merged,

        [Parameter(Mandatory)]
        $Current,

        [Parameter(Mandatory)]
        [hashtable]$Sections,

        [Parameter(Mandatory)]
        $SignalInfo
    )

    $assignments = Get-Section `
        -Sections $Sections `
        -Name 'EffectLayouts'

    $ignoredEffects = Get-Section `
        -Sections $Sections `
        -Name 'IgnoredEffects'

    $ignoredLayouts = Get-Section `
        -Sections $Sections `
        -Name 'IgnoredLayouts'

    $ignoredPresets = Get-IgnoredPresetLookup `
        -Sections $Sections

    $lines = New-Object `
        System.Collections.ArrayList

    $warnings = New-Object `
        System.Collections.ArrayList

    [void]$lines.Add(
        '# SignalRGB Pro Switcher Free Inventory'
    )

    [void]$lines.Add('')

    [void]$lines.Add(
        '- Generated: ' +
        (
            Get-Date `
                -Format 'yyyy-MM-dd HH:mm:ss'
        )
    )

    if ($SignalInfo.Version) {
        [void]$lines.Add(
            '- SignalRGB version: ' +
            (
                ConvertTo-MarkdownText $SignalInfo.Version
            )
        )
    }

    [void]$lines.Add('')
    [void]$lines.Add('## Current state')
    [void]$lines.Add('')

    [void]$lines.Add(
        '- Effect: ' +
        (
            ConvertTo-MarkdownText $Current.Current.EffectName
        )
    )

    [void]$lines.Add(
        '- Preset: ' +
        (
            ConvertTo-MarkdownText $Current.Current.Preset
        )
    )

    [void]$lines.Add(
        '- Layout: ' +
        (
            ConvertTo-MarkdownText $Current.Current.Layout
        )
    )

    [void]$lines.Add('')
    [void]$lines.Add('## Effects and presets')

    foreach (
        $effect in @(
            $Merged.Effects.Values |
                Sort-Object Name, Id
        )
    ) {
        $heading = (
            '### ' +
            (
                ConvertTo-MarkdownText $effect.Name
            )
        )

        if ($effect.Status -eq 'Missing') {
            $heading += ' — missing'
        }
        elseif ($effect.Status -eq 'Present-Unusable') {
            $heading += ' - unusable'
        }

        [void]$lines.Add('')
        [void]$lines.Add($heading)
        [void]$lines.Add('')

        $ignored = $false

        if ($ignoredEffects.ContainsKey($effect.Name)) {
            $ignored = Is-True `
                $ignoredEffects[$effect.Name]
        }
        elseif (
            $effect.Status -eq 'Present-Unusable' -and
            $ignoredEffects.ContainsKey($effect.Id)
        ) {
            $ignored = Is-True `
                $ignoredEffects[$effect.Id]
        }

        [void]$lines.Add(
            '- Status: ' +
            $effect.Status
        )

        [void]$lines.Add(
            '- ID: ' +
            [string]$effect.Id
        )

        [void]$lines.Add(
            '- Ignored by AHK: ' +
            $(
                if ($ignored) {
                    'Yes'
                }
                else {
                    'No'
                }
            )
        )

        $assigned = ''

        if ($assignments.ContainsKey($effect.Name)) {
            $assigned = [string]$assignments[$effect.Name]
        }
        elseif (
            $effect.Status -eq 'Present-Unusable' -and
            $assignments.ContainsKey($effect.Id)
        ) {
            $assigned = [string]$assignments[$effect.Id]
        }

        if ($assigned) {
            [void]$lines.Add(
                '- Assigned layout: ' +
                (
                    ConvertTo-MarkdownText $assigned
                )
            )

            $found = @(
                $Merged.Layouts.Values |
                    Where-Object {
                        $_.Name -ieq $assigned -and
                        $_.Status -eq 'Present'
                    }
            ).Count -gt 0

            if (-not $found) {
                [void]$warnings.Add(
                    'Assigned layout not found for ' +
                    $effect.Name +
                    ': ' +
                    $assigned
                )
            }
        }

        [void]$lines.Add('- Presets:')

        if (
            $Merged.Presets.ContainsKey($effect.Id) -and
            $Merged.Presets[$effect.Id].Count
        ) {
            $records = @(
                $Merged.Presets[$effect.Id].Values |
                    Sort-Object Name
            )

            foreach ($preset in $records) {
                $suffix = ''

                if ($preset.Status -eq 'Missing') {
                    $suffix += ' — missing'
                }

                if (
                    Test-IgnoredPreset `
                        -Lookup $ignoredPresets `
                        -EffectName $effect.Name `
                        -PresetName $preset.Name
                ) {
                    $suffix += ' — ignored for this effect'
                }

                [void]$lines.Add(
                    '  - ' +
                    (
                        ConvertTo-MarkdownText $preset.Name
                    ) +
                    $suffix
                )
            }

            $preferredName = Get-FirstOrderedPreset `
                -Sections $Sections `
                -EffectName $effect.Name `
                -Records $records

            if ($preferredName) {
                [void]$lines.Add(
                    '- First in set order preset: ' +
                    (
                        ConvertTo-MarkdownText $preferredName
                    )
                )
            }

        }
        else {
            [void]$lines.Add(
                '  - None found'
            )
        }

        if ($effect.Status -eq 'Missing') {
            [void]$warnings.Add(
                'Effect no longer found: ' +
                $effect.Name
            )
        }
        elseif ($effect.Status -eq 'Present-Unusable') {
            [void]$warnings.Add(
                'A present effect could not be made usable.'
            )
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add('## Layouts')
    [void]$lines.Add('')

    $layouts = @(
        $Merged.Layouts.Values |
            Sort-Object Name
    )

    if (-not $layouts.Count) {
        [void]$lines.Add(
            '- None found'
        )
    }
    else {
        foreach ($layout in $layouts) {
            $suffix = ''

            if ($layout.Status -eq 'Missing') {
                $suffix += ' — missing'

                [void]$warnings.Add(
                    'Layout no longer found: ' +
                    $layout.Name
                )
            }

            if (
                $ignoredLayouts.ContainsKey($layout.Name) -and
                (
                    Is-True `
                        $ignoredLayouts[$layout.Name]
                )
            ) {
                $suffix += ' — ignored'
            }

            [void]$lines.Add(
                '- ' +
                (
                    ConvertTo-MarkdownText $layout.Name
                ) +
                $suffix
            )
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add('## Warnings')
    [void]$lines.Add('')

    $unique = @(
        $warnings |
            Sort-Object -Unique
    )

    if (-not $unique.Count) {
        [void]$lines.Add('- None')
    }
    else {
        foreach ($warning in $unique) {
            [void]$lines.Add(
                '- ' +
                (
                    ConvertTo-MarkdownText $warning
                )
            )
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add('## Notes')
    [void]$lines.Add('')

    [void]$lines.Add(
        '- Effect IDs are used internally but intentionally omitted here.'
    )

    [void]$lines.Add(
        '- Presets and layouts have no separate SignalRGB IDs in the observed storage.'
    )

    [void]$lines.Add(
        '- Missing entries remain in data\inventory.ini and stay in your config.ini order lists marked No Longer Found. Ignores, layout assignments, and the custom order of still-present items are preserved.'
    )

    return (
        $lines -join "`r`n"
    ) + "`r`n"
}


$projectRoot = Resolve-ProjectRoot

$dataRoot = Join-Path `
    $projectRoot `
    'data'

if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    New-Item `
        -ItemType Directory `
        -Path $dataRoot `
        -Force |
        Out-Null
}

$configPath = Join-Path `
    $projectRoot `
    $ConfigName

$inventoryPath = Join-Path `
    $dataRoot `
    $InventoryName

$reportPath = Join-Path `
    $dataRoot `
    $ReportName

Write-Status ''
Write-Status `
    'Reading user configuration...' `
    Green

$configCreated = $false
$configUpdated = $false

if (
    Test-Path `
        -LiteralPath $configPath `
        -PathType Leaf
) {
    $configText = [IO.File]::ReadAllText($configPath)
}
else {
    $configText = New-DefaultConfig

    Write-Utf8 `
        -Path $configPath `
        -Content $configText

    $configCreated = $true
}

$configSections = Read-Ini $configText

$backupPath = Join-Path `
    $dataRoot `
    'config.backup.ini'

Write-Status `
    'Saving configuration backup...' `
    Green

Backup-ConfigBeforeInventoryUpdate `
    -ConfigPath $configPath `
    -BackupPath $backupPath

Write-Status `
    'Reading previous generated inventory...' `
    Green

$inventoryText = if (
    Test-Path `
        -LiteralPath $inventoryPath `
        -PathType Leaf
) {
    [IO.File]::ReadAllText($inventoryPath)
}
else {
    ''
}

$inventorySections = Read-Ini $inventoryText

$previous = Get-PreviousInventory `
    -Sections $inventorySections

Write-Status `
    'Reading SignalRGB inventory...' `
    Green

$signalInfo = Get-SignalInfo

$current = Get-CurrentInventory `
    -Previous $previous `
    -SignalInfo $signalInfo

if (
    -not $current.LiveRegistryAvailable -and
    (
        $previous.Effects.Count -gt 0 -or
        $previous.Presets.Count -gt 0 -or
        $previous.Layouts.Count -gt 0
    )
) {
    Write-Status `
        'SignalRGB live inventory was unavailable; preserving previous generated inventory.' `
        Yellow

    $current = Convert-PreviousInventoryToCurrent `
        -Previous $previous
}

$merged = Merge-Inventory `
    -Current $current `
    -Previous $previous

Write-Status `
    'Updating config inventory sections...' `
    Green

$updatedConfigText = Update-ConfigInventorySections `
    -ConfigText $configText `
    -Merged $merged

if ($updatedConfigText -ne $configText) {
    Write-Utf8 `
        -Path $configPath `
        -Content $updatedConfigText

    $configText = $updatedConfigText
    $configSections = Read-Ini $configText
    $configUpdated = $true
}

Write-Status `
    'Writing generated inventory INI...' `
    Green

$generatedInventory = New-InventoryFile `
    -Merged $merged `
    -SignalInfo $signalInfo

Write-Utf8 `
    -Path $inventoryPath `
    -Content $generatedInventory

Write-Status `
    'Writing Markdown inventory...' `
    Green

$markdown = New-Markdown `
    -Merged $merged `
    -Current $current `
    -Sections $configSections `
    -SignalInfo $signalInfo

Write-Utf8 `
    -Path $reportPath `
    -Content $markdown

$presentEffects = @(
    $merged.Effects.Values |
        Where-Object {
            $_.Status -eq 'Present'
        }
).Count

$unusableEffects = @(
    $merged.Effects.Values |
        Where-Object {
            $_.Status -eq 'Present-Unusable'
        }
).Count

$missingEffects = @(
    $merged.Effects.Values |
        Where-Object {
            $_.Status -eq 'Missing'
        }
).Count

$presentPresets = 0
$missingPresets = 0

foreach ($records in $merged.Presets.Values) {
    $presentPresets += @(
        $records.Values |
            Where-Object {
                $_.Status -eq 'Present'
            }
    ).Count

    $missingPresets += @(
        $records.Values |
            Where-Object {
                $_.Status -eq 'Missing'
            }
    ).Count
}

$presentLayouts = @(
    $merged.Layouts.Values |
        Where-Object {
            $_.Status -eq 'Present'
        }
).Count

$missingLayouts = @(
    $merged.Layouts.Values |
        Where-Object {
            $_.Status -eq 'Missing'
        }
).Count

Write-Status ''

Write-Status `
    'Inventory update complete.' `
    Green

Write-Status (
    $(
        if ($configCreated) {
            'Config created: '
        }
        elseif ($configUpdated) {
            'Config updated: '
        }
        else {
            'Config preserved: '
        }
    ) +
    $configPath
)

Write-Status (
    'Config backup: ' +
    $backupPath
)

Write-Status (
    'Inventory INI: ' +
    $inventoryPath
)

Write-Status (
    'Inventory Markdown: ' +
    $reportPath
)

Write-Status (
    'Present effects: ' +
    $presentEffects
)

Write-Status (
    'Unusable effects: ' +
    $unusableEffects
)

Write-Status (
    'Missing retained effects: ' +
    $missingEffects
)

Write-Status (
    'Present presets: ' +
    $presentPresets
)

Write-Status (
    'Missing retained presets: ' +
    $missingPresets
)

Write-Status (
    'Present layouts: ' +
    $presentLayouts
)

Write-Status (
    'Missing retained layouts: ' +
    $missingLayouts
)

Write-Status `
    (
        'Inventory-ID: ' +
        $merged.InventoryId
    ) `
    DarkGray

$result = [pscustomobject]@{
    ConfigPath = $configPath
    ConfigCreated = $configCreated
    ConfigUpdated = $configUpdated
    InventoryPath = $inventoryPath
    MarkdownPath = $reportPath
    InventoryId = $merged.InventoryId
    PresentEffects = $presentEffects
    UnusableEffects = $unusableEffects
    MissingEffects = $missingEffects
    PresentPresets = $presentPresets
    MissingPresets = $missingPresets
    PresentLayouts = $presentLayouts
    MissingLayouts = $missingLayouts
}

if (-not $Quiet) {
    $result
}

exit 0
