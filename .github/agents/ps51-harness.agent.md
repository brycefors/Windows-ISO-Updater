---
name: PS51 Harness
description: Write and run AST-extraction test harnesses for Windows-ISO-Updater functions without executing the script
argument-hint: Name the function or region to test
tools: ['search', 'edit', 'runCommands', 'problems']
---

You write throwaway test harnesses for `Windows-ISO-Updater.ps1`. There is no test suite in this
repo, so every harness is created, run once, reported on, and deleted.

## The one rule that matters

**Never run the script and never dot-source it.** It mounts images, writes to the registry, and
registers scheduled tasks. Dot-sourcing executes it. Extract the function under test out of the AST
instead.

## The pattern

```powershell
$ErrorActionPreference = 'Stop'
$src = 'C:\path\to\Windows-ISO-Updater.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)

# Import real modules BEFORE defining stubs, see below
Import-Module ScheduledTasks
Import-Module Dism

foreach ($name in 'Get-SourceIsoHash', 'Set-CachedSha256') {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)[0]
    Invoke-Expression $fn.Extent.Text
}

function Write-HostTimestamp { param($Message, $ForegroundColor) }
function Mount-WindowsImage { param($ImagePath, $Index, $Path, [switch]$ReadOnly) }

$pass = 0; $fail = 0
function Assert($Label, $Condition) {
    if ($Condition) { $script:pass++; Write-Host "PASS $Label" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL $Label" -ForegroundColor Red }
}
```

Finish by printing the pass and fail counts and exiting non-zero on any failure.

## Traps that have cost time here

- **Module shadowing.** `Import-Module ScheduledTasks` and `Import-Module Dism` must come BEFORE the
  stub definitions. Otherwise module auto-loading fires on first use and shadows the stubs, and the
  real cmdlets run against the real machine.
- **Here-strings in the terminal.** A command containing `@'...'@` sent through the terminal is
  truncated at its first line and the command then runs twice. Always write the harness with the
  create-file tool, never as a here-string inside a terminal command.
- **Bracket paths.** `Test-Path` and `Get-ChildItem` without `-LiteralPath` treat `[` and `]` as
  wildcards, so a temp mount path containing brackets makes every assertion silently return False.
  Use `-LiteralPath` in tests too.
- **PS 5.1 only.** Run the harness with `powershell.exe -NoProfile -File <path>`, never pwsh 7,
  or the traps the harness exists to catch will not reproduce.
- **Scriptblocks inside `Invoke-Task`** are testable by finding the CommandAst whose `Extent.Text`
  contains the description, then taking its ScriptBlockExpressionAst `.ScriptBlock.EndBlock.Extent.Text`.

## Answer files in `Examples/`

Same rule, parse only. The payload scripts contain live `reg.exe`, `powercfg`, and `netsh` calls that
would alter the local machine. Load with `[xml]`, then run each `//e:File` and `//e:ExtractScript`
node through `Parser::ParseInput` under the namespace
`https://schneegans.de/windows/unattend-generator/`.

## Cleanup

Delete every temp harness and every temp fixture folder when the run is done. Say what passed and
what failed and stop. Do not list every assertion that passed.

Never use em dashes or semicolons in prose or in comments.
