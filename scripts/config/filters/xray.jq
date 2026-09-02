.
| .inbounds[0].port = $port
| .inbounds[0].settings.clients[0].id = $uuid
| .inbounds[0].streamSettings.realitySettings.target = $target
| .inbounds[0].streamSettings.realitySettings.serverNames = (
    $servernames
    | split(",")
    | map(sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
  )
| .inbounds[0].streamSettings.realitySettings.shortIds = (
    $shortids
    | split(",")
    | map(sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
  )
| .inbounds[0].streamSettings.realitySettings.privateKey = $private_key
| .inbounds[0].streamSettings.realitySettings.mldsa65Seed = $mldsa65_seed
