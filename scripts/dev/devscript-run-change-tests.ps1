#requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SignalRoot   = 'HKCU:\SOFTWARE\WhirlwindFX\SignalRgb'
$EffectsRoot  = Join-Path $SignalRoot 'effects'
$StatesRoot   = Join-Path $SignalRoot 'states'
$SelectedRoot = Join-Path $EffectsRoot 'selected'
$LayoutsRoot  = Join-Path $SignalRoot 'layouts'
$EndpointRoot = Join-Path $SignalRoot 'lighting\endpoint'

$Results = [System.Collections.Generic.List[object]]::new()

function Read-ConsoleInput {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    Write-Host -NoNewline $Prompt
    return [Console]::ReadLine()
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    while ($true) {
        $answer = (
            Read-ConsoleInput "$Prompt [y/n] "
        ).Trim().ToLowerInvariant()

        if ($answer -in @('y', 'yes')) {
            return $true
        }

        if ($answer -in @('n', 'no')) {
            return $false
        }

        Write-Host 'Enter Y or N.' -ForegroundColor Red
    }
}

function Add-TestResult {
    param(
        [Parameter(Mandatory)]
        [string]$Test,

        [Parameter(Mandatory)]
        [string]$Result,

        [Parameter(Mandatory)]
        [string]$Details
    )

    $Results.Add(
        [pscustomobject]@{
            Test    = $Test
            Result  = $Result
            Details = $Details
        }
    )
}

function Encode-UrlSegment {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    return [Uri]::EscapeDataString($Text)
}

function Invoke-SignalRgbUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    Write-Host ''
    Write-Host "Launching: $Url" -ForegroundColor DarkGray

    Start-Process -FilePath $Url
}

function Get-SelectedEffect {
    if (-not (Test-Path -LiteralPath $SelectedRoot)) {
        throw "Selected-effect registry key was not found: $SelectedRoot"
    }

    $data = Get-ItemProperty `
        -LiteralPath $SelectedRoot `
        -ErrorAction Stop

    return [pscustomobject]@{
        Id = if (
            $data.PSObject.Properties.Name -contains 'id'
        ) {
            [string]$data.id
        }
        else {
            ''
        }

        Name = if (
            $data.PSObject.Properties.Name -contains 'name'
        ) {
            [string]$data.name
        }
        else {
            ''
        }

        Previous = if (
            $data.PSObject.Properties.Name -contains 'previous'
        ) {
            [string]$data.previous
        }
        else {
            ''
        }
    }
}

function Get-CurrentPreset {
    param(
        [Parameter(Mandatory)]
        [string]$EffectId
    )

    $effectPath = Join-Path $EffectsRoot $EffectId

    if (-not (Test-Path -LiteralPath $effectPath)) {
        return ''
    }

    $data = Get-ItemProperty `
        -LiteralPath $effectPath `
        -ErrorAction SilentlyContinue

    if (
        $data -and
        $data.PSObject.Properties.Name -contains 'current_preset'
    ) {
        return [string]$data.current_preset
    }

    return ''
}

function Get-PresetNames {
    param(
        [Parameter(Mandatory)]
        [string]$EffectId
    )

    $statePath = Join-Path $StatesRoot $EffectId

    if (-not (Test-Path -LiteralPath $statePath)) {
        return @()
    }

    return @(
        (Get-Item -LiteralPath $statePath).
            GetValueNames() |
        Where-Object {
            $_ -notin @('A', 'B', 'C') -and
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Sort-Object -Unique
    )
}

function Get-NextItem {
    param(
        [Parameter(Mandatory)]
        [string[]]$Items,

        [AllowEmptyString()]
        [string]$Current
    )

    if ($Items.Count -eq 0) {
        return ''
    }

    $currentIndex = [Array]::IndexOf($Items, $Current)

    if ($currentIndex -lt 0) {
        return $Items[0]
    }

    return $Items[
        ($currentIndex + 1) % $Items.Count
    ]
}

function Wait-ForValue {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ValueScript,

        [Parameter(Mandatory)]
        [string]$Expected,

        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $actual = [string](& $ValueScript)

        if ($actual -eq $Expected) {
            return $true
        }

        Start-Sleep -Milliseconds 250
    }

    return $false
}

