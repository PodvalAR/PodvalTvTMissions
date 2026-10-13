#requires -Version 5.1
Set-StrictMode -Off

# ------------------------------------------------------------------ remap table
# Walk the (nested, human-grouped) remap JSON. Any property whose NAME is a full ref is
# an entry; a filled value (also a ref) is an active mapping, an empty/invalid value is
# a stub that is intentionally skipped so it still surfaces as unresolved.
function Load-RemapTable {
    [CmdletBinding()]
    param([string]$Path = $script:RMC.RemapTable)

    $map = [ordered]@{}      # full-old-ref -> full-new-ref (filled only)
    $stubs = [ordered]@{}    # full-old-ref -> '' (declared but unfilled)
    $mappedGuids = @{}
    $occurrences = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Map=$map; Stubs=$stubs; MappedGuids=$mappedGuids; Entries=$occurrences.ToArray() }
    }
    $json = Read-Text $Path | ConvertFrom-Json
    $entries = [ordered]@{}
    $walk = {
        param($node)
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Value -is [string]) {
                if ($p.Name -match $script:RefShape) {
                    $entries[$p.Name] = [string]$p.Value
                    $occurrences.Add([pscustomobject]@{ OldRef=$p.Name; NewRef=[string]$p.Value })
                }
            }
            elseif ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count) {
                & $walk $p.Value
            }
        }
    }
    & $walk $json
    foreach ($k in $entries.Keys) {
        if ($entries[$k] -match $script:RefShape) {
            $map[$k] = $entries[$k]
            if ($k -match '^\{([0-9A-Fa-f]{16})\}') { $mappedGuids[$Matches[1].ToUpper()] = $true }
        } else {
            $stubs[$k] = ''
        }
    }
    return [pscustomobject]@{ Map=$map; Stubs=$stubs; MappedGuids=$mappedGuids; Entries=$occurrences.ToArray() }
}

function Get-RMReplacementIndex($Remap, [hashtable]$ModIndex) {
    $byGuid = @{}; $invalid = @{}; $sourceGuids = @{}; $targets = @{}
    $entries = if ($null -ne $Remap.PSObject.Properties['Entries']) { @($Remap.Entries) }
        else { @($Remap.Map.Keys | ForEach-Object { [pscustomobject]@{ OldRef=$_; NewRef=$Remap.Map[$_] } }) }
    foreach ($entry in $entries) {
        $oldGuid = Guid-Of $entry.OldRef
        if (-not $oldGuid) { continue }
        if ([string]::IsNullOrWhiteSpace($entry.NewRef)) { continue }
        $sourceGuids[$oldGuid] = $true
        $newGuid = Guid-Of $entry.NewRef
        $newPath = if ($entry.NewRef -match $script:RefShape) { $entry.NewRef.Substring(18) } else { $null }
        if (-not $newGuid -or -not $newPath -or -not $ModIndex.ContainsKey($newGuid) -or $ModIndex[$newGuid] -ne $newPath) {
            $invalid[$oldGuid] = $true
            continue
        }
        if ($targets.ContainsKey($oldGuid) -and $targets[$oldGuid] -ne $newGuid) { $invalid[$oldGuid] = $true; continue }
        $targets[$oldGuid] = $newGuid
        if (-not $byGuid.ContainsKey($oldGuid)) {
            $byGuid[$oldGuid] = [pscustomobject]@{ OldRef=$entry.OldRef; NewRef=('{' + $newGuid + '}' + $ModIndex[$newGuid]) }
        }
    }
    foreach ($guid in $invalid.Keys) { $byGuid.Remove($guid) }
    return [pscustomobject]@{ ByGuid=$byGuid; InvalidGuids=$invalid; SourceGuids=$sourceGuids }
}

function Guid-Of([string]$fullRef) {
    if ($fullRef -match '^\{([0-9A-Fa-f]{16})\}') { return $Matches[1].ToUpper() }
    return $null
}

function Get-RemapFileHash([string]$Path = $script:RMC.RemapTable) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash($bytes)
    return [System.BitConverter]::ToString($hash).Replace('-', '').ToLower()
}

