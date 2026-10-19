$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
docker compose --env-file $envFile -f (Join-Path $root "docker-compose.yml") stop
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose could not stop the demo services."
}