function Get-RegistryFingerprint {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return ''
    }

    $lines = [System.Collections.Generic.List[string]]::new()

    $keys = @(
        Get-Item -LiteralPath $Root
    ) + @(
        Get-ChildItem `
            -LiteralPath $Root `
            -Recurse `
            -ErrorAction SilentlyContinue
    )

    foreach ($key in $keys | Sort-Object Name) {
        foreach ($valueName in $key.GetValueNames() | Sort-Object) {
            try {
                $value = $key.GetValue($valueName)

                if ($value -is [byte[]]) {
                    $valueText = [Convert]::ToBase64String($value)
                }
                elseif (
                    $value -is [Array] -and
                    $value -isnot [string]
                ) {
                    $valueText = $value -join '|'
                }
                else {
                    $valueText = [string]$value
                }

                $lines.Add(
                    "$($key.Name)|$valueName|$valueText"
                )
            }
            catch {
            }
        }
    }

    $text = $lines -join "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)

    $sha256 = [Security.Cryptography.SHA256]::Create()

    try {
        return (
            [BitConverter]::ToString(
                $sha256.ComputeHash($bytes)
            ) -replace '-', ''
        )
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-LayoutNames {
    if (-not (Test-Path -LiteralPath $LayoutsRoot)) {
        return @()
    }

    return @(
        Get-ChildItem `
            -LiteralPath $LayoutsRoot `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.GetValueNames().Count -gt 0
        } |
        Select-Object -ExpandProperty PSChildName |
        Sort-Object -Unique
    )
}

function Get-CurrentLayout {
    if (-not (Test-Path -LiteralPath $LayoutsRoot)) {
        return ''
    }

    $data = Get-ItemProperty `
        -LiteralPath $LayoutsRoot `
        -ErrorAction SilentlyContinue

    if (
        $data -and
        $data.PSObject.Properties.Name -contains 'currentLayout'
    ) {
        return [string]$data.currentLayout
    }

    return ''
}

function Restore-LayoutRegistryValues {
    param(
        [Parameter(Mandatory)]
        [string]$CurrentLayout,

        [Parameter(Mandatory)]
        [string]$PreviousLayout
    )

    Set-ItemProperty `
        -LiteralPath $LayoutsRoot `
        -Name 'currentLayout' `
        -Value $CurrentLayout `
        -Type String

    Set-ItemProperty `
        -LiteralPath $LayoutsRoot `
        -Name 'previousLayout' `
        -Value $PreviousLayout `
        -Type String
}

$signalProcess = Get-Process `
    -Name 'SignalRgb' `
    -ErrorAction SilentlyContinue

if (-not $signalProcess) {
    throw 'SignalRGB is not running. Open it fully and rerun this test.'
}

if (-not (Test-Path -LiteralPath $SignalRoot)) {
    throw "SignalRGB registry data was not found: $SignalRoot"
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' SIGNALRGB EXTERNAL LIVE-CONTROL TEST'
Write-Host '========================================' -ForegroundColor Green

$startingEffect = Get-SelectedEffect
$startingPreset = Get-CurrentPreset `
    -EffectId $startingEffect.Id

$startingLayout = Get-CurrentLayout

$layoutRootData = Get-ItemProperty `
    -LiteralPath $LayoutsRoot `
    -ErrorAction SilentlyContinue

$startingPreviousLayout = if (
    $layoutRootData -and
    $layoutRootData.PSObject.Properties.Name -contains 'previousLayout'
) {
    [string]$layoutRootData.previousLayout
}
else {
    ''
}

Write-Host ''
Write-Host "Starting effect: $($startingEffect.Name)"
Write-Host "Starting effect ID: $($startingEffect.Id)"
Write-Host "Starting preset: $startingPreset"
Write-Host "Starting layout: $startingLayout"

# ------------------------------------------------------------
# TEST 1: APPLY NEXT PRESET THROUGH A TEMPORARY WRITABLE SLOT
# ------------------------------------------------------------

Write-Host ''
Write-Host '=== TEST 1: PRESET SWITCHING ===' -ForegroundColor Green

$presets = @(
    Get-PresetNames `
        -EffectId $startingEffect.Id
)

if ($presets.Count -lt 2) {
    Write-Host 'Skipped: current effect has fewer than two saved presets.' `
        -ForegroundColor Yellow

    Add-TestResult `
        -Test 'Preset writable alias' `
        -Result 'SKIPPED' `
        -Details 'The starting effect had fewer than two normal saved presets.'
}
elseif (Read-YesNo 'Run the preset-switch test?') {
    $targetPreset = Get-NextItem `
        -Items $presets `
        -Current $startingPreset

    $stateSubKey = (
        "SOFTWARE\WhirlwindFX\SignalRgb\states\$($startingEffect.Id)"
    )

    $effectSubKey = (
        "SOFTWARE\WhirlwindFX\SignalRgb\effects\$($startingEffect.Id)"
    )

    $stateKey = $null
    $effectKey = $null

    $slot = 'A'
    $slotPreviouslyExisted = $false
    $oldSlotValue = $null
    $oldSlotKind = $null

    $registryChangedToSlot = $false
    $afterTargetPreset = ''
    $afterRestorePreset = ''
    $targetApplied = $false
    $originalRestored = $false
    $temporarySlotRestored = $false
    $presetError = ''

    try {
        $stateKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            $stateSubKey,
            $true
        )

        $effectKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            $effectSubKey,
            $true
        )

        if (-not $stateKey) {
            throw "Could not open the preset registry key: $stateSubKey"
        }

        if (-not $effectKey) {
            throw "Could not open the effect registry key: $effectSubKey"
        }

        $allValueNames = @($stateKey.GetValueNames())

        if ($allValueNames -contains $slot) {
            $slotPreviouslyExisted = $true

            $oldSlotValue = $stateKey.GetValue(
                $slot,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::
                    DoNotExpandEnvironmentNames
            )

            $oldSlotKind = $stateKey.GetValueKind($slot)
        }

        $targetValue = $stateKey.GetValue(
            $targetPreset,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::
                DoNotExpandEnvironmentNames
        )

        if ($null -eq $targetValue) {
            throw "Could not read target preset '$targetPreset'."
        }

        $targetKind = $stateKey.GetValueKind($targetPreset)

        $originalValue = $stateKey.GetValue(
            $startingPreset,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::
                DoNotExpandEnvironmentNames
        )

        if ($null -eq $originalValue) {
            throw "Could not read original preset '$startingPreset'."
        }

        $originalKind = $stateKey.GetValueKind($startingPreset)

        Write-Host "Current preset: $startingPreset"
        Write-Host "Target preset:  $targetPreset"
        Write-Host "Temporary slot: $slot"

        Write-Host ''
        Write-Host 'Copying the target preset into temporary slot A...' `
            -ForegroundColor Green

        $stateKey.SetValue(
            $slot,
            $targetValue,
            $targetKind
        )

        $effectEncoded = Encode-UrlSegment $startingEffect.Name

        $targetPresetUrl = (
            "signalrgb://effect/applypreset/" +
            "$effectEncoded/$slot" +
            '?-silentlaunch-'
        )

        Invoke-SignalRgbUrl -Url $targetPresetUrl

        $registryChangedToSlot = Wait-ForValue `
            -ValueScript {
                Get-CurrentPreset `
                    -EffectId $startingEffect.Id
            } `
            -Expected $slot `
            -TimeoutSeconds 10

        $afterTargetPreset = Get-CurrentPreset `
            -EffectId $startingEffect.Id

        $targetApplied = Read-YesNo `
            "Did the RGB visibly change to preset '$targetPreset'?"

        Write-Host ''
        Write-Host 'Restoring the original preset through slot A...' `
            -ForegroundColor Green

        $stateKey.SetValue(
            $slot,
            $originalValue,
            $originalKind
        )

        $restorePresetUrl = (
            "signalrgb://effect/applypreset/" +
            "$effectEncoded/$slot" +
            '?-silentlaunch-'
        )

        Invoke-SignalRgbUrl -Url $restorePresetUrl

        Start-Sleep -Seconds 4

        $afterRestorePreset = Get-CurrentPreset `
            -EffectId $startingEffect.Id

        $originalRestored = Read-YesNo `
            "Did the RGB visibly return to preset '$startingPreset'?"

        # SignalRGB reports the temporary alias name after applying it.
        # Restore the human-readable saved-preset name after the live restore.
        $effectKey.SetValue(
            'current_preset',
            $startingPreset,
            [Microsoft.Win32.RegistryValueKind]::String
        )
    }
    catch {
        $presetError = $_.Exception.Message

        Write-Host ''
        Write-Host "Preset test error: $presetError" `
            -ForegroundColor Red
    }
    finally {
        if ($effectKey) {
            try {
                $effectKey.SetValue(
                    'current_preset',
                    $startingPreset,
                    [Microsoft.Win32.RegistryValueKind]::String
                )
            }
            catch {
            }
        }

        if ($stateKey) {
            try {
                if ($slotPreviouslyExisted) {
                    $stateKey.SetValue(
                        $slot,
                        $oldSlotValue,
                        $oldSlotKind
                    )
                }
                else {
                    $stateKey.DeleteValue(
                        $slot,
                        $false
                    )
                }

                $temporarySlotRestored = $true
            }
            catch {
                $temporarySlotRestored = $false
            }
        }

        if ($effectKey) {
            $effectKey.Close()
        }

        if ($stateKey) {
            $stateKey.Close()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($presetError)) {
        $presetResult = 'ERROR'
    }
    elseif (
        $registryChangedToSlot -and
        $targetApplied -and
        $originalRestored -and
        $temporarySlotRestored
    ) {
        $presetResult = 'PASS'
    }
    elseif (
        $registryChangedToSlot -or
        $targetApplied
    ) {
        $presetResult = 'PARTIAL'
    }
    else {
        $presetResult = 'FAIL'
    }

    Add-TestResult `
        -Test 'Preset writable alias' `
        -Result $presetResult `
        -Details (
            "Target='$targetPreset'; " +
            "TemporarySlot='$slot'; " +
            "RegistryAfterTarget='$afterTargetPreset'; " +
            "TargetVisiblyApplied=$targetApplied; " +
            "RegistryAfterRestore='$afterRestorePreset'; " +
            "OriginalVisiblyRestored=$originalRestored; " +
            "TemporarySlotRestored=$temporarySlotRestored; " +
            "Error='$presetError'"
        )

    Start-Sleep -Seconds 1
}
else {
    Add-TestResult `
        -Test 'Preset writable alias' `
        -Result 'SKIPPED' `
        -Details 'User skipped the test.'
}

