#requires -Version 5.1

<#
.SYNOPSIS
    Creates a read-only developer architecture report for SignalRGB.

.DESCRIPTION
    This script documents the local mechanisms used by the companion
    AutoHotkey and PowerShell tools.

    It reads and reports:

    - Running SignalRGB executable and version
    - SignalRGB process information
    - Registry roots and storage architecture
    - Currently selected effect name and ID
    - Current preset storage
    - Saved preset storage and registry value types
    - Temporary preset alias slot availability
    - Saved layout storage
    - Current and previous layout storage
    - Whether layouts expose separate IDs
    - SignalRGB URL protocol registration
    - Local SignalRGB API status
    - SignalRGB user-data and cache locations
    - Effect, state, layout, playlist, macro, and endpoint key structures
    - The externally verified control methods used by this project

    This script does NOT:

    - Change an effect
    - Change a preset
    - Change a layout
    - Create temporary preset aliases
    - Write to the SignalRGB registry
    - Restart or close SignalRGB

    It only writes Markdown and JSON reports to the selected output folder.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SignalRoot = 'HKCU:\SOFTWARE\WhirlwindFX\SignalRgb'

$EffectsRoot = Join-Path `
    $SignalRoot `
    'effects'

$StatesRoot = Join-Path `
    $SignalRoot `
    'states'

$SelectedEffectPath = Join-Path `
    $EffectsRoot `
    'selected'

$LayoutsRoot = Join-Path `
    $SignalRoot `
    'layouts'

$LightingRoot = Join-Path `
    $SignalRoot `
    'lighting'

$EndpointRoot = Join-Path `
    $LightingRoot `
    'endpoint'

$PlaylistsPath = Join-Path `
    $LightingRoot `
    'Playlists'

$MacroblocksRoot = Join-Path `
    $SignalRoot `
    'Macroblocks'

function Get-SignalRgbProcess {
    $processes = @(
        Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "Name='SignalRgb.exe'" `
            -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace(
                [string]$_.ExecutablePath
            )
        }
    )

    if (@($processes).Count -gt 0) {
        return $processes[0]
    }

    $fallback = Get-Process `
        -Name 'SignalRgb' `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($fallback) {
        $fallbackPath = ''

        try {
            $fallbackPath = [string]$fallback.Path
        }
        catch {
        }

        return [pscustomobject][ordered]@{
            Name           = $fallback.ProcessName
            ProcessId      = $fallback.Id
            ExecutablePath = $fallbackPath
            CommandLine    = ''
        }
    }

    return $null
}

function Read-ConsoleInput {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    Write-Host -NoNewline $Prompt
    return [Console]::ReadLine()
}

function Read-OutputFolder {
    while ($true) {
        Write-Host ''
        Write-Host (
            'Enter the folder path where the reports should be saved:'
        ) -ForegroundColor Green

        $entered = Read-ConsoleInput 'Path> '

        if ($null -eq $entered) {
            $entered = ''
        }

        $entered = $entered.Trim().Trim('"')

        if ([string]::IsNullOrWhiteSpace($entered)) {
            Write-Host ''
            Write-Host 'A folder path is required.' -ForegroundColor Red
            continue
        }

        try {
            if (
                -not (
                    Test-Path `
                        -LiteralPath $entered `
                        -PathType Container
                )
            ) {
                New-Item `
                    -ItemType Directory `
                    -Path $entered `
                    -Force |
                    Out-Null
            }

            return (
                Get-Item `
                    -LiteralPath $entered `
                    -ErrorAction Stop
            ).FullName
        }
        catch {
            Write-Host ''
            Write-Host (
                'The output folder could not be created ' +
                'or accessed.'
            ) -ForegroundColor Red

            Write-Host $_.Exception.Message
        }
    }
}

function Get-RegistryValueSafe {
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ValueName
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $RegistryPath
        )
    ) {
        return $null
    }

    try {
        $key = Get-Item `
            -LiteralPath $RegistryPath `
            -ErrorAction Stop

        return $key.GetValue(
            $ValueName,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::
                DoNotExpandEnvironmentNames
        )
    }
    catch {
        return $null
    }
}

function Get-RegistryValueKindSafe {
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ValueName
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $RegistryPath
        )
    ) {
        return ''
    }

    try {
        $key = Get-Item `
            -LiteralPath $RegistryPath `
            -ErrorAction Stop

        return [string]$key.GetValueKind(
            $ValueName
        )
    }
    catch {
        return ''
    }
}

function Get-RegistryValueNamesSafe {
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $RegistryPath
        )
    ) {
        return @()
    }

    try {
        $key = Get-Item `
            -LiteralPath $RegistryPath `
            -ErrorAction Stop

        return @(
            $key.GetValueNames()
        )
    }
    catch {
        return @()
    }
}

function Get-RegistrySubKeyNamesSafe {
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath
    )

    if (
        -not (
            Test-Path `
                -LiteralPath $RegistryPath
        )
    ) {
        return @()
    }

    try {
        return @(
            Get-ChildItem `
                -LiteralPath $RegistryPath `
                -ErrorAction Stop |
            Select-Object `
                -ExpandProperty PSChildName
        )
    }
    catch {
        return @()
    }
}

