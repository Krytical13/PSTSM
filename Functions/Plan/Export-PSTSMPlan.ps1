# SPDX-License-Identifier: GPL-3.0-or-later
function Export-PSTSMPlan {
    <#
    .SYNOPSIS
        Writes a task plan to JSON so it can be reviewed, committed, and applied elsewhere.
    .DESCRIPTION
        The plan is deliberately plain data, which makes this the config-as-code path: build a
        task once in the UI, export it, commit it, then apply it non-interactively to every
        server that needs it.

        Nothing secret is written. A Password logon type records only the account name; the
        password itself lives in Task Scheduler's own credential store on each machine and must
        be supplied again at registration.
    .PARAMETER Plan
        A task plan.
    .PARAMETER Path
        Destination .json file.
    .PARAMETER PassThru
        Emit the file object.
    .OUTPUTS
        [System.IO.FileInfo] when -PassThru is used.
    .EXAMPLE
        Export-PSTSMPlan -Plan $plan -Path .\Plans\NightlyReport.task.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Plan,

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$PassThru
    )

    process {
        # ArgumentString is a computed convenience; keep it in the file as documentation of
        # what this plan produces, but it is never read back on import.
        $export = [ordered]@{
            SchemaVersion    = $Plan.SchemaVersion
            ExportedBy       = 'PSTSM'
            ExportedOn       = (Get-Date).ToString('o')

            TaskName         = $Plan.TaskName
            TaskPath         = $Plan.TaskPath
            Description      = $Plan.Description

            ScriptPath       = $Plan.ScriptPath
            EngineId         = $Plan.EngineId
            EnginePath       = $Plan.EnginePath
            WorkingDirectory = $Plan.WorkingDirectory

            Parameters       = $Plan.Parameters
            ExtraArguments   = $Plan.ExtraArguments

            NoProfile        = $Plan.NoProfile
            NonInteractive   = $Plan.NonInteractive
            ExecutionPolicy  = $Plan.ExecutionPolicy
            WindowStyle      = $Plan.WindowStyle

            Triggers         = @($Plan.Triggers)
            Principal        = $Plan.Principal
            Settings         = $Plan.Settings
            Logging          = $Plan.Logging

            RenderedCommand  = "$($Plan.EnginePath) $($Plan.ArgumentString)"
        }

        $json = $export | ConvertTo-Json -Depth 10

        if ($PSCmdlet.ShouldProcess($Path, 'Write task plan')) {
            # Resolve against the PowerShell location, not the process working directory. The
            # cmdlets here (Split-Path, Test-Path, New-Item) are provider-aware and [System.IO.File]
            # is not - it uses [Environment]::CurrentDirectory, which in a PowerShell session is
            # wherever the process started and is frequently not where the user thinks they are.
            # A relative path like the .\Plans\... in this function's own example therefore wrote
            # somewhere else, or threw because the directory it had just created was not there.
            # GetUnresolvedProviderPathFromPSPath works for a file that does not exist yet.
            $full = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
            $dir = Split-Path -Path $full -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($full, $json, $utf8Bom)
        }

        if ($PassThru) { Get-Item -LiteralPath $Path }
    }
}

function Import-PSTSMPlan {
    <#
    .SYNOPSIS
        Reads a task plan back from JSON into the object shape the rest of the module expects.
    .DESCRIPTION
        ConvertFrom-Json produces PSCustomObjects, but the plan's Parameters, Settings,
        Principal and Logging blocks are dictionaries that downstream code enumerates by key.
        This converts them back so an imported plan behaves exactly like one from
        New-PSTSMPlan - including the computed ArgumentString.

        EnginePath is re-resolved against the local machine by default, because a plan built on
        a box with PowerShell 7.4 must still register on one with 7.2.
    .PARAMETER Path
        The .json file to read.
    .PARAMETER KeepEnginePath
        Trust the EnginePath recorded in the file instead of re-resolving it locally.
    .OUTPUTS
        [pscustomobject] PSTSM.TaskPlan
    .EXAMPLE
        Import-PSTSMPlan -Path .\Plans\NightlyReport.task.json | Register-PSTSMPlan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Path,

        [switch]$KeepEnginePath
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Plan file not found: $Path"
        }

        $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

        if ($raw.SchemaVersion -and [int]$raw.SchemaVersion -gt 1) {
            Write-Warning "Plan declares schema version $($raw.SchemaVersion); this module understands 1. Unknown fields will be ignored."
        }

        function ConvertTo-PSTSMOrderedDictionary($obj) {
            $d = [ordered]@{}
            if ($null -eq $obj) { return $d }
            foreach ($p in $obj.PSObject.Properties) { $d[$p.Name] = $p.Value }
            $d
        }

        $enginePath = $raw.EnginePath
        if (-not $KeepEnginePath) {
            $candidates = @(Get-PSTSMEngine -Id $raw.EngineId)
            $pick = @($candidates | Where-Object { $_.Bitness -eq 'x64' } | Select-Object -First 1)
            if (-not $pick) { $pick = @($candidates | Select-Object -First 1) }
            if ($pick) {
                if ($pick[0].Path -ne $raw.EnginePath) {
                    Write-Verbose "Re-resolved engine locally: $($raw.EnginePath) -> $($pick[0].Path)"
                }
                $enginePath = $pick[0].Path
            }
            else {
                Write-Warning "No '$($raw.EngineId)' engine found locally; keeping the recorded path '$($raw.EnginePath)'."
            }
        }

        # Triggers stay as PSCustomObjects - they are read by property, not by key.
        $triggers = @()
        foreach ($t in @($raw.Triggers)) {
            if ($null -eq $t) { continue }
            $t.PSObject.TypeNames.Insert(0, 'PSTSM.TriggerSpec')
            $triggers += $t
        }

        $plan = [PSCustomObject]@{
            PSTypeName       = 'PSTSM.TaskPlan'
            SchemaVersion    = if ($raw.SchemaVersion) { [int]$raw.SchemaVersion } else { 1 }

            TaskName         = $raw.TaskName
            TaskPath         = $raw.TaskPath
            Description      = $raw.Description

            ScriptPath       = $raw.ScriptPath
            EngineId         = $raw.EngineId
            EnginePath       = $enginePath
            WorkingDirectory = $raw.WorkingDirectory

            Parameters       = (ConvertTo-PSTSMOrderedDictionary $raw.Parameters)
            ExtraArguments   = $raw.ExtraArguments

            NoProfile        = [bool]$raw.NoProfile
            NonInteractive   = [bool]$raw.NonInteractive
            ExecutionPolicy  = $raw.ExecutionPolicy
            WindowStyle      = $raw.WindowStyle

            Triggers         = $triggers
            Principal        = (ConvertTo-PSTSMOrderedDictionary $raw.Principal)
            Settings         = (ConvertTo-PSTSMOrderedDictionary $raw.Settings)
            Logging          = (ConvertTo-PSTSMOrderedDictionary $raw.Logging)

            Source           = [ordered]@{
                EngineConfidence = 'Imported'
                EngineReason     = "imported from $Path"
                DerivedFrom      = $Path
            }
        }

        $plan | Add-Member -MemberType ScriptProperty -Name 'ArgumentString' -Value {
            ConvertTo-PSTSMArgument -ScriptPath $this.ScriptPath `
                -Parameters $this.Parameters `
                -ExtraArguments $this.ExtraArguments `
                -ExecutionPolicy $this.ExecutionPolicy `
                -NoProfile $this.NoProfile `
                -NonInteractive $this.NonInteractive `
                -WindowStyle $this.WindowStyle
        }

        $plan
    }
}
