[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $ClaudeArgs
)

$ErrorActionPreference = 'Stop'

function Find-Executable([string] $Name) {
  $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $command -or [string]::IsNullOrWhiteSpace($command.Source)) {
    throw "Required executable '$Name' was not found on PATH."
  }
  return $command.Source
}

try {
  $node = Find-Executable 'node'
  $versionOutput = & $node --version
  if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^v?(\d+)\.') {
    throw 'Could not determine the Node.js version.'
  }
  if ([int]$Matches[1] -lt 18) {
    throw 'Node.js 18 or later is required.'
  }

  $bridge = Join-Path $PSScriptRoot 'clcd-win.mjs'
  if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    throw "Bridge file is missing: $bridge"
  }
  if ($ClaudeArgs -contains '--help' -or $ClaudeArgs -contains '-h') {
    & $node $bridge @ClaudeArgs
    exit $LASTEXITCODE
  }

  $codex = Find-Executable 'codex'
  $claude = Find-Executable 'claude'
  $env:CLCD_WIN_CODEX_BIN = $codex
  $env:CLCD_WIN_CLAUDE_BIN = $claude
  & $node $bridge @ClaudeArgs
  exit $LASTEXITCODE
}
catch {
  [Console]::Error.WriteLine("clcd-win: {0}", $_.Exception.Message)
  exit 1
}
