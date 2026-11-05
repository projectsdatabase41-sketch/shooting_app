<#
  tool/check.ps1 — проверка проекта одной командой.

  Что делает: pub get → flutter analyze → flutter test → (по флагу)
  flutter build web. Печатает короткий итог в консоль и складывает
  подробный отчёт в build/check-report.txt и build/check-report.json —
  их читает и человек, и агент, не разбирая километры вывода.

  Примеры:
    pwsh -File tool/check.ps1                # анализ + тесты
    pwsh -File tool/check.ps1 -BuildWeb      # плюс сборка веба
    pwsh -File tool/check.ps1 -Fast          # только анализатор
    pwsh -File tool/check.ps1 -NoTests       # без тестов (для быстрой правки)

  Код возврата: 0 — всё чисто, 1 — есть падения. Годится и для CI,
  и для «сломалось ли» внутри других скриптов.

  Почему не голый `flutter analyze` в консоли: вывод там длиной в
  сотни строк, а решения принимаются по трём числам (ошибки/тесты) и
  списку упавших тестов. Их и печатаем.

  Важно: flutter запускается через cmd.exe с перенаправлением в файл —
  так надёжно ловится весь вывод, включая stderr, и работает
  WaitForExit с таймаутом (иначе зависший `flutter` не убить).
#>
[CmdletBinding()]
param(
  [switch]$Fast,      # только анализатор
  [switch]$NoTests,   # без тестов
  [switch]$BuildWeb,  # плюс сборка веб-версии
  [switch]$NoPub,     # не запускать pub get
  [string]$Files      # только эти файлы в анализаторе: "lib\a.dart,test\b.dart"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $root 'build'
$logDir = Join-Path $buildDir 'check-logs'
New-Item -ItemType Directory -Force -Path $buildDir, $logDir | Out-Null

$flutter = (Get-Command flutter -ErrorAction Stop).Source
# Аналитика Flutter при первом запуске лезет в сеть и умеет висеть.
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'

$steps = [System.Collections.Generic.List[object]]::new()

function Invoke-Step {
  param(
    [string]$Name,
    [string]$Command,
    [int]$TimeoutMin = 15,
    [string]$LogName
  )
  $log = Join-Path $logDir $LogName
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # Аргументы уходят в cmd.exe как есть, поэтому своё имя файла — в
  # кавычках (в пути пользователя есть пробелы и кириллица). Команда —
  # без внешних кавычек: она и так целиком в аргументе /c.
  $q = { param($s) '"' + $s + '"' }
  $line = '/S /C "' + $Command + ' > ' + (& $q $log) + ' 2>&1"'
  $p = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList $line `
    -WorkingDirectory $root `
    -NoNewWindow -PassThru
  $finished = $p.WaitForExit($TimeoutMin * 60000)
  if (-not $finished) {
    try { $p.Kill($true) } catch { }
    try { $p.WaitForExit(5000) | Out-Null } catch { }
  }
  $sw.Stop()
  $step = [pscustomobject]@{
    name     = $Name
    code     = $(if ($finished) { $p.ExitCode } else { -1 })
    seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    timedOut = (-not $finished)
    log      = $log
  }
  $steps.Add($step)
  return $step
}

function Get-AnalyzeStats {
  param([string]$Log)
  $lines = @(Get-Content -LiteralPath $Log -ErrorAction SilentlyContinue)
  $text = $lines -join "`n"
  # Формат анализатора Dart: `error - <текст> - <файл>:<строка>:<кол> - <код>`
  # (не `error • …`: так пишет `dart analyze`, а `flutter analyze` — тире).
  return [pscustomobject]@{
    errors   = @($lines | Where-Object { $_ -match '^\s*error\s+[-•]' }).Count
    warnings = @($lines | Where-Object { $_ -match '^\s*warning\s+[-•]' }).Count
    infos    = @($lines | Where-Object { $_ -match '^\s*info\s+[-•]' }).Count
    clean    = [bool]($text -match 'No issues found')
  }
}

function Get-TestStats {
  param([string]$Log)
  $names = @{}
  $done = [System.Collections.Generic.List[object]]::new()
  $errors = [System.Collections.Generic.List[string]]::new()
  if (-not (Test-Path -LiteralPath $Log)) {
    return [pscustomobject]@{ total = 0; passed = 0; skipped = 0; failed = 0; names = @(); errors = @('лог тестов не создан') }
  }

  # Кодировка — явно UTF-8: без BOM .NET иначе читает как ANSI и ломает
  # кириллицу в именах тестов.
  $reader = [System.IO.StreamReader]::new($Log, [System.Text.UTF8Encoding]::new($false))
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      # JSON-строки идут вперемешку с обычным текстом компилятора —
      # берём только строки протокола.
      if (-not $line.StartsWith('{')) {
        # «Unhandled exception:» и крах компилятора печатаются до того,
        # как тест успел упасть, — иначе тесты «зависают» до таймаута.
        if ($line -match 'Unhandled exception|Crash when compiling') {
          if ($errors.Count -lt 10) { $errors.Add($line.Trim()) }
        }
        continue
      }
      try { $e = $line | ConvertFrom-Json } catch { continue }
      switch ($e.type) {
        'testStart' { $names["$($e.test.id)"] = $e.test.name }
        'error' {
          if ($errors.Count -lt 10) {
            $msg = "$($e.error)".Trim()
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '…' }
            $errors.Add($msg)
          }
        }
        'testDone' {
          if (-not $e.hidden) {
            $done.Add([pscustomobject]@{
              name    = $names["$($e.testID)"]
              result  = "$($e.result)"
              skipped = [bool]$e.skipped
            })
          }
        }
      }
    }
  } finally { $reader.Dispose() }

  $failed = @($done | Where-Object { $_.result -ne 'success' })
  return [pscustomobject]@{
    total   = $done.Count
    passed  = @($done | Where-Object { $_.result -eq 'success' -and -not $_.skipped }).Count
    skipped = @($done | Where-Object { $_.skipped }).Count
    failed  = $failed.Count
    names   = @($failed | Select-Object -First 15 | ForEach-Object { $_.name })
    errors  = @($errors)
  }
}

