$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$decision = '{"permissionDecision":"deny","permissionDecisionReason":"CLI_GUARD_FAILURE"}'
$process = $null

try {
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $payload = [Console]::In.ReadToEnd()
    if ($payload.Length -gt 1048576) {
        throw 'INPUT_LIMIT'
    }
    $root = Split-Path -Parent $PSScriptRoot
    $engine = Join-Path $root 'tools\privacy_guard.py'
    $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $python
    $start.Arguments = '-I "' + $engine + '" hook'
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw 'LAUNCH_FAILED'
    }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    # Keep the engine deadline below the CLI's fail-open hook timeout.
    $write = $process.StandardInput.WriteAsync($payload)
    if (-not $write.Wait(3000)) {
        throw 'INPUT_TIMEOUT'
    }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(15000)) {
        throw 'ENGINE_TIMEOUT'
    }
    if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000) -or $process.ExitCode -ne 0) {
        throw 'ENGINE_FAILED'
    }
    if ($stdout.Result.Length -gt 4096) {
        throw 'OUTPUT_LIMIT'
    }
    $raw = $stdout.Result.Trim()
    if (-not $raw.StartsWith('{') -or -not $raw.EndsWith('}')) {
        throw 'INVALID_OUTPUT'
    }
    $result = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    # Only exact allowlisted reasons may leave the launcher, never raw diagnostics.
    if ($result -is [PSCustomObject] -and @($result.PSObject.Properties).Count -eq 0) {
        $decision = '{}'
    }
    elseif ($result -isnot [System.Array] -and $result.permissionDecision -ceq 'deny') {
        $decision = '{"permissionDecision":"deny","permissionDecisionReason":"CLI_POLICY_DENIED"}'
        $safeReasons = @(
            'DUPLICATE_KEY', 'INVALID_JSON', 'INPUT_LIMIT', 'INVALID_VALUE',
            'INVALID_FIELDS', 'LINK_PATH', 'INVALID_PROJECT', 'INVALID_PATH',
            'CONTROL_PATH', 'NOT_REGULAR_FILE', 'OUTSIDE_PROJECT', 'FILE_CHANGED',
            'INVALID_VERSION', 'INVALID_POLICY', 'POLICY_MISSING', 'DUPLICATE_PATH',
            'INVALID_CATEGORY', 'INVALID_DIGEST', 'INVALID_TASK', 'TASK_NOT_REVIEWED',
            'STALE_DIGEST', 'UNCLASSIFIED_FILE', 'SEARCH_SCOPE_LIMIT',
            'HISTORY_SCOPE_REQUIRED', 'TOOL_DENIED', 'INVALID_ARGUMENTS',
            'SHELL_DENIED', 'POLICY_ERROR'
        )
        $reason = $result.permissionDecisionReason
        if ($reason -is [string] -and $safeReasons -ccontains $reason) {
            if ($reason -ceq 'POLICY_MISSING') {
                $reason = 'POLICY_MISSING: No project policy in the current working directory. Start a fresh CLI session from the exact initialized project root, or have a human initialize the intended root. Parent policies are not inherited.'
            }
            elseif ($reason -ceq 'INVALID_PROJECT') {
                $reason = 'INVALID_PROJECT: Invalid working directory. Start a fresh CLI session from the exact existing absolute project root; relative paths and filesystem aliases are not supported.'
            }
            elseif ($reason -ceq 'HISTORY_SCOPE_REQUIRED') {
                $reason = 'CLI_HISTORY_SCOPE_REQUIRED: Use source=local. Supported SQL: SELECT id, summary, updated_at FROM sessions WHERE cwd=''<exact project root>'' ORDER BY updated_at DESC LIMIT 20; or SELECT t.session_id, t.user_message, t.assistant_response FROM turns AS t JOIN sessions AS s ON t.session_id=s.id WHERE s.cwd=''<exact project root>'' ORDER BY t.timestamp DESC LIMIT 50. Substitute the current project root and escape SQL quotes. No unscoped queries.'
            }
            $decision = ConvertTo-Json -Compress -InputObject @{
                permissionDecision = 'deny'
                permissionDecisionReason = $reason
            }
        }
    }
}
catch {
    $decision = '{"permissionDecision":"deny","permissionDecisionReason":"CLI_GUARD_FAILURE"}'
}
finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
            }
        }
        catch {}
        $process.Dispose()
    }
}
[Console]::Out.WriteLine($decision)
exit 0
