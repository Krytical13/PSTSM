# SPDX-License-Identifier: GPL-3.0-or-later
function Get-PSTSMTaskOrigin {
    <#
    .SYNOPSIS
        Works out who put a scheduled task on the machine: Windows, an installed application,
        a person, or this tool.
    .DESCRIPTION
        Task Scheduler shows several hundred tasks and gives no hint which of them anyone at
        this organisation actually created. That is the question an admin is really asking when
        they open the list, and it is answerable from metadata the task already carries.

        Signals, in the order they are applied:

          PSTSM    the action points at a wrapper this tool generated
          Windows  the task lives under \Microsoft\, or its Author is a resource string of the
                   form $(@%SystemRoot%\system32\thing.dll,-601) - only OS components register
                   an Author that has to be looked up in a DLL
          Person   the Author is DOMAIN\name for a real account. Machine accounts (trailing $)
                   and NT AUTHORITY\* are excluded: those are installers running as the
                   computer or as SYSTEM, not somebody sitting at a keyboard
          App      the Author is a plain vendor string - "NVIDIA Corporation", "ASUSTek",
                   "Zoom Communications, Inc." - or a Source is recorded
          Unknown  no Author at all, which is common for tasks written directly as XML

        This is a classification of evidence, not a security boundary: Author is a free-text
        field, so anything that wants to look like Windows can. It is for orientation, and the
        detail string always names what the guess was based on.
    .PARAMETER Task
        A scheduled task from Get-ScheduledTask.
    .PARAMETER IsManagedByTool
        Whether the action resolves to a PSTSM-generated wrapper. Passed in because
        Get-PSTSMInventory has already parsed the action and there is no point doing it twice.
    .OUTPUTS
        [pscustomobject] Origin, Detail
    .EXAMPLE
        Get-ScheduledTask | ForEach-Object { Get-PSTSMTaskOrigin -Task $_ }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Task,

        [bool]$IsManagedByTool
    )

    $author = [string]$Task.Author
    $source = [string]$Task.Source

    if ($IsManagedByTool) {
        return [PSCustomObject]@{ Origin = 'PSTSM'; Detail = 'Created by this tool - the action runs a PSTSM wrapper.' }
    }

    if ($Task.TaskPath -like '\Microsoft\*') {
        return [PSCustomObject]@{ Origin = 'Windows'; Detail = 'Lives under \Microsoft\, the folder the OS uses for its own tasks.' }
    }

    # Only OS components use an indirect, localisable Author.
    if ($author -match '^\$\(@') {
        return [PSCustomObject]@{ Origin = 'Windows'; Detail = "Author is a resource string: $author" }
    }

    if ($author -match '^[^\\]+\\[^\\]+$') {
        $leaf = ($author -split '\\')[-1]
        if ($author -match '^(?i)NT AUTHORITY\\') {
            return [PSCustomObject]@{ Origin = 'App'; Detail = "Registered by something running as $author - an installer or service, not a person." }
        }
        if ($leaf -match '\$$') {
            return [PSCustomObject]@{ Origin = 'App'; Detail = "Registered by the computer account $author - an installer running as the machine." }
        }
        return [PSCustomObject]@{ Origin = 'Person'; Detail = "Created by $author." }
    }

    if ($author) {
        return [PSCustomObject]@{ Origin = 'App'; Detail = "Registered by $author." }
    }
    if ($source) {
        return [PSCustomObject]@{ Origin = 'App'; Detail = "Source: $source" }
    }

    [PSCustomObject]@{ Origin = 'Unknown'; Detail = 'No author recorded, which is usual for a task written straight to XML.' }
}