function Validate-RemapEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OldRef,
        [Parameter()][string]$NewRef,
        [Parameter(Mandatory)][hashtable]$ModIndex,
        [Parameter()][hashtable]$OldRefCounts
    )

    if ($OldRef -notmatch $script:RefShape) {
        return [pscustomobject]@{ Status = 'malformed'; Message = 'Старый реф имеет некорректный формат (ожидается {16-HEX-GUID}Path.et)' }
    }
    if ($OldRefCounts -and $OldRefCounts[$OldRef] -gt 1) {
        return [pscustomobject]@{ Status = 'dup'; Message = 'Дубликат: префаб присутствует в нескольких группах базы' }
    }
    if ([string]::IsNullOrWhiteSpace($NewRef)) {
        return [pscustomobject]@{ Status = 'stub'; Message = 'Заглушка (ожидает подбора замены)' }
    }
    if ($NewRef -notmatch $script:RefShape) {
        return [pscustomobject]@{ Status = 'malformed'; Message = 'Новый реф имеет некорректный формат (ожидается {16-HEX-GUID}Path.et)' }
    }
    if ($OldRef -eq $NewRef) {
        return [pscustomobject]@{ Status = 'self-mapping'; Message = 'Старый и новый реф совпадают' }
    }

    $newGuid = Guid-Of $NewRef
    $NewRef -match '^\{[0-9A-Fa-f]{16}\}(.+)$' | Out-Null
    $newRelPath = $Matches[1]

    if (-not $ModIndex.ContainsKey($newGuid)) {
        return [pscustomobject]@{ Status = 'target-missing'; Message = "Целевой префаб {$newGuid} отсутствует в моде" }
    }

    $actualPath = $ModIndex[$newGuid]
    if ($newRelPath -ne $actualPath) {
        return [pscustomobject]@{ Status = 'path-mismatch'; Message = "Путь не совпадает с модом (в моде: $actualPath)" }
    }

    $oldGuid = Guid-Of $OldRef
    if ($ModIndex.ContainsKey($oldGuid)) {
        return [pscustomobject]@{ Status = 'source-alive'; Message = "Исходный префаб найден в текущем моде ($($ModIndex[$oldGuid]))" }
    }

    return [pscustomobject]@{ Status = 'ok'; Message = 'Корректный маппинг' }
}

function Get-RemapModel {
    [CmdletBinding()]
    param([string]$Path = $script:RMC.RemapTable)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            meta        = [pscustomobject]@{ description = ''; status = '' }
            versionHash = ''
            groups      = @()
            tree        = [pscustomobject]@{}
            entries     = @()
            stats       = [pscustomobject]@{ total = 0; filled = 0; stubs = 0; errors = 0; warnings = 0 }
        }
    }

    $raw = Read-Text $Path
    $hash = Get-RemapFileHash $Path
    $json = $raw | ConvertFrom-Json
    # Read-only view: tolerate a missing prefab mod by validating against the catalog
    # snapshot instead of an empty index (which would flag every entry as broken).
    $effective = Get-RMEffectiveModIndex
    $modIndex = $effective.Index

    # Count occurrences of old refs to detect dups
    $oldRefCounts = @{}
    $countWalk = {
        param($node)
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Value -is [string] -and $p.Name -match $script:RefShape) {
                $oldRefCounts[$p.Name] = [int]$oldRefCounts[$p.Name] + 1
            } elseif ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count -gt 0 -and $p.Name -notmatch $script:RefShape) {
                & $countWalk $p.Value
            }
        }
    }
    & $countWalk $json

    $entries = New-Object System.Collections.Generic.List[object]
    $groupSet = New-Object System.Collections.Generic.HashSet[string]

    $walk = {
        param($node, [string[]]$trail)
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -eq '_meta' -and $trail.Length -eq 0) { continue }
            if ($p.Value -is [string]) {
                if ($p.Name -match $script:RefShape) {
                    $grpStr = $trail -join '/'
                    if ($grpStr) { [void]$groupSet.Add($grpStr) }
                    $v = Validate-RemapEntry -OldRef $p.Name -NewRef $p.Value -ModIndex $modIndex -OldRefCounts $oldRefCounts
                    $entries.Add([pscustomobject]@{
                        oldRef    = $p.Name
                        newRef    = [string]$p.Value
                        group     = $grpStr
                        groupPath = $trail
                        status    = $v.Status
                        statusMsg = $v.Message
                        oldGuid   = (Guid-Of $p.Name)
                        newGuid   = (Guid-Of $p.Value)
                    })
                }
            } elseif ($null -ne $p.Value -and $p.Value.PSObject -and $p.Value.PSObject.Properties.Count -gt 0) {
                $subTrail = $trail + @($p.Name)
                [void]$groupSet.Add(($subTrail -join '/'))
                & $walk $p.Value $subTrail
            }
        }
    }
    & $walk $json @()

    $metaObj = [pscustomobject]@{
        description = if ($json._meta -and $json._meta.description) { [string]$json._meta.description } else { '' }
        status      = if ($json._meta -and $json._meta.status) { [string]$json._meta.status } else { '' }
    }

    $st = @{ total = $entries.Count; filled = 0; stubs = 0; errors = 0; warnings = 0 }
    foreach ($e in $entries) {
        if ($e.status -eq 'stub') { $st.stubs++ }
        elseif ($e.status -eq 'ok') { $st.filled++ }
        elseif ($e.status -in @('target-missing', 'path-mismatch', 'malformed', 'dup')) {
            $st.errors++
            if ($e.newRef) { $st.filled++ }
        }
        elseif ($e.status -in @('source-alive', 'self-mapping')) {
            $st.warnings++
            if ($e.newRef) { $st.filled++ }
        }
    }

    $sortedGroups = @($groupSet) | Sort-Object

    return [pscustomobject]@{
        meta        = $metaObj
        versionHash = $hash
        groups      = [string[]]@($sortedGroups)
        tree        = $json
        entries     = $entries.ToArray()
        stats       = [pscustomobject]$st
        # Tells the UI whether target validation ran against the live prefab mod or
        # against the persisted catalog snapshot (prefab mod not configured).
        modIndexSource = $effective.Source
        modIndexLive   = $effective.Live
    }
}