function Get-ByteHash {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()

    try {
        return (
            [BitConverter]::ToString(
                $sha256.ComputeHash($Bytes)
            ) -replace '-', ''
        )
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-ValueDescription {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return [pscustomobject][ordered]@{
            DataType = 'Null'
            Length   = 0
            SHA256   = ''
            Preview  = ''
        }
    }

    if ($Value -is [byte[]]) {
        $previewLength = [Math]::Min(
            $Value.Length,
            32
        )

        $hexPreview = ''

        if ($previewLength -gt 0) {
            $hexPreview = (
                $Value[0..($previewLength - 1)] |
                    ForEach-Object {
                        $_.ToString('X2')
                    }
            ) -join ' '
        }

        return [pscustomobject][ordered]@{
            DataType = 'ByteArray'
            Length   = $Value.Length
            SHA256   = Get-ByteHash -Bytes $Value
            Preview  = $hexPreview
        }
    }

    if (
        $Value -is [System.Array] -and
        $Value -isnot [string]
    ) {
        $arrayValues = @(
            $Value |
                ForEach-Object {
                    [string]$_
                }
        )

        $joined = $arrayValues -join ' | '

        if ($joined.Length -gt 300) {
            $joined = (
                $joined.Substring(0, 300) +
                '...'
            )
        }

        return [pscustomobject][ordered]@{
            DataType = $Value.GetType().FullName
            Length   = @($arrayValues).Count
            SHA256   = ''
            Preview  = $joined
        }
    }

    $text = [string]$Value

    if ($text.Length -gt 300) {
        $text = (
            $text.Substring(0, 300) +
            '...'
        )
    }

    return [pscustomobject][ordered]@{
        DataType = $Value.GetType().FullName
        Length   = ([string]$Value).Length
        SHA256   = ''
        Preview  = $text
    }
}

function Get-RegistryKeySchema {
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath,

        [switch]$IncludeValues
    )

    $exists = Test-Path `
        -LiteralPath $RegistryPath

    if (-not $exists) {
        return [pscustomobject][ordered]@{
            RegistryPath = $RegistryPath
            Exists       = $false
            SubKeyCount  = 0
            ValueCount   = 0
            Values       = @()
        }
    }

    $subKeyNames = @(
        Get-RegistrySubKeyNamesSafe `
            -RegistryPath $RegistryPath
    )

    $valueNames = @(
        Get-RegistryValueNamesSafe `
            -RegistryPath $RegistryPath
    )

    $valueRecords = @()

    if ($IncludeValues) {
        foreach ($valueName in $valueNames) {
            $value = Get-RegistryValueSafe `
                -RegistryPath $RegistryPath `
                -ValueName $valueName

            $description = Get-ValueDescription `
                -Value $value

            $displayName = if (
                [string]::IsNullOrEmpty($valueName)
            ) {
                '(Default)'
            }
            else {
                $valueName
            }

            $valueRecords += [pscustomobject][ordered]@{
                ValueName = $displayName
                ValueKind = Get-RegistryValueKindSafe `
                    -RegistryPath $RegistryPath `
                    -ValueName $valueName
                DataType  = $description.DataType
                Length    = $description.Length
                SHA256    = $description.SHA256
                Preview   = $description.Preview
            }
        }
    }

    return [pscustomobject][ordered]@{
        RegistryPath = $RegistryPath
        Exists       = $true
        SubKeyCount  = @($subKeyNames).Count
        ValueCount   = @($valueNames).Count
        Values       = @($valueRecords)
    }
}

function Get-CurrentEffectState {
    $effectId = [string](
        Get-RegistryValueSafe `
            -RegistryPath $SelectedEffectPath `
            -ValueName 'id'
    )

    $effectName = [string](
        Get-RegistryValueSafe `
            -RegistryPath $SelectedEffectPath `
            -ValueName 'name'
    )

    $previousEffectName = [string](
        Get-RegistryValueSafe `
            -RegistryPath $SelectedEffectPath `
            -ValueName 'previous'
    )

    $effectSettingsPath = ''

    $presetStatePath = ''

    if (
        -not [string]::IsNullOrWhiteSpace(
            $effectId
        )
    ) {
        $effectSettingsPath = Join-Path `
            $EffectsRoot `
            $effectId

        $presetStatePath = Join-Path `
            $StatesRoot `
            $effectId
    }

    $currentPreset = ''

    if (
        -not [string]::IsNullOrWhiteSpace(
            $effectSettingsPath
        )
    ) {
        $currentPreset = [string](
            Get-RegistryValueSafe `
                -RegistryPath $effectSettingsPath `
                -ValueName 'current_preset'
        )
    }

    return [pscustomobject][ordered]@{
        EffectId           = $effectId
        EffectName         = $effectName
        PreviousEffectName = $previousEffectName
        EffectSettingsPath = $effectSettingsPath
        PresetStatePath    = $presetStatePath
        CurrentPreset      = $currentPreset
    }
}