# ------------------------------------------------------------
# TEST 2: APPLY ANOTHER EFFECT THROUGH SIGNALRGB URL
# ------------------------------------------------------------

Write-Host ''
Write-Host '=== TEST 2: EFFECT SWITCHING ===' -ForegroundColor Green

$currentBeforeEffectTest = Get-SelectedEffect
$targetEffectName = $currentBeforeEffectTest.Previous

if (
    -not $targetEffectName -or
    $targetEffectName -eq $currentBeforeEffectTest.Name
) {
    Write-Host 'Enter the exact name of another installed effect:'

    $targetEffectName = (
        Read-ConsoleInput 'Effect Name> '
    ).Trim()
}

if (-not $targetEffectName) {
    Add-TestResult `
        -Test 'Effect URL' `
        -Result 'SKIPPED' `
        -Details 'No target effect was available.'
}
elseif (Read-YesNo "Switch temporarily to '$targetEffectName'?") {
    $targetEffectEncoded = Encode-UrlSegment $targetEffectName

    $effectUrl = (
        "signalrgb://effect/apply/" +
        $targetEffectEncoded +
        '?-silentlaunch-'
    )

    Invoke-SignalRgbUrl -Url $effectUrl

    $registryChanged = Wait-ForValue `
        -ValueScript {
            (Get-SelectedEffect).Name
        } `
        -Expected $targetEffectName `
        -TimeoutSeconds 12

    $visuallyChanged = Read-YesNo `
        "Did SignalRGB visibly switch to effect '$targetEffectName'?"

    if ($registryChanged -and $visuallyChanged) {
        $effectResult = 'PASS'
    }
    elseif ($registryChanged) {
        $effectResult = 'PARTIAL'
    }
    else {
        $effectResult = 'FAIL'
    }

    Add-TestResult `
        -Test 'Effect URL' `
        -Result $effectResult `
        -Details (
            "Target='$targetEffectName'; " +
            "RegistryChanged=$registryChanged; " +
            "VisuallyChanged=$visuallyChanged"
        )

    Write-Host ''
    Write-Host 'Restoring the original effect...' -ForegroundColor Green

    $originalEffectEncoded = Encode-UrlSegment `
        $currentBeforeEffectTest.Name

    $restoreEffectUrl = (
        "signalrgb://effect/apply/" +
        $originalEffectEncoded +
        '?-silentlaunch-'
    )

    Invoke-SignalRgbUrl -Url $restoreEffectUrl

    [void](
        Wait-ForValue `
            -ValueScript {
                (Get-SelectedEffect).Name
            } `
            -Expected $currentBeforeEffectTest.Name `
            -TimeoutSeconds 12
    )

    Start-Sleep -Seconds 2
}
else {
    Add-TestResult `
        -Test 'Effect URL' `
        -Result 'SKIPPED' `
        -Details 'User skipped the test.'
}

# ------------------------------------------------------------
# TEST 3: LAYOUT URL ROUTES
# ------------------------------------------------------------

Write-Host ''
Write-Host '=== TEST 3: LAYOUT SWITCHING ===' -ForegroundColor Green

$layouts = @(
    Get-LayoutNames
)

$currentLayout = Get-CurrentLayout

if ($layouts.Count -lt 2) {
    Write-Host 'Skipped: fewer than two saved layouts were found.' `
        -ForegroundColor Yellow

    Add-TestResult `
        -Test 'Layout switching' `
        -Result 'SKIPPED' `
        -Details 'Fewer than two saved layouts were found.'
}
elseif (Read-YesNo 'Run the layout-switch test?') {
    $targetLayout = Get-NextItem `
        -Items $layouts `
        -Current $currentLayout

    Write-Host "Current layout: $currentLayout"
    Write-Host "Target layout:  $targetLayout"

    $targetLayoutEncoded = Encode-UrlSegment $targetLayout
    $workingLayoutUrl = ''
    $layoutUrlWorked = $false

    $layoutUrlCandidates = @(
        "signalrgb://layout/apply/$targetLayoutEncoded`?-silentlaunch-"
        "signalrgb://scene/apply/$targetLayoutEncoded`?-silentlaunch-"
    )

    foreach ($candidateUrl in $layoutUrlCandidates) {
        Write-Host ''
        Write-Host 'Testing a layout URL route...' -ForegroundColor Green

        Invoke-SignalRgbUrl -Url $candidateUrl

        $changed = Wait-ForValue `
            -ValueScript {
                Get-CurrentLayout
            } `
            -Expected $targetLayout `
            -TimeoutSeconds 6

        if ($changed) {
            $layoutUrlWorked = $true
            $workingLayoutUrl = $candidateUrl
            break
        }
    }

    if ($layoutUrlWorked) {
        $visuallyChanged = Read-YesNo `
            "Did SignalRGB visibly apply layout '$targetLayout'?"

        if ($visuallyChanged) {
            $layoutResult = 'PASS'
        }
        else {
            $layoutResult = 'PARTIAL'
        }

        Add-TestResult `
            -Test 'Layout URL' `
            -Result $layoutResult `
            -Details (
                "Target='$targetLayout'; " +
                "WorkingUrl='$workingLayoutUrl'; " +
                "VisuallyChanged=$visuallyChanged"
            )

        Write-Host ''
        Write-Host 'Restoring the original layout...' -ForegroundColor Green

        $originalLayoutEncoded = Encode-UrlSegment $currentLayout

        if ($workingLayoutUrl -like 'signalrgb://layout/*') {
            $restoreLayoutUrl = (
                "signalrgb://layout/apply/" +
                $originalLayoutEncoded +
                '?-silentlaunch-'
            )
        }
        else {
            $restoreLayoutUrl = (
                "signalrgb://scene/apply/" +
                $originalLayoutEncoded +
                '?-silentlaunch-'
            )
        }

        Invoke-SignalRgbUrl -Url $restoreLayoutUrl

        [void](
            Wait-ForValue `
                -ValueScript {
                    Get-CurrentLayout
                } `
                -Expected $currentLayout `
                -TimeoutSeconds 8
        )
    }
    else {
        Add-TestResult `
            -Test 'Layout URL' `
            -Result 'FAIL' `
            -Details 'Neither tested URL route changed currentLayout.'

        Write-Host ''
        Write-Host (
            'No layout URL route responded. ' +
            'Testing live registry reload instead.'
        ) -ForegroundColor Yellow

        $endpointFingerprintBefore = Get-RegistryFingerprint `
            -Root $EndpointRoot

        $originalCurrentLayout = Get-CurrentLayout

        $layoutData = Get-ItemProperty `
            -LiteralPath $LayoutsRoot `
            -ErrorAction SilentlyContinue

        $originalPreviousLayout = if (
            $layoutData -and
            $layoutData.PSObject.Properties.Name -contains
                'previousLayout'
        ) {
            [string]$layoutData.previousLayout
        }
        else {
            ''
        }

        Set-ItemProperty `
            -LiteralPath $LayoutsRoot `
            -Name 'previousLayout' `
            -Value $originalCurrentLayout `
            -Type String

        Set-ItemProperty `
            -LiteralPath $LayoutsRoot `
            -Name 'currentLayout' `
            -Value $targetLayout `
            -Type String

        Write-Host ''
        Write-Host 'Waiting five seconds for SignalRGB to react...'
        Start-Sleep -Seconds 5

        $endpointFingerprintAfter = Get-RegistryFingerprint `
            -Root $EndpointRoot

        $endpointDataChanged = (
            $endpointFingerprintBefore -ne
            $endpointFingerprintAfter
        )

        $visuallyChanged = Read-YesNo `
            "Did the visible device layout change to '$targetLayout'?"

        if ($endpointDataChanged -and $visuallyChanged) {
            $registryResult = 'PASS'
        }
        elseif ($endpointDataChanged -or $visuallyChanged) {
            $registryResult = 'PARTIAL'
        }
        else {
            $registryResult = 'FAIL'
        }

        Add-TestResult `
            -Test 'Layout registry live reload' `
            -Result $registryResult `
            -Details (
                "Target='$targetLayout'; " +
                "EndpointDataChanged=$endpointDataChanged; " +
                "VisuallyChanged=$visuallyChanged"
            )

        Write-Host ''
        Write-Host 'Restoring the original layout registry values...' `
            -ForegroundColor Green

        Restore-LayoutRegistryValues `
            -CurrentLayout $originalCurrentLayout `
            -PreviousLayout $originalPreviousLayout

        Start-Sleep -Seconds 5

        if ($visuallyChanged) {
            [void](
                Read-ConsoleInput (
                    'Confirm the original layout is visible again, ' +
                    'then press Enter '
                )
            )
        }
    }
}
else {
    Add-TestResult `
        -Test 'Layout switching' `
        -Result 'SKIPPED' `
        -Details 'User skipped the test.'
}

# ------------------------------------------------------------
# FINAL SAFETY RESTORE
# ------------------------------------------------------------

Write-Host ''
Write-Host 'Performing final registry safety restoration...' `
    -ForegroundColor Green

Restore-LayoutRegistryValues `
    -CurrentLayout $startingLayout `
    -PreviousLayout $startingPreviousLayout

Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' FINAL TEST RESULTS'
Write-Host '========================================' -ForegroundColor Green
Write-Host ''

$Results |
    Format-Table `
        Test,
        Result,
        Details `
        -AutoSize `
        -Wrap

Write-Host ''
Write-Host 'Copy and send me the full FINAL TEST RESULTS section.'
Write-Host 'SignalRGB was not restarted or closed.'