# ------------------------------------------------------------------ remap table writes
function Escape-JsonString([string]$str) {
    if ($null -eq $str) { return '""' }
    $sb = [System.Text.StringBuilder]::new()
    $chars = $str.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        switch ($c) {
            '"'  { [void]$sb.Append('\"'); break }
            '\' { [void]$sb.Append('\\'); break }
            "`r" { [void]$sb.Append('\r'); break }
            "`n" { [void]$sb.Append('\n'); break }
            "`t" { [void]$sb.Append('\t'); break }
            "`b" { [void]$sb.Append('\b'); break }
            "`f" { [void]$sb.Append('\f'); break }
            default {
                $code = [int]$c
                if ($code -lt 32) {
                    [void]$sb.Append([string]::Format('\u{0:x4}', $code))
                } else {
                    [void]$sb.Append($c)
                }
            }
        }
    }
    return '"' + $sb.ToString() + '"'
}

function Format-RemapJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputObject,
        [int]$Indent = 4
    )

    $sb = [System.Text.StringBuilder]::new()

    function Serialize-Node($node, [int]$depth) {
        $indentStr = ' ' * ($depth * $Indent)
        $nextIndentStr = ' ' * (($depth + 1) * $Indent)

        if ($null -eq $node) {
            [void]$sb.Append("null")
            return
        }

        if ($node -is [System.Collections.IDictionary] -or $node -is [System.Management.Automation.PSCustomObject]) {
            $props = @()
            if ($node -is [System.Collections.IDictionary]) {
                foreach ($k in $node.Keys) {
                    $props += [pscustomobject]@{ Name = [string]$k; Value = $node[$k] }
                }
            } else {
                foreach ($p in $node.PSObject.Properties) {
                    $props += [pscustomobject]@{ Name = [string]$p.Name; Value = $p.Value }
                }
            }

            if ($props.Count -eq 0) {
                [void]$sb.Append("{}")
                return
            }

            $orderedProps = @()
            if ($depth -eq 0) {
                $meta = $props | Where-Object { $_.Name -eq '_meta' }
                $nonMeta = $props | Where-Object { $_.Name -ne '_meta' }
                if ($meta) { $orderedProps += $meta }
                $groups = $nonMeta | Where-Object { $_.Name -ne '_Unresolved_Pending' }
                $orderedProps += $groups
                $pending = $nonMeta | Where-Object { $_.Name -eq '_Unresolved_Pending' }
                if ($pending) { $orderedProps += $pending }
            } else {
                $metaProps = @($props | Where-Object { $_.Name -like '_*' } | Sort-Object Name)
                $leafProps = @($props | Where-Object { $_.Name -notlike '_*' -and ($_.Value -is [string] -or $null -eq $_.Value -or $_.Value.GetType().IsPrimitive) } | Sort-Object Name)
                $subGroups  = @($props | Where-Object { $_.Name -notlike '_*' -and ($_.Value -isnot [string] -and $null -ne $_.Value -and -not $_.Value.GetType().IsPrimitive) } | Sort-Object Name)
                $orderedProps = $metaProps + $leafProps + $subGroups
            }

            [void]$sb.AppendLine("{")
            for ($i = 0; $i -lt $orderedProps.Count; $i++) {
                $p = $orderedProps[$i]
                $isLast = ($i -eq ($orderedProps.Count - 1))
                $keyEscaped = Escape-JsonString $p.Name
                [void]$sb.Append($nextIndentStr)
                [void]$sb.Append($keyEscaped)
                [void]$sb.Append(": ")
                Serialize-Node $p.Value ($depth + 1)
                if (-not $isLast) {
                    [void]$sb.AppendLine(",")
                } else {
                    [void]$sb.AppendLine()
                }
            }
            [void]$sb.Append($indentStr)
            [void]$sb.Append("}")
            return
        }

        if ($node -is [string]) {
            [void]$sb.Append((Escape-JsonString $node))
            return
        }

        if ($node -is [bool]) {
            [void]$sb.Append($(if ($node) { "true" } else { "false" }))
            return
        }

        if ($node.GetType().IsPrimitive) {
            [void]$sb.Append($node.ToString())
            return
        }

        if ($node -is [System.Collections.IEnumerable]) {
            $items = @($node)
            if ($items.Count -eq 0) {
                [void]$sb.Append("[]")
                return
            }
            [void]$sb.AppendLine("[")
            for ($i = 0; $i -lt $items.Count; $i++) {
                $isLast = ($i -eq ($items.Count - 1))
                [void]$sb.Append($nextIndentStr)
                Serialize-Node $items[$i] ($depth + 1)
                if (-not $isLast) {
                    [void]$sb.AppendLine(",")
                } else {
                    [void]$sb.AppendLine()
                }
            }
            [void]$sb.Append($indentStr)
            [void]$sb.Append("]")
            return
        }

        [void]$sb.Append((Escape-JsonString ($node.ToString())))
    }

    Serialize-Node $InputObject 0
    return $sb.ToString()
}