$swTotal = [Diagnostics.Stopwatch]::StartNew()

# 1. Зависимости. Оффлайн по умолчанию не форсируем: кэш и так есть,
#    а сеть нужна, если поменялся pubspec.
if (-not $NoPub) {
  Invoke-Step -Name 'pub get' -Command "`"$flutter`" --no-version-check pub get" -TimeoutMin 10 -LogName 'pub.txt' | Out-Null
}

# 2. Анализатор. --no-fatal-infos — как в CI: подсказки не валят сборку,
#    ошибки и предупреждения — валят.
$analyzeCmd = "`"$flutter`" --no-version-check analyze --no-fatal-infos"
if ($Files) {
  # Точечная проверка пары файлов — секунды вместо минут.
  $list = ($Files -split '[,\s]+' | Where-Object { $_ }) | ForEach-Object { '"' + $_ + '"' }
  $analyzeCmd += ' ' + ($list -join ' ')
}
$analyze = Invoke-Step -Name 'analyze' -Command $analyzeCmd -TimeoutMin 20 -LogName 'analyze.txt'
$analyzeStats = Get-AnalyzeStats -Log $analyze.log

# 3. Тесты.
$testStats = $null
if (-not $Fast -and -not $NoTests) {
  $test = Invoke-Step -Name 'test' -Command "`"$flutter`" --no-version-check test --reporter json" -TimeoutMin 40 -LogName 'test.jsonl'
  $testStats = Get-TestStats -Log $test.log
  # Краш компилятора не даёт тестам завершиться — процесс висит до
  # таймаута и режется. Флагуем это отдельно от просто упавших тестов.
  if ($test.timedOut -and $testStats.errors.Count -gt 0) {
    $testStats | Add-Member -NotePropertyName crashed -NotePropertyValue $true -Force
  }
}

# 4. Сборка веба — только по флагу: она долгая, и обычно не нужна.
if ($BuildWeb) {
  Invoke-Step -Name 'build web' -Command "`"$flutter`" --no-version-check build web --release --no-web-resources-cdn --pwa-strategy=none" -TimeoutMin 30 -LogName 'build-web.txt' | Out-Null
}

$swTotal.Stop()

# --- итог для человека ---
function Fmt-Sec([double]$s) { if ($s -ge 60) { "{0:N1} мин" -f ($s / 60) } else { "{0:N0} c" -f $s } }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("=== Проверка shooting_app ===")
$i = 0
foreach ($s in $steps) {
  $i++
  $label = switch ($s.name) {
    'pub get'   { 'зависимости' }
    'analyze'   { 'анализатор' }
    'test'      { 'тесты' }
    'build web' { 'сборка веба' }
    default     { $s.name }
  }
  if ($s.timedOut) {
    $status = 'ТАЙМАУТ'
  } elseif ($s.code -eq 0) {
    $status = 'ok     '
  } else {
    $status = 'ПАДЕНИЕ'
  }

  $details = ''
  if ($s.name -eq 'analyze') {
    $details = "ошибок $($analyzeStats.errors), предупреждений $($analyzeStats.warnings), подсказок $($analyzeStats.infos)"
  } elseif ($s.name -eq 'test' -and $testStats) {
    $details = "прошло $($testStats.passed) из $($testStats.total), упало $($testStats.failed), пропущено $($testStats.skipped)"
  }

  $lines.Add(("{0}. {1,-12} {2}  {3,8}  {4}" -f $i, $label, $status, (Fmt-Sec $s.seconds), $details).TrimEnd())
}

$broken = @($steps | Where-Object { $_.code -ne 0 }).Count
$lines.Add('')
if ($broken -eq 0) {
  $lines.Add("ИТОГ: чисто. Всего $(Fmt-Sec $swTotal.Elapsed.TotalSeconds).")
} else {
  $lines.Add("ИТОГ: проблемных шагов $broken из $($steps.Count). Разбор — ниже.")
}

if ($testStats -and $testStats.PSObject.Properties['crashed'] -and $testStats.crashed) {
  $lines.Add('')
  $lines.Add('ВНИМАНИЕ: компилятор Dart упал — часть тестов не дошла до запуска.')
  $lines.Add('  Сначала лечится синтаксис по списку анализатора ниже, потом тесты.')
}

if ($testStats -and $testStats.failed -gt 0) {
  $lines.Add('')
  $lines.Add('Упавшие тесты:')
  foreach ($n in $testStats.names) { $lines.Add("  - $n") }
  if ($testStats.failed -gt $testStats.names.Count) {
    $lines.Add("  … и ещё $($testStats.failed - $testStats.names.Count)")
  }
}

if ($testStats -and $testStats.errors.Count -gt 0) {
  $lines.Add('')
  $lines.Add('Ошибки протокола тестов:')
  foreach ($e in $testStats.errors) { $lines.Add("  ! " + ($e -replace "`r?`n", ' ')) }
}

if ($analyzeStats.errors -gt 0 -or $analyzeStats.warnings -gt 0) {
  $lines.Add('')
  # Сводка «где сломалось»: файл и число замечаний, по убыванию.
  # Формат строки: `error - текст - <файл>:<строка>:<кол> - <код>`.
  $lines.Add('Файлы с ошибками и предупреждениями:')
  Get-Content -LiteralPath $analyze.log |
    Where-Object { $_ -match '^\s*(error|warning)\s+[-•]' } |
    ForEach-Object {
      $parts = $_ -split '\s+-\s+'
      if ($parts.Count -ge 3) { $parts[2] -replace ':\d+:\d+$', '' } else { '?' }
    } |
    Group-Object |
    Sort-Object Count -Descending |
    Select-Object -First 12 |
    ForEach-Object { $lines.Add(("  {0,3}  {1}" -f $_.Count, $_.Name)) }

  $lines.Add('')
  $lines.Add('Первые ошибки анализатора:')
  Get-Content -LiteralPath $analyze.log |
    Where-Object { $_ -match '^\s*(error|warning)\s+[-•]' } |
    Select-Object -First 12 |
    ForEach-Object { $lines.Add('  ' + $_.Trim()) }
}

$lines.Add('')
$lines.Add("Полные логи: $logDir")

# Отчёт: txt для глаз, json для разбора кодом (и для меня).
$reportTxt = Join-Path $buildDir 'check-report.txt'
$reportJson = Join-Path $buildDir 'check-report.json'
$lines -join "`n" | Set-Content -LiteralPath $reportTxt -Encoding utf8
[pscustomobject]@{
  generatedAt = (Get-Date).ToString('s')
  totalSeconds = [math]::Round($swTotal.Elapsed.TotalSeconds, 1)
  brokenSteps = $broken
  steps       = $steps
  analyze     = $analyzeStats
  tests       = $testStats
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportJson -Encoding utf8

$lines | ForEach-Object { Write-Host $_ }

exit $(if ($broken -eq 0) { 0 } else { 1 })