function Get-CurrentPresetStorageReport {
    param(
        [Parameter(Mandatory)]
        $CurrentEffect
    )

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$CurrentEffect.PresetStatePath
        ) -or
        -not (
            Test-Path `
                -LiteralPath $CurrentEffect.PresetStatePath
        )
    ) {
        return [pscustomobject][ordered]@{
            RegistryPath           = $CurrentEffect.PresetStatePath
            PresetCount            = 0
            CurrentPreset          = $CurrentEffect.CurrentPreset
            CurrentPresetFound     = $false
            SeparatePresetIdsFound = $false
            AliasSlots             = @()
            PresetStorageSamples   = @()
        }
    }

    $valueNames = @(
        Get-RegistryValueNamesSafe `
            -RegistryPath $CurrentEffect.PresetStatePath
    )

    $normalPresetNames = @(
        $valueNames |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notin @('A', 'B', 'C')
            }
    )

    $aliasSlots = @()

    foreach ($slot in @('A', 'B', 'C')) {
        $exists = $valueNames -contains $slot

        $slotKind = ''

        $slotDescription = $null

        if ($exists) {
            $slotValue = Get-RegistryValueSafe `
                -RegistryPath $CurrentEffect.PresetStatePath `
                -ValueName $slot

            $slotKind = Get-RegistryValueKindSafe `
                -RegistryPath $CurrentEffect.PresetStatePath `
                -ValueName $slot

            $slotDescription = Get-ValueDescription `
                -Value $slotValue
        }

        $aliasSlots += [pscustomobject][ordered]@{
            Slot      = $slot
            Exists    = $exists
            ValueKind = $slotKind
            DataType  = if ($slotDescription) {
                $slotDescription.DataType
            }
            else {
                ''
            }
            Length    = if ($slotDescription) {
                $slotDescription.Length
            }
            else {
                0
            }
        }
    }

    $samples = @()

    foreach (
        $presetName in (
            $normalPresetNames |
                Select-Object -First 10
        )
    ) {
        $presetValue = Get-RegistryValueSafe `
            -RegistryPath $CurrentEffect.PresetStatePath `
            -ValueName $presetName

        $description = Get-ValueDescription `
            -Value $presetValue

        $samples += [pscustomobject][ordered]@{
            PresetName = $presetName
            ValueKind  = Get-RegistryValueKindSafe `
                -RegistryPath $CurrentEffect.PresetStatePath `
                -ValueName $presetName
            DataType   = $description.DataType
            Length     = $description.Length
            SHA256     = $description.SHA256
            IsCurrent  = (
                $presetName -eq
                $CurrentEffect.CurrentPreset
            )
        }
    }

    $possibleIdNames = @(
        $normalPresetNames |
            Where-Object {
                $_ -match (
                    '^(?i)' +
                    '(id|guid|uuid)[:=_-]'
                )
            }
    )

    return [pscustomobject][ordered]@{
        RegistryPath = $CurrentEffect.PresetStatePath

        PresetCount = @(
            $normalPresetNames
        ).Count

        CurrentPreset = $CurrentEffect.CurrentPreset

        CurrentPresetFound = (
            $normalPresetNames -contains
            $CurrentEffect.CurrentPreset
        )

        SeparatePresetIdsFound = (
            @($possibleIdNames).Count -gt 0
        )

        AliasSlots = @($aliasSlots)

        PresetStorageSamples = @($samples)
    }
}