function Backup-RemapTable([string]$Path = $script:RMC.RemapTable) {
    if (Test-Path -LiteralPath $Path) {
        $bak = "$Path.bak"
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $bakTs = "$Path.bak.$ts"
        Copy-Item -LiteralPath $Path -Destination $bakTs -Force
        return $bakTs
    }
    return $null
}

# Insert key:value entries into a named top-level group (creating it if missing).
# Used for both stubs (value '') and resolved mappings (value = new ref).
function Get-RemapLeaves($Root, [string]$Key) {
    $found = New-Object System.Collections.Generic.List[object]
    $walk = {
        param($node, [string[]]$trail)
        if ($node -isnot [System.Management.Automation.PSCustomObject]) { return }
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -match $script:RefShape -and $p.Value -is [string]) {
                if (-not $Key -or $p.Name -eq $Key) {
                    $found.Add([pscustomobject]@{ Parent=$node; Trail=[string[]]@($trail); Property=$p })
                }
            } elseif ($p.Value -is [System.Management.Automation.PSCustomObject]) {
                & $walk $p.Value ([string[]]@($trail + @($p.Name)))
            }
        }
    }
    & $walk $Root ([string[]]@())
    return ,($found.ToArray())
}

function Resolve-RemapGroup($Root, $GroupSpec, [bool]$Create = $true) {
    if ($Root -isnot [System.Management.Automation.PSCustomObject]) { throw 'The remap table root must be an object.' }
    if ($GroupSpec -is [string]) {
        $parts = @($GroupSpec.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } elseif ($null -ne $GroupSpec -and $GroupSpec -is [System.Collections.IEnumerable]) {
        $parts = @($GroupSpec)
        foreach ($part in $parts) {
            if ($part -isnot [string] -or [string]::IsNullOrWhiteSpace($part)) { throw 'Group paths must contain nonempty string segments.' }
        }
    } else { throw 'A group must be a string path or an array of exact segments.' }
    $current = $Root
    foreach ($part in $parts) {
        $property = $current.PSObject.Properties[[string]$part]
        if (-not $property) {
            if (-not $Create) { return $null }
            $current | Add-Member -NotePropertyName ([string]$part) -NotePropertyValue ([pscustomobject]@{})
            $property = $current.PSObject.Properties[[string]$part]
        }
        if ($property.Value -isnot [System.Management.Automation.PSCustomObject]) { throw "Group segment is not an object: $part" }
        $current = $property.Value
    }
    return $current
}

function Get-RemapOperationSource($Root, $Operation) {
    $key = [string]$Operation.oldRef
    if ($key -notmatch $script:RefShape) { throw "Invalid oldRef: $key" }
    $scope = $Operation.PSObject.Properties['groupPath']
    if ($scope) {
        if ($null -eq $scope.Value -or $scope.Value -is [string] -or $scope.Value -isnot [System.Collections.IEnumerable]) {
            throw 'groupPath must be an array of exact string segments; [] addresses the root.'
        }
        $parent = Resolve-RemapGroup $Root $scope.Value $false
        if (-not $parent -or -not $parent.PSObject.Properties[$key] -or $parent.PSObject.Properties[$key].Value -isnot [string]) {
            throw "Scoped remap entry not found: $key"
        }
        return [pscustomobject]@{ Parent=$parent; Property=$parent.PSObject.Properties[$key] }
    }
    $matches = Get-RemapLeaves $Root $key
    if ($matches.Count -gt 1) { throw "Ambiguous remap entry; specify groupPath: $key" }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-RemapDestinationSpec($Operation, [string]$Property = 'group') {
    $p = $Operation.PSObject.Properties[$Property]
    if (-not $p -or $null -eq $p.Value -or ($p.Value -is [string] -and [string]::IsNullOrWhiteSpace($p.Value))) {
        return '_Unresolved_Pending'
    }
    return ,$p.Value
}

function Get-RemapGroupPath([string]$Ref) {
    $norm = ($Ref -replace '^\{[0-9A-Fa-f]{16}\}', '') -replace '\\', '/'
    $parts = @($norm.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -lt 2 -or $parts[0] -ne 'Prefabs') {
        return @('_Unresolved_Pending', 'Other')
    }
    $category = $parts[1]
    $rest = if ($parts.Count -gt 2) { @($parts[2..($parts.Count - 1)]) } else { @() }
    if ($rest.Count -gt 2 -and $rest[0] -eq 'Factions') {
        return @('_Unresolved_Pending', $category, $rest[0]) + @($rest[1..($rest.Count - 2)])
    }
    if ($rest.Count -gt 1) {
        return @('_Unresolved_Pending', $category) + @($rest[0..($rest.Count - 2)])
    }
    return @('_Unresolved_Pending', $category)
}

function Set-RemapEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Entries,
        [string]$Path = $script:RMC.RemapTable,
        [string]$Group = '_Unresolved_Pending',
        [hashtable]$EntryGroups = @{}
    )
    if ($Entries.Count -eq 0) { return [pscustomobject]@{ Added=0; Updated=0 } }
    $version = Get-RemapFileHash $Path
    $root = Read-Text $Path | ConvertFrom-Json
    $added = 0; $updated = 0
    $operations = New-Object System.Collections.Generic.List[object]
    foreach ($key in $Entries.Keys) {
        $matches = Get-RemapLeaves $root $key
        if ($matches.Count -gt 1) { throw "Ambiguous remap entry; use scoped operations: $key" }
        if ($matches.Count -eq 1) { $updated++ } else { $added++ }
        $targetGroup = if ($EntryGroups.ContainsKey($key)) { $EntryGroups[$key] } else { $Group }
        $operations.Add([pscustomobject]@{ op='set'; oldRef=$key; newRef=[string]$Entries[$key]; group=$targetGroup })
    }
    Save-RemapOperations -Operations $operations.ToArray() -ExpectedVersionHash $version -Path $Path | Out-Null
    return [pscustomobject]@{ Added=$added; Updated=$updated }
}

