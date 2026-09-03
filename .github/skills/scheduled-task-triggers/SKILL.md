---
name: scheduled-task-triggers
description: Build monthly, Patch Tuesday, and recurring scheduled task triggers under Windows PowerShell 5.1, where Register-ScheduledTask rejects the monthly CIM trigger classes. Use when editing Register-UpdaterScheduledTask, the -Schedule, -ScheduleDay or -ScheduleTime parameters, or any scheduled task registration in this repo.
---

# Scheduled task triggers

## The constraint

`Register-ScheduledTask -Trigger` rejects the client-only `MSFT_Task*Monthly*Trigger` CIM classes with
0x80070057 ("the parameter is incorrect") no matter which properties are set. There is no property
combination that makes it work, so do not spend a turn trying. Daily, weekly, and `-Once` with a
repetition interval are all fine through the CIM path.

## The workaround

Register with a **placeholder weekly trigger**, export the task's own XML, swap the calendar element,
then re-register with `-Xml`. Task Scheduler accepts a monthly calendar trigger through XML.

```powershell
$MonthsXml = '<Months><January /><February /><March /><April /><May /><June /><July /><August /><September /><October /><November /><December /></Months>'

# Placeholder. The day of week does not matter, it gets replaced.
$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $Start
$CalendarXml = "<ScheduleByMonth><DaysOfMonth><Day>$([int]$DayNumber)</Day></DaysOfMonth>$MonthsXml</ScheduleByMonth>"

Register-ScheduledTask @RegParams | Out-Null

if ($CalendarXml) {
    $TaskXml = (Export-ScheduledTask -TaskName $TaskName) -replace '(?s)<ScheduleByWeek>.*?</ScheduleByWeek>', $CalendarXml
    $XmlRegParams = @{ TaskName = $TaskName; Xml = $TaskXml; Force = $true; ErrorAction = 'Stop' }
    if ($TaskUsername) { $XmlRegParams['User'] = $TaskUsername }
    if ($TaskPassword) { $XmlRegParams['Password'] = $TaskPassword }
    Register-ScheduledTask @XmlRegParams | Out-Null
}
```

Points that are easy to get wrong:

- The regex needs `(?s)` because `Export-ScheduledTask` returns multi-line XML.
- Re-registering with `-Xml` drops the credential, so `User` and `Password` have to be passed again.
- `Force = $true` on both calls, otherwise the second registration fails on the existing task.
- Nothing else in the exported XML should be rewritten. Swap only the calendar element.

## Calendar elements

| Schedule | Element |
| --- | --- |
| Day N of every month | `<ScheduleByMonth><DaysOfMonth><Day>N</Day></DaysOfMonth>` + months |
| Nth weekday of every month | `<ScheduleByMonthDayOfWeek><Weeks><Week>N</Week></Weeks><DaysOfWeek><Tuesday /></DaysOfWeek>` + months |

The `<Months>` block must list all twelve elements explicitly. An empty or omitted `<Months>` produces a
task that never fires.

## Patch Tuesday

Updates publish at 10:30 Pacific on the second Tuesday. Two consequences the code already handles, so
preserve them:

- In time zones where 10:30 Pacific lands on the **next local day**, the target is Wednesday, and the
  Wednesday after the second Tuesday is not always in calendar week 2. Trigger weeks 2 **and** 3 and let
  the early run exit on the rebuild check. Narrowing this to week 3 alone skips months.
- When `-ScheduleTime` is earlier than the local equivalent of 10:30 Pacific, warn rather than refuse.
  The run is harmless, it just finds nothing new.

## Other 5.1 traps in this area

- `[enum]::TryParse([System.DayOfWeek], $str, $true, [ref]$out)` fails to bind. Use `[enum]::Parse`
  inside try/catch to convert a weekday name.
- The `string[]` overload of `[datetime]::TryParseExact` fails to bind. Regex-parse `HH:mm` by hand and
  range-check the hour and minute.
- Omitting the repetition duration on `-Once -RepetitionInterval` means repeat indefinitely, which is
  what an hourly schedule wants.

## Testing

`Import-Module ScheduledTasks` **before** defining stubs for `Register-ScheduledTask` or
`Export-ScheduledTask`, otherwise module auto-loading shadows the stubs and the real cmdlets run and
register a real task. Never register a real task without being asked.
