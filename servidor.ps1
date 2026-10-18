# Servidor local sencillo para ver la web en http://localhost:5500
# (YouTube no reproduce vídeos si la página se abre con doble clic como archivo)
# -NoBrowser: arranca sin abrir una pestaña nueva
param([switch]$NoBrowser)
$port = 5500
$root = $PSScriptRoot
$types = @{
  '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css'; '.js' = 'text/javascript'
  '.json' = 'application/json'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
  '.gif' = 'image/gif'; '.svg' = 'image/svg+xml'; '.webp' = 'image/webp'; '.ico' = 'image/x-icon'
  '.mp4' = 'video/mp4'; '.webm' = 'video/webm'; '.woff2' = 'font/woff2'
}

# Handles one request. Runs in its own thread so a video that is still loading never blocks the rest of the page.
$handler = {
  param($ctx, $root, $types)
  $res = $ctx.Response
  $stream = $null
  try {
    $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
    if ($path -eq '') { $path = 'index.html' }
    $file = [IO.Path]::GetFullPath((Join-Path $root $path))
    if ($file.StartsWith($root) -and (Test-Path -LiteralPath $file -PathType Leaf)) {
      $ext = [IO.Path]::GetExtension($file).ToLower()
      $res.ContentType = if ($types[$ext]) { $types[$ext] } else { 'application/octet-stream' }
      $res.AddHeader('Accept-Ranges', 'bytes')
      $stream = [IO.File]::OpenRead($file)
      $size = $stream.Length; $start = 0; $end = $size - 1
      # Range requests ("bytes=start-end") let the browser stream and seek inside videos
      $range = $ctx.Request.Headers['Range']
      if ($range -match '^bytes=(\d*)-(\d*)$') {
        if ($Matches[1] -ne '') {
          $start = [long]$Matches[1]
          # open-ended ranges are answered in 4 MB pieces; the browser asks for the next one when it needs it
          $end = if ($Matches[2] -ne '') { [Math]::Min([long]$Matches[2], $size - 1) } else { [Math]::Min($start + 4MB - 1, $size - 1) }
        } elseif ($Matches[2] -ne '') {
          $start = [Math]::Max(0, $size - [long]$Matches[2])
        }
        $res.StatusCode = 206
        $res.AddHeader('Content-Range', "bytes $start-$end/$size")
      }
      $res.ContentLength64 = $end - $start + 1
      $stream.Position = $start
      $buffer = New-Object byte[] 262144
      $left = $end - $start + 1
      while ($left -gt 0) {
        $read = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $left))
        if ($read -le 0) { break }
        $res.OutputStream.Write($buffer, 0, $read)
        $left -= $read
      }
    } else {
      $res.StatusCode = 404
    }
  } catch {
    # the browser closed the connection (normal when a video seeks); ignore
  } finally {
    if ($stream) { $stream.Dispose() }
    try { $res.Close() } catch {}
  }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
$pool = [RunspaceFactory]::CreateRunspacePool(1, 16)
$pool.Open()
$running = New-Object System.Collections.ArrayList
Write-Host "Web abierta en http://localhost:$port  (cierra esta ventana para pararla)"
if (-not $NoBrowser) { Start-Process "http://localhost:$port/" }

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($handler).AddArgument($ctx).AddArgument($root).AddArgument($types)
    [void]$running.Add([pscustomobject]@{ Shell = $ps; Handle = $ps.BeginInvoke() })
    # free the threads of requests that already finished
    foreach ($job in @($running)) {
      if ($job.Handle.IsCompleted) {
        try { [void]$job.Shell.EndInvoke($job.Handle) } catch {}
        $job.Shell.Dispose()
        $running.Remove($job)
      }
    }
  }
} finally {
  $listener.Stop()
  $pool.Close()
}