function Save-RemapOperations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations,
        [string]$ExpectedVersionHash,
        [string]$Path = $script:RMC.RemapTable
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Таблица ремапа не найдена по пути: $Path" }
    $currentHash = Get-RemapFileHash $Path
    if ($ExpectedVersionHash -and $currentHash -and $ExpectedVersionHash -ne $currentHash) {
        throw "Конфликт версий: файл на диске был изменён другим процессом (актуальный хеш $currentHash, ожидался $ExpectedVersionHash). Обновите страницу."
    }
    $root = Read-Text $Path | ConvertFrom-Json
    if ($root -isnot [System.Management.Automation.PSCustomObject]) { throw 'The remap table root must be an object.' }
    $applied = 0
    foreach ($op in $Operations) {
        $type = ([string]$op.op).ToLowerInvariant()
        switch ($type) {
            'set' {
                $leaf = Get-RemapOperationSource $root $op
                if ($leaf) { $leaf.Property.Value = [string]$op.newRef }
                else {
                    $groupSpec = Get-RemapDestinationSpec $op
                    $target = Resolve-RemapGroup $root $groupSpec $true
                    if ($target.PSObject.Properties[[string]$op.oldRef]) { throw "Remap key already exists: $($op.oldRef)" }
                    $target | Add-Member -NotePropertyName ([string]$op.oldRef) -NotePropertyValue ([string]$op.newRef)
                }
                $applied++
            }
            'add' {
                if ([string]$op.oldRef -notmatch $script:RefShape) { throw "Invalid oldRef: $($op.oldRef)" }
                $target = Resolve-RemapGroup $root (Get-RemapDestinationSpec $op) $true
                if ($target.PSObject.Properties[[string]$op.oldRef]) { throw "Remap key already exists: $($op.oldRef)" }
                $target | Add-Member -NotePropertyName ([string]$op.oldRef) -NotePropertyValue ([string]$op.newRef)
                $applied++
            }
            'delete' {
                $leaf = Get-RemapOperationSource $root $op
                if ($leaf) { $leaf.Parent.PSObject.Properties.Remove([string]$op.oldRef); $applied++ }
            }
            'move' {
                $leaf = Get-RemapOperationSource $root $op
                if ($leaf) {
                    $target = Resolve-RemapGroup $root (Get-RemapDestinationSpec $op 'targetGroup') $true
                    if ([object]::ReferenceEquals($target, $leaf.Parent)) { $applied++; break }
                    if ($target.PSObject.Properties[[string]$op.oldRef]) { throw "Move destination already contains the key: $($op.oldRef)" }
                    $value = $leaf.Property.Value
                    $target | Add-Member -NotePropertyName ([string]$op.oldRef) -NotePropertyValue $value
                    $leaf.Parent.PSObject.Properties.Remove([string]$op.oldRef)
                    $applied++
                }
            }
            'rename' {
                $leaf = Get-RemapOperationSource $root $op
                if ($leaf) {
                    $newKey = [string]$op.newOldRef
                    if ($newKey -notmatch $script:RefShape) { throw "Invalid newOldRef: $newKey" }
                    $collision = $leaf.Parent.PSObject.Properties[$newKey]
                    if ($collision -and $newKey -ne [string]$op.oldRef) { throw "Rename destination already contains the key: $newKey" }
                    $value = if ($op.PSObject.Properties['newRef']) { [string]$op.newRef } else { $leaf.Property.Value }
                    $leaf.Parent.PSObject.Properties.Remove([string]$op.oldRef)
                    $leaf.Parent | Add-Member -NotePropertyName $newKey -NotePropertyValue $value
                    $applied++
                }
            }
            'meta' {
                if (-not $root.PSObject.Properties['_meta']) {
                    $root | Add-Member -NotePropertyName '_meta' -NotePropertyValue ([pscustomobject]@{})
                }
                if ($root._meta -isnot [System.Management.Automation.PSCustomObject]) { throw '_meta must be an object.' }
                foreach ($name in @('description','status')) {
                    if ($null -ne $op.$name) {
                        if ($root._meta.PSObject.Properties[$name]) { $root._meta.PSObject.Properties[$name].Value = [string]$op.$name }
                        else { $root._meta | Add-Member -NotePropertyName $name -NotePropertyValue ([string]$op.$name) }
                    }
                }
                $applied++
            }
            'note' {
                $groupSpec = [string[]]@()
                if ($op.PSObject.Properties['group']) { $groupSpec = $op.group }
                $group = Resolve-RemapGroup $root $groupSpec $true
                if ([string]::IsNullOrWhiteSpace([string]$op.note)) { $group.PSObject.Properties.Remove('_note') }
                elseif ($group.PSObject.Properties['_note']) { $group._note = [string]$op.note }
                else { $group | Add-Member -NotePropertyName '_note' -NotePropertyValue ([string]$op.note) }
                $applied++
            }
            default { throw "Неизвестная операция: $type" }
        }
    }
    $formatted = Format-RemapJson $root
    $null = $formatted | ConvertFrom-Json
    $backup = Backup-RemapTable $Path
    Write-Text $Path $formatted
    return [pscustomobject]@{ ok=$true; applied=$applied; newHash=(Get-RemapFileHash $Path); backupFile=$backup }
}
