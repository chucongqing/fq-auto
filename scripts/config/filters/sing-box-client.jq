def trim:
  sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");

def host_parts($hostport):
  if ($hostport | test("^[^:]+:[0-9]+$")) then
    ($hostport | capture("^(?<server>[^:]+):(?<port>[0-9]+)$"))
    | {server: .server, server_port: (.port | tonumber)}
  else
    {server: $hostport}
  end;

def parse_dns($tag; $value; $detour):
  if ($value | test("^(tls|https|quic|h3|tcp|udp)://")) then
    ($value | capture("^(?<type>tls|https|quic|h3|tcp|udp)://(?<hostport>[^/]+)(?<path>/.*)?$")) as $uri
    | (host_parts($uri.hostport)) as $parts
    | ({tag: $tag, type: $uri.type} + $parts)
    | if (($uri.path // "") == "/" or ($uri.path // "") == "") then . else .path = $uri.path end
    | if $detour == "" then . else .detour = $detour end
  else
    (host_parts($value)) as $parts
    | ({tag: $tag, type: "udp"} + $parts)
    | if $detour == "" then . else .detour = $detour end
  end;

def enabled($tag):
  ($tag == "vless" and $enable_vless == "true") or
  ($tag == "hy2" and $enable_hy2 == "true") or
  ($tag == "tuic" and $enable_tuic == "true") or
  ($tag == "anytls" and $enable_anytls == "true");

.
| .dns.servers = [
    parse_dns("remote-dns"; $remote_dns; $default_outbound),
    parse_dns("local-dns"; $local_dns; "")
  ]
| .inbounds[0].listen = $mixed_listen
| .inbounds[0].listen_port = $mixed_port
| .outbounds |= map(
    if (.tag == "vless" or .tag == "hy2" or .tag == "tuic" or .tag == "anytls") and (enabled(.tag) | not) then
      empty
    elif .tag == "warp" and $enable_warp != "true" then
      empty
    else
      .
    end
  )
| (.outbounds[] | select(.tag == "vless")) |= (
    .server = $vless_server
    | .server_port = $vless_port
    | .uuid = $vless_uuid
    | .tls.server_name = $vless_server_name
    | .tls.reality.public_key = $vless_public_key
    | .tls.reality.short_id = $vless_short_id
  )
| (.outbounds[] | select(.tag == "hy2")) |= (
    .server = $hy2_server
    | .server_port = $hy2_port
    | .password = $hy2_password
    | .tls.server_name = $hy2_server_name
  )
| (.outbounds[] | select(.tag == "tuic")) |= (
    .server = $tuic_server
    | .server_port = $tuic_port
    | .uuid = $tuic_uuid
    | .password = $tuic_password
    | .tls.server_name = $tuic_server_name
  )
| (.outbounds[] | select(.tag == "anytls")) |= (
    .server = $anytls_server
    | .server_port = $anytls_port
    | .password = $anytls_password
    | .tls.server_name = $anytls_server_name
  )
| if ($enable_warp == "true") then
    (.outbounds[] | select(.tag == "warp")) |= (.server = $warp_server | .server_port = $warp_port)
  else
    .route.rules |= map(select(.outbound != "warp"))
  end
| .route.rules |= map(
    if .clash_mode == "global" then .outbound = $default_outbound else . end
  )
| .route.final = $default_outbound