function Get-LayoutStorageReport {
    $layoutSubKeys = @(
        Get-RegistrySubKeyNamesSafe `
            -RegistryPath $LayoutsRoot
    )

    $currentLayout = [string](
        Get-RegistryValueSafe `
            -RegistryPath $LayoutsRoot `
            -ValueName 'currentLayout'
    )

    $previousLayout = [string](
        Get-RegistryValueSafe `
            -RegistryPath $LayoutsRoot `
            -ValueName 'previousLayout'
    )

    $internalIdCandidates = @()

    foreach ($layoutName in $layoutSubKeys) {
        $layoutPath = Join-Path `
            $LayoutsRoot `
            $layoutName

        $layoutValueNames = @(
            Get-RegistryValueNamesSafe `
                -RegistryPath $layoutPath
        )

        foreach ($valueName in $layoutValueNames) {
            if (
                $valueName -match (
                    '(?i)' +
                    '(^id$|guid|uuid|' +
                    'layout.?id|identifier)'
                )
            ) {
                $candidateValue = Get-RegistryValueSafe `
                    -RegistryPath $layoutPath `
                    -ValueName $valueName

                $internalIdCandidates += [pscustomobject][ordered]@{
                    LayoutKeyName = $layoutName
                    ValueName     = $valueName
                    ValueKind     = Get-RegistryValueKindSafe `
                        -RegistryPath $layoutPath `
                        -ValueName $valueName
                    Value         = (
                        Get-ValueDescription `
                            -Value $candidateValue
                    ).Preview
                }
            }
        }
    }

    $examples = @(
        $layoutSubKeys |
            Sort-Object |
            Select-Object -First 10
    )

    return [pscustomobject][ordered]@{
        RegistryPath = $LayoutsRoot

        LayoutCount = @(
            $layoutSubKeys
        ).Count

        CurrentLayout = $currentLayout

        PreviousLayout = $previousLayout

        CurrentLayoutMatchesSubKey = (
            $layoutSubKeys -contains
            $currentLayout
        )

        PreviousLayoutMatchesSubKey = (
            $layoutSubKeys -contains
            $previousLayout
        )

        LayoutNameExamples = @($examples)

        InternalIdCandidateCount = @(
            $internalIdCandidates
        ).Count

        InternalIdCandidates = @(
            $internalIdCandidates
        )

        ObservedIdentityMethod = if (
            @($internalIdCandidates).Count -gt 0
        ) {
            (
                'Layout subkeys are named after layouts, and ' +
                'one or more possible internal ID values were found.'
            )
        }
        else {
            (
                'Saved layout subkeys are named after the layouts. ' +
                'No separate layout ID value was observed.'
            )
        }
    }
}

function Get-SignalRgbProtocolReport {
    $candidateRoots = @(
        'Registry::HKEY_CURRENT_USER\Software\Classes\signalrgb',
        'Registry::HKEY_CLASSES_ROOT\signalrgb'
    )

    foreach ($protocolRoot in $candidateRoots) {
        $commandPath = Join-Path `
            $protocolRoot `
            'shell\open\command'

        if (
            -not (
                Test-Path `
                    -LiteralPath $commandPath
            )
        ) {
            continue
        }

        try {
            $commandKey = Get-Item `
                -LiteralPath $commandPath `
                -ErrorAction Stop

            return [pscustomobject][ordered]@{
                Registered  = $true
                RootPath    = $protocolRoot
                CommandPath = $commandPath
                Command     = [string](
                    $commandKey.GetValue('')
                )
            }
        }
        catch {
        }
    }

    return [pscustomobject][ordered]@{
        Registered  = $false
        RootPath    = ''
        CommandPath = ''
        Command     = ''
    }
}

function Get-ApiProbeResults {
    $uris = @(
        'http://localhost:16038/api/v1/lighting',
        'http://localhost:16038/api/v1/lighting/effects'
    )

    $results = @()

    foreach ($uri in $uris) {
        try {
            $response = Invoke-WebRequest `
                -Uri $uri `
                -Method Get `
                -UseBasicParsing `
                -TimeoutSec 5 `
                -ErrorAction Stop

            $results += [pscustomobject][ordered]@{
                Uri        = $uri
                Status     = 'Available'
                StatusCode = [int]$response.StatusCode
                Message    = [string](
                    $response.StatusDescription
                )
            }
        }
        catch {
            $status = 'Unavailable'
            $statusCode = $null
            $message = $_.Exception.Message
            $response = $_.Exception.Response

            if (
                $response -and
                $response.StatusCode
            ) {
                $statusCode = [int](
                    $response.StatusCode
                )

                $message = [string](
                    $response.StatusDescription
                )

                if ($statusCode -eq 403) {
                    $status = (
                        'Forbidden - Pro API access unavailable'
                    )
                }
                else {
                    $status = 'HTTP error'
                }
            }

            $results += [pscustomobject][ordered]@{
                Uri        = $uri
                Status     = $status
                StatusCode = $statusCode
                Message    = $message
            }
        }
    }

    $results
}

function Get-PathReport {
    param(
        [Parameter(Mandatory)]
        [string]$Purpose,

        [AllowEmptyString()]
        [string]$Path
    )

    $exists = $false
    $pathType = ''
    $itemCount = 0

    if (
        -not [string]::IsNullOrWhiteSpace(
            $Path
        )
    ) {
        $exists = Test-Path `
            -LiteralPath $Path

        if ($exists) {
            if (
                Test-Path `
                    -LiteralPath $Path `
                    -PathType Container
            ) {
                $pathType = 'Directory'

                try {
                    $itemCount = @(
                        Get-ChildItem `
                            -LiteralPath $Path `
                            -Force `
                            -ErrorAction SilentlyContinue
                    ).Count
                }
                catch {
                    $itemCount = 0
                }
            }
            else {
                $pathType = 'File'
                $itemCount = 1
            }
        }
    }

    return [pscustomobject][ordered]@{
        Purpose   = $Purpose
        Path      = $Path
        Exists    = $exists
        PathType  = $pathType
        ItemCount = $itemCount
    }
}

function Get-EndpointArchitectureReport {
    $endpointNames = @(
        Get-RegistrySubKeyNamesSafe `
            -RegistryPath $EndpointRoot
    )

    $positionKeyCount = 0

    foreach ($endpointName in $endpointNames) {
        $positionPath = Join-Path `
            (Join-Path $EndpointRoot $endpointName) `
            'position'

        if (
            Test-Path `
                -LiteralPath $positionPath
        ) {
            $positionKeyCount++
        }
    }

    return [pscustomobject][ordered]@{
        RegistryPath    = $EndpointRoot
        EndpointCount   = @($endpointNames).Count
        PositionKeyCount = $positionKeyCount
        EndpointExamples = @(
            $endpointNames |
                Sort-Object |
                Select-Object -First 10
        )
    }
}

function Write-JsonReport {
    param(
        [Parameter(Mandatory)]
        $Report,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Report |
        ConvertTo-Json `
            -Depth 30 |
        Set-Content `
            -LiteralPath $Path `
            -Encoding UTF8
}

function Write-MarkdownReport {
    param(
        [Parameter(Mandatory)]
        $Report,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $lines = @()

    $lines += '# SignalRGB Developer Discovery Report'
    $lines += ''
    $lines += "Created: $($Report.Report.Created)"
    $lines += "SignalRGB version: $($Report.SignalRGB.Version)"
    $lines += "Executable: $($Report.SignalRGB.ExecutablePath)"
    $lines += "Process ID: $($Report.SignalRGB.ProcessId)"
    $lines += "PowerShell version: $($Report.Report.PowerShellVersion)"
    $lines += ''
    $lines += '## Read-only guarantee'
    $lines += ''
    $lines += (
        'This report script did not change effects, presets, ' +
        'layouts, registry values, or SignalRGB processes.'
    )
    $lines += ''
    $lines += 'It only read local data and created this report.'
    $lines += ''
    $lines += '## Verified external control methods'
    $lines += ''
    $lines += '### Effect switching'
    $lines += ''
    $lines += (
        'Method: signalrgb://effect/apply/' +
        '<URL-encoded effect name>?-silentlaunch-'
    )
    $lines += ''
    $lines += (
        'Selected effect ID and name are read from: ' +
        $Report.Architecture.Effects.SelectedEffectRegistryPath
    )
    $lines += ''
    $lines += 'Status: Verified by the separate live-control test.'
    $lines += ''
    $lines += '### Preset switching'
    $lines += ''
    $lines += (
        'Saved presets are registry values under: ' +
        $Report.Architecture.Presets.SavedPresetRegistryPattern
    )
    $lines += ''
    $lines += (
        'The chosen preset value is temporarily copied into ' +
        'writable alias slot A.'
    )
    $lines += ''
    $lines += (
        'SignalRGB is then called with: ' +
        'signalrgb://effect/applypreset/' +
        '<URL-encoded effect name>/A?-silentlaunch-'
    )
    $lines += ''
    $lines += (
        'Afterward, slot A and the human-readable current_preset ' +
        'value are restored.'
    )
    $lines += ''
    $lines += (
        'Direct custom preset names in the URL failed on the ' +
        'tested SignalRGB 2.5.72 installation.'
    )
    $lines += ''
    $lines += 'Status: Verified by the separate live-control test.'
    $lines += ''
    $lines += '### Layout switching'
    $lines += ''
    $lines += (
        'Method: signalrgb://layout/apply/' +
        '<URL-encoded layout name>?-silentlaunch-'
    )
    $lines += ''
    $lines += (
        'Current and previous layouts are stored beneath: ' +
        $Report.Architecture.Layouts.RegistryPath
    )
    $lines += ''
    $lines += 'Status: Verified by the separate live-control test.'
    $lines += ''
    $lines += '### Restart requirement'
    $lines += ''
    $lines += 'No SignalRGB restart is required for these operations.'
    $lines += ''
    $lines += '## Current effect state'
    $lines += ''
    $lines += (
        'Effect name: ' +
        $Report.CurrentState.Effect.EffectName
    )
    $lines += (
        'Effect ID: ' +
        $Report.CurrentState.Effect.EffectId
    )
    $lines += (
        'Previous effect: ' +
        $Report.CurrentState.Effect.PreviousEffectName
    )
    $lines += (
        'Current preset: ' +
        $Report.CurrentState.Effect.CurrentPreset
    )
    $lines += ''
    $lines += '## Effect architecture'
    $lines += ''
    $lines += (
        'Selected effect registry path: ' +
        $Report.Architecture.Effects.SelectedEffectRegistryPath
    )
    $lines += (
        'Effect settings pattern: ' +
        $Report.Architecture.Effects.EffectSettingsRegistryPattern
    )
    $lines += (
        'Effect key count: ' +
        $Report.Architecture.Effects.EffectKeyCount
    )
    $lines += (
        'ID-style effect keys: ' +
        $Report.Architecture.Effects.IdStyleEffectKeyCount
    )
    $lines += (
        'HTML-name effect keys: ' +
        $Report.Architecture.Effects.HtmlNameEffectKeyCount
    )
    $lines += ''
    $lines += '## Preset architecture'
    $lines += ''
    $lines += (
        'Saved preset pattern: ' +
        $Report.Architecture.Presets.SavedPresetRegistryPattern
    )
    $lines += (
        'Current preset value name: ' +
        $Report.Architecture.Presets.CurrentPresetValueName
    )
    $lines += (
        'Current effect saved preset count: ' +
        $Report.CurrentState.PresetStorage.PresetCount
    )
    $lines += (
        'Current preset found as saved value: ' +
        $Report.CurrentState.PresetStorage.CurrentPresetFound
    )
    $lines += (
        'Separate preset IDs observed: ' +
        $Report.CurrentState.PresetStorage.SeparatePresetIdsFound
    )
    $lines += ''
    $lines += 'Temporary alias slots:'
    $lines += ''

    foreach (
        $slot in @(
            $Report.CurrentState.PresetStorage.AliasSlots
        )
    ) {
        $lines += (
            '- Slot ' +
            $slot.Slot +
            ': exists=' +
            $slot.Exists +
            ', kind=' +
            $slot.ValueKind
        )
    }

    $lines += ''
    $lines += '## Layout architecture'
    $lines += ''
    $lines += (
        'Layout registry path: ' +
        $Report.Architecture.Layouts.RegistryPath
    )
    $lines += (
        'Saved layout count: ' +
        $Report.Architecture.Layouts.LayoutCount
    )
    $lines += (
        'Current layout: ' +
        $Report.Architecture.Layouts.CurrentLayout
    )
    $lines += (
        'Previous layout: ' +
        $Report.Architecture.Layouts.PreviousLayout
    )
    $lines += (
        'Internal layout ID candidates: ' +
        $Report.Architecture.Layouts.InternalIdCandidateCount
    )
    $lines += (
        'Identity observation: ' +
        $Report.Architecture.Layouts.ObservedIdentityMethod
    )
    $lines += ''
    $lines += 'Layout examples:'
    $lines += ''

    foreach (
        $layoutName in @(
            $Report.Architecture.Layouts.LayoutNameExamples
        )
    ) {
        $lines += "- $layoutName"
    }

    $lines += ''
    $lines += '## URL protocol registration'
    $lines += ''
    $lines += (
        'Registered: ' +
        $Report.UrlProtocol.Registered
    )
    $lines += (
        'Registry path: ' +
        $Report.UrlProtocol.CommandPath
    )
    $lines += (
        'Command: ' +
        $Report.UrlProtocol.Command
    )
    $lines += ''
    $lines += '## Local API probes'
    $lines += ''

    foreach (
        $probe in @(
            $Report.ApiProbes
        )
    ) {
        $lines += (
            '- ' +
            $probe.Uri +
            ' | ' +
            $probe.Status +
            ' | HTTP ' +
            $probe.StatusCode
        )
    }

    $lines += ''
    $lines += '## Registry architecture summary'
    $lines += ''

    foreach (
        $schema in @(
            $Report.RegistrySchemas
        )
    ) {
        $lines += (
            '- ' +
            $schema.RegistryPath +
            ' | exists=' +
            $schema.Exists +
            ' | subkeys=' +
            $schema.SubKeyCount +
            ' | values=' +
            $schema.ValueCount
        )
    }

    $lines += ''
    $lines += '## Storage locations'
    $lines += ''

    foreach (
        $location in @(
            $Report.StorageLocations
        )
    ) {
        $lines += (
            '- ' +
            $location.Purpose +
            ': ' +
            $location.Path +
            ' | exists=' +
            $location.Exists
        )
    }

    $lines += ''
    $lines += '## Endpoint and device-position architecture'
    $lines += ''
    $lines += (
        'Endpoint registry path: ' +
        $Report.Architecture.Endpoints.RegistryPath
    )
    $lines += (
        'Endpoint count: ' +
        $Report.Architecture.Endpoints.EndpointCount
    )
    $lines += (
        'Position key count: ' +
        $Report.Architecture.Endpoints.PositionKeyCount
    )
    $lines += ''
    $lines += '## Conclusions'
    $lines += ''
    $lines += (
        'Effects have a stable selected effect ID and name record.'
    )
    $lines += ''
    $lines += (
        'Saved presets are identified by registry value names ' +
        'beneath an effect ID key.'
    )
    $lines += ''
    $lines += (
        'No separate preset ID was observed for the currently ' +
        'selected effect.'
    )
    $lines += ''
    $lines += (
        'Saved layouts are represented by registry subkey names.'
    )
    $lines += ''
    $lines += (
        'Any possible internal layout identifiers discovered are ' +
        'listed in the JSON report.'
    )
    $lines += ''
    $lines += (
        'The local HTTP API is available only when SignalRGB Pro ' +
        'authorization permits it.'
    )

    $lines |
        Set-Content `
            -LiteralPath $Path `
            -Encoding UTF8
}

Write-Host ''
Write-Host '=============================================' `
    -ForegroundColor Green

Write-Host ' SignalRGB Developer Discovery Report' `
    -ForegroundColor Green

Write-Host '=============================================' `
    -ForegroundColor Green

Write-Host ''
Write-Host 'Checking SignalRGB...'

$signalProcess = Get-SignalRgbProcess

if (-not $signalProcess) {
    throw (
        'SignalRGB is not running. Open SignalRGB normally, ' +
        'wait for it to finish loading, and rerun this script.'
    )
}

if (
    -not (
        Test-Path `
            -LiteralPath $SignalRoot
    )
) {
    throw (
        'SignalRGB registry data was not found at: ' +
        $SignalRoot
    )
}

$signalExecutablePath = [string](
    $signalProcess.ExecutablePath
)

if (
    [string]::IsNullOrWhiteSpace(
        $signalExecutablePath
    )
) {
    throw (
        'SignalRGB is running, but its executable path ' +
        'could not be read.'
    )
}

$signalExecutableFolder = Split-Path `
    -Path $signalExecutablePath `
    -Parent

$signalVersion = ''

try {
    $signalVersion = (
        [Diagnostics.FileVersionInfo]::GetVersionInfo(
            $signalExecutablePath
        )
    ).FileVersion
}
catch {
}

$outputRoot = Read-OutputFolder

$timestamp = Get-Date `
    -Format 'yyyy-MM-dd_HHmmss'

$runFolder = Join-Path `
    $outputRoot `
    "Run-$timestamp"

New-Item `
    -ItemType Directory `
    -Path $runFolder `
    -Force |
    Out-Null

Write-Host ''
Write-Host 'Reading current effect and preset state...'

$currentEffect = Get-CurrentEffectState

$presetStorage = Get-CurrentPresetStorageReport `
    -CurrentEffect $currentEffect

Write-Host 'Reading layout architecture...'

$layoutReport = Get-LayoutStorageReport

Write-Host 'Reading URL protocol registration...'

$urlProtocol = Get-SignalRgbProtocolReport

Write-Host 'Checking local SignalRGB API endpoints...'

$apiProbes = @(
    Get-ApiProbeResults
)

Write-Host 'Reading registry architecture...'

$effectSubKeys = @(
    Get-RegistrySubKeyNamesSafe `
        -RegistryPath $EffectsRoot
)

$stateSubKeys = @(
    Get-RegistrySubKeyNamesSafe `
        -RegistryPath $StatesRoot
)

$idStyleEffectKeys = @(
    $effectSubKeys |
        Where-Object {
            $_ -match (
                '^-[A-Za-z0-9_-]{10,}$'
            ) -or
            $_ -match (
                '^[0-9a-fA-F]{8}-' +
                '[0-9a-fA-F]{4}-' +
                '[0-9a-fA-F]{4}-' +
                '[0-9a-fA-F]{4}-' +
                '[0-9a-fA-F]{12}$'
            )
        }
)

$htmlNameEffectKeys = @(
    $effectSubKeys |
        Where-Object {
            $_ -match '(?i)\.html?$'
        }
)

$endpointReport = Get-EndpointArchitectureReport

$registrySchemas = @(
    Get-RegistryKeySchema `
        -RegistryPath $SignalRoot `
        -IncludeValues

    Get-RegistryKeySchema `
        -RegistryPath $EffectsRoot

    Get-RegistryKeySchema `
        -RegistryPath $SelectedEffectPath `
        -IncludeValues

    Get-RegistryKeySchema `
        -RegistryPath $StatesRoot

    Get-RegistryKeySchema `
        -RegistryPath $LayoutsRoot `
        -IncludeValues

    Get-RegistryKeySchema `
        -RegistryPath $LightingRoot `
        -IncludeValues

    Get-RegistryKeySchema `
        -RegistryPath $EndpointRoot

    Get-RegistryKeySchema `
        -RegistryPath $PlaylistsPath `
        -IncludeValues

    Get-RegistryKeySchema `
        -RegistryPath $MacroblocksRoot
)

$userDirectory = [string](
    Get-RegistryValueSafe `
        -RegistryPath $SignalRoot `
        -ValueName 'UserDirectory'
)

$storageLocations = @(
    Get-PathReport `
        -Purpose 'Running SignalRGB executable' `
        -Path $signalExecutablePath

    Get-PathReport `
        -Purpose 'Running SignalRGB application folder' `
        -Path $signalExecutableFolder

    Get-PathReport `
        -Purpose 'Bundled effects root' `
        -Path (
            Join-Path `
                $signalExecutableFolder `
                'Effects'
        )

    Get-PathReport `
        -Purpose 'Bundled static effects' `
        -Path (
            Join-Path `
                $signalExecutableFolder `
                'Effects\Static'
        )

    Get-PathReport `
        -Purpose 'Bundled dynamic effects' `
        -Path (
            Join-Path `
                $signalExecutableFolder `
                'Effects\Dynamic'
        )

    Get-PathReport `
        -Purpose 'SignalRGB user directory from registry' `
        -Path $userDirectory

    Get-PathReport `
        -Purpose 'Local WhirlwindFX data' `
        -Path (
            Join-Path `
                $env:LOCALAPPDATA `
                'WhirlwindFX'
        )

    Get-PathReport `
        -Purpose 'Local SignalRGB data' `
        -Path (
            Join-Path `
                $env:LOCALAPPDATA `
                'WhirlwindFX\SignalRgb'
        )

    Get-PathReport `
        -Purpose 'Downloaded effect cache' `
        -Path (
            Join-Path `
                $env:LOCALAPPDATA `
                'WhirlwindFX\SignalRgb\cache\effects'
        )

    Get-PathReport `
        -Purpose 'Roaming WhirlwindFX data' `
        -Path (
            Join-Path `
                $env:APPDATA `
                'WhirlwindFX'
        )

    Get-PathReport `
        -Purpose 'Documents WhirlwindFX data' `
        -Path (
            Join-Path `
                $env:USERPROFILE `
                'Documents\WhirlwindFX'
        )

    Get-PathReport `
        -Purpose 'VortxEngine root' `
        -Path (
            Join-Path `
                $env:LOCALAPPDATA `
                'VortxEngine'
        )

    Get-PathReport `
        -Purpose 'SignalRGB launcher' `
        -Path (
            Join-Path `
                $env:LOCALAPPDATA `
                'VortxEngine\SignalRgbLauncher.exe'
        )
)

$report = [pscustomobject][ordered]@{
    Report = [pscustomobject][ordered]@{
        Created = Get-Date `
            -Format 'yyyy-MM-dd HH:mm:ss'

        ScriptPurpose = (
            'Read-only SignalRGB developer architecture discovery'
        )

        ReadOnly = $true

        OutputFolder = $runFolder

        ComputerName = $env:COMPUTERNAME

        WindowsUser = $env:USERNAME

        PowerShellVersion = (
            $PSVersionTable.PSVersion.ToString()
        )
    }

    SignalRGB = [pscustomobject][ordered]@{
        ExecutablePath = $signalExecutablePath

        ExecutableFolder = $signalExecutableFolder

        Version = $signalVersion

        ProcessId = [int](
            $signalProcess.ProcessId
        )

        RegistryRoot = $SignalRoot

        UserDirectory = $userDirectory
    }

    VerifiedControlMethods = [pscustomobject][ordered]@{
        Source = (
            'Verified by the separate interactive ' +
            'live-control test script'
        )

        SignalRgbRestartRequired = $false

        Effect = [pscustomobject][ordered]@{
            Method = 'SignalRGB URL protocol'

            UrlTemplate = (
                'signalrgb://effect/apply/' +
                '<URL-encoded effect name>?-silentlaunch-'
            )

            Result = 'PASS'
        }

        Preset = [pscustomobject][ordered]@{
            Method = (
                'Temporary writable preset alias followed ' +
                'by SignalRGB URL protocol'
            )

            SavedPresetSource = (
                $StatesRoot +
                '\<Effect-ID>\<Preset-Name>'
            )

            TemporaryAlias = 'A'

            UrlTemplate = (
                'signalrgb://effect/applypreset/' +
                '<URL-encoded effect name>/A?-silentlaunch-'
            )

            RequiredCleanup = @(
                'Restore or remove temporary alias A'
                'Restore human-readable current_preset value'
            )

            DirectNamedPresetUrlObservation = (
                'A URL containing the custom preset name ' +
                'failed on the tested SignalRGB 2.5.72 installation.'
            )

            Result = 'PASS'
        }

        Layout = [pscustomobject][ordered]@{
            Method = 'SignalRGB URL protocol'

            UrlTemplate = (
                'signalrgb://layout/apply/' +
                '<URL-encoded layout name>?-silentlaunch-'
            )

            Result = 'PASS'
        }
    }

    CurrentState = [pscustomobject][ordered]@{
        Effect = $currentEffect

        PresetStorage = $presetStorage
    }

    Architecture = [pscustomobject][ordered]@{
        Effects = [pscustomobject][ordered]@{
            RegistryRoot = $EffectsRoot

            SelectedEffectRegistryPath = (
                $SelectedEffectPath
            )

            SelectedEffectIdValueName = 'id'

            SelectedEffectNameValueName = 'name'

            PreviousEffectNameValueName = 'previous'

            EffectSettingsRegistryPattern = (
                $EffectsRoot +
                '\<Effect-ID>'
            )

            EffectKeyCount = @(
                $effectSubKeys
            ).Count

            IdStyleEffectKeyCount = @(
                $idStyleEffectKeys
            ).Count

            HtmlNameEffectKeyCount = @(
                $htmlNameEffectKeys
            ).Count

            OtherEffectKeyCount = (
                @($effectSubKeys).Count -
                @($idStyleEffectKeys).Count -
                @($htmlNameEffectKeys).Count
            )
        }

        Presets = [pscustomobject][ordered]@{
            RegistryRoot = $StatesRoot

            SavedPresetRegistryPattern = (
                $StatesRoot +
                '\<Effect-ID>\<Preset-Name>'
            )

            CurrentPresetRegistryPattern = (
                $EffectsRoot +
                '\<Effect-ID>\current_preset'
            )

            CurrentPresetValueName = 'current_preset'

            StateKeyCount = @(
                $stateSubKeys
            ).Count

            ObservedIdentityMethod = (
                'Preset names are registry value names beneath ' +
                'their owning effect ID key.'
            )

            SeparatePresetIdObserved = (
                $presetStorage.SeparatePresetIdsFound
            )
        }

        Layouts = $layoutReport

        Endpoints = $endpointReport

        Playlists = [pscustomobject][ordered]@{
            RegistryPath = $PlaylistsPath

            Exists = Test-Path `
                -LiteralPath $PlaylistsPath

            ValueCount = @(
                Get-RegistryValueNamesSafe `
                    -RegistryPath $PlaylistsPath
            ).Count
        }

        Macroblocks = [pscustomobject][ordered]@{
            RegistryPath = $MacroblocksRoot

            Exists = Test-Path `
                -LiteralPath $MacroblocksRoot

            RootSubKeyCount = @(
                Get-RegistrySubKeyNamesSafe `
                    -RegistryPath $MacroblocksRoot
            ).Count
        }
    }

    UrlProtocol = $urlProtocol

    ApiProbes = @($apiProbes)

    RegistrySchemas = @($registrySchemas)

    StorageLocations = @($storageLocations)
}

$jsonPath = Join-Path `
    $runFolder `
    'SignalRGB-Developer-Discovery-Report.json'

$markdownPath = Join-Path `
    $runFolder `
    'SignalRGB-Developer-Discovery-Report.md'

Write-Host 'Writing JSON report...'

Write-JsonReport `
    -Report $report `
    -Path $jsonPath

Write-Host 'Writing Markdown report...'

Write-MarkdownReport `
    -Report $report `
    -Path $markdownPath

Write-Host ''
Write-Host '=============================================' `
    -ForegroundColor Green

Write-Host ' Developer discovery completed successfully' `
    -ForegroundColor Green

Write-Host '=============================================' `
    -ForegroundColor Green

Write-Host ''
Write-Host 'No SignalRGB settings or registry values were changed.'
Write-Host ''
Write-Host 'Reports created:'
Write-Host "Markdown: $markdownPath"
Write-Host "JSON:     $jsonPath"
Write-Host ''
Write-Host 'Send back both generated report files.'
