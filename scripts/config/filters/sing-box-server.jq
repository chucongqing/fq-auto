.
| .inbounds[0].listen_port = $tuic_port
| .inbounds[0].users[0].uuid = $tuic_uuid
| .inbounds[0].users[0].password = $tuic_password
| .inbounds[0].tls.server_name = $site
| .inbounds[1].listen_port = $anytls_port
| .inbounds[1].users[0].name = $anytls_username
| .inbounds[1].users[0].password = $anytls_password
| .inbounds[1].tls.server_name = $site
| if ($warp_server == "" or $warp_port == 0) then
    .outbounds |= map(select(.tag != "warp"))
    | .route.rules |= map(select(.outbound != "warp"))
  else
    (.outbounds[] | select(.tag == "warp")) |= (.server = $warp_server | .server_port = $warp_port)
  end
