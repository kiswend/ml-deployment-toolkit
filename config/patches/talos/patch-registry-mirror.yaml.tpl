machine:
  registries:
    mirrors:
      docker.io:
        endpoints:
          - https://${proxy_url}/v2/docker-hub
      ghcr.io:
        endpoints:
          - https://${proxy_url}/v2/ghcr
      quay.io:
        endpoints:
          - https://${proxy_url}/v2/quay
      registry.k8s.io:
        endpoints:
          - https://${proxy_url}/v2/k8s
    config:
      ${proxy_url}:
        auth:
          username: ${proxy_username}
          password: ${proxy_password}
