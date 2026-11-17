# Stops every running keeper.mjs process (Windows). Prints the PIDs it stopped.
# A plain `kill $!` from a shell only reaches the wrapper, not the node process, so match on the command line.
$found = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'keeper\.mjs' }
foreach ($p in $found) {
  Stop-Process -Id $p.ProcessId -Force
  "stopped $($p.ProcessId)"
}
"running keepers now: " + @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'keeper\.mjs' }).Count
