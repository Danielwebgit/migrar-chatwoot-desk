# migrar-chatwoot-desk

## Rodar o seguinte comando no servidor de origem antes de iniciar a migração

docker service scale $(docker service ls --format '{{.Name}}' \
  | grep -E 'chatwoot|sidekiq|redis|postgres' \
  | sed 's/$/=0/')
