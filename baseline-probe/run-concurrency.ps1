param(
  [int]$Concurrency = 2,
  [string]$BaseUrl = 'http://spark-570a:11434',
  [string]$Model = 'qwen3-coder:30b-32k'
)

$prompt = 'Write a JavaScript function that normalizes a repository path: convert backslashes to forward slashes, collapse repeated slashes, preserve one leading slash, and remove a trailing slash except for root. Return code only.'
$payload = @{
  model = $Model
  stream = $false
  keep_alive = '10m'
  messages = @(@{ role = 'user'; content = $prompt })
  options = @{ num_ctx = 32768; num_predict = 128; temperature = 0 }
} | ConvertTo-Json -Depth 6

Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$requests = @()
for ($i = 1; $i -le $Concurrency; $i++) {
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$BaseUrl/api/chat")
  $request.Content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  $task = $client.SendAsync($request)
  $requests += [pscustomobject]@{ Id = $i; Timer = $timer; Request = $request; Task = $task }
}

[System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($requests | ForEach-Object { $_.Task }))
$results = foreach ($item in $requests) {
  $item.Timer.Stop()
  $response = $item.Task.GetAwaiter().GetResult()
  [void]$response.EnsureSuccessStatusCode()
  $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  $result = $json | ConvertFrom-Json
  [pscustomobject]@{
    Request = $item.Id
    WallSeconds = [math]::Round($item.Timer.Elapsed.TotalSeconds, 2)
    LoadSeconds = [math]::Round($result.load_duration / 1e9, 2)
    PromptTokens = $result.prompt_eval_count
    OutputTokens = $result.eval_count
    GenerationTokensPerSecond = if ($result.eval_duration -gt 0) { [math]::Round(($result.eval_count * 1e9) / $result.eval_duration, 2) } else { $null }
    Done = $result.done
  }
  $response.Dispose()
  $item.Request.Dispose()
}
$client.Dispose()
$results | ConvertTo-Json -Depth 4
