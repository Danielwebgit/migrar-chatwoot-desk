#!/bin/bash
set -euo pipefail

REMOTE_USER="usuario"
REMOTE_HOST="IP_DO_SERVIDOR"
SSH_PASS="SENHA"

REMOTE_BACKUP_DIR="/tmp/chatwoot_backup"
POSTGRES_HOST="postgres"
POSTGRES_USERNAME="chatwoot"
POSTGRES_PASSWORD="POSTGRES_PASSWORD"
POSTGRES_DATABASE="chatwoot"
FRONTEND_URL="chatwoot.seu_dominio.com.br"
POSTGRES_PORT="5432" #Normalmente é 5432, mas pode ser alterada
#------------------------------------------------ Backup e cópia dos volumes -----------------------------------------------

docker service scale $(docker service ls --format '{{.Name}}' \
  | grep -E 'chatwoot|sidekiq|redis|postgres' \
  | sed 's/$/=0/')

# Cria diretório remoto
sshpass -p "$SSH_PASS" ssh $REMOTE_USER@$REMOTE_HOST "mkdir -p ${REMOTE_BACKUP_DIR}"

# Faz backup de todos os volumes que contêm "chatwoot" no nome usando um contêiner Alpine
sshpass -p "$SSH_PASS" ssh $REMOTE_USER@$REMOTE_HOST bash -c "'
set -e
VOLUMES=\$(docker volume ls --format \"{{.Name}}\" | grep chatwoot || true)

if [ -z \"\$VOLUMES\" ]; then
  echo \"⚠️ Nenhum volume do Chatwoot encontrado\"
  exit 0
fi

for VOL in \$VOLUMES; do
  echo \"📦 Fazendo backup do volume: \$VOL\"
  docker run --rm \
    -v \"\$VOL:/data:ro\" \
    -v \"${REMOTE_BACKUP_DIR}:/backup\" \
    alpine sh -c \"tar czf /backup/\${VOL}.tar.gz -C /data .\"
done
'"
echo "✅ Backup de todos os volumes do Chatwoot criado no servidor de origem em ${REMOTE_BACKUP_DIR}/"

# --------------------------------------------------------------------------------------

# Executa o dump do banco de dados no container correto
sshpass -p "$SSH_PASS" ssh $REMOTE_USER@$REMOTE_HOST bash -c "'
# Identifica o container do Postgres (pega o primeiro que encontrar)
PG_CONTAINER=\$(docker ps --filter name=postgres --format \"{{.Names}}\" | head -n1)

if [ -z \"\$PG_CONTAINER\" ]; then
    echo \"❌ Nenhum container Postgres encontrado\"
    exit 1
fi

echo \"🔹 Exportando banco do container \$PG_CONTAINER...\"

# Define nome do arquivo de backup com timestamp
DATA=\$(date +\"%Y%m%d-%H%M%S\")
BACKUP_FILE=${REMOTE_BACKUP_DIR}/chatwoot_db.dump

# Executa pg_dump no formato custom (-Fc)
docker exec \$PG_CONTAINER pg_dump -U postgres -Fc --no-acl --no-owner chatwoot > \$BACKUP_FILE

echo \"✅ Backup do banco criado no servidor de origem em: \$BACKUP_FILE\"
'"

# --------------------------------------------------------------------------------------

echo "📦 Fazendo importação do Banco de dados"
rsync -avz -P $REMOTE_USER@$REMOTE_HOST:/tmp/chatwoot_backup/chatwoot_db.dump ~/chatwoot/postgresql/
echo "✅ Importação do Banco de Dados concluída"
# --------------------------------------------------------------------------------------
echo "📦 Fazendo importação dos volumes"
rsync -avz -e "ssh -c aes128-ctr" --progress $REMOTE_USER@$REMOTE_HOST:/tmp/chatwoot_backup/chatwoot_data.tar.gz ~/chatwoot/volumes/
echo "✅ Importação dos volumes concluída"
# --------------------------------------------------------------------------------------

docker service scale $(docker service ls --format '{{.Name}}' \
  | grep -E 'chatwoot|sidekiq|redis|postgres' \
  | sed 's/$/=1/')

# === Extrair variáveis de todos os containers Chatwoot e criar .env remoto ===
sshpass -p "$SSH_PASS" ssh $REMOTE_USER@$REMOTE_HOST bash -c "'
mkdir -p /tmp/chatwoot_backup
docker ps --format \"{{.Names}}\" | grep chatwoot | while read CONTAINER; do
    echo \"# Variáveis do container \$CONTAINER\"
    docker exec -i \$CONTAINER printenv
    echo \"\"
done > /tmp/chatwoot_backup/.env
'"
echo "✅ .env gerado em: /tmp/chatwoot_backup/.env no servidor remoto"

# Copia todos os arquivos de backup para a sua máquina local
scp -r ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP_DIR} ~/chatwoot/volumes
echo "✅ Volumes copiados para ~/chatwoot/volumes"

#-----------------------------------------------------------------------------------------------------------------------------

# === Função auxiliar para rodar comandos no servidor remoto ===
remote_exec() {
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no $REMOTE_USER@$REMOTE_HOST "$1"
}

echo "🔎 Identificando containers no servidor $REMOTE_HOST ..."

# Identifica containers
PG_CONTAINER=$(remote_exec "docker ps --filter name=postgres --format '{{.Names}}' | head -n1")
REDIS_CONTAINER=$(remote_exec "docker ps --filter name=redis --format '{{.Names}}' | head -n1")
CHATWOOT_CONTAINER=$(remote_exec "docker ps --filter name=chatwoot --format '{{.Names}}' | head -n1")

if [[ -z "$PG_CONTAINER" || -z "$REDIS_CONTAINER" || -z "$CHATWOOT_CONTAINER" ]]; then
  echo "❌ Não foi possível identificar todos os containers (Postgres, Redis, Chatwoot)."
  exit 1
fi

# Pega imagens
PG_IMAGE=$(remote_exec "docker inspect -f '{{.Config.Image}}' $PG_CONTAINER | cut -d'@' -f1")
REDIS_IMAGE=$(remote_exec "docker inspect -f '{{.Config.Image}}' $REDIS_CONTAINER | cut -d'@' -f1")
CHATWOOT_IMAGE=$(remote_exec "docker inspect -f '{{.Config.Image}}' $CHATWOOT_CONTAINER | cut -d'@' -f1")

# Pega volumes
PG_VOLUME=$(remote_exec "docker inspect -f '{{ range .Mounts }}{{ if eq .Destination \"/var/lib/postgresql/data\"}}{{.Name}}{{end}}{{end}}' $PG_CONTAINER")
REDIS_VOLUME=$(remote_exec "docker inspect -f '{{ range .Mounts }}{{ if eq .Destination \"/data\"}}{{.Name}}{{end}}{{end}}' $REDIS_CONTAINER")
STORAGE_VOLUME=$(remote_exec "docker inspect -f '{{ range .Mounts }}{{ if eq .Destination \"/app/storage\"}}{{.Name}}{{end}}{{end}}' $CHATWOOT_CONTAINER")

# Pega a rede do container Chatwoot (primeira encontrada)
REDE_NETWORK=$(remote_exec "docker inspect -f '{{range \$key, \$value := .NetworkSettings.Networks}}{{\$key}}{{end}}' $CHATWOOT_CONTAINER")
if [[ -z "$REDE_NETWORK" ]]; then
  echo "❌ Não foi possível identificar a rede do container Chatwoot."
  exit 1
fi

echo "📦 Encontrado:"
echo "   - Chatwoot image: $CHATWOOT_IMAGE"
echo "   - Postgres image: $PG_IMAGE"
echo "   - Redis image:    $REDIS_IMAGE"
echo "   - Volumes: storage=[$STORAGE_VOLUME], postgres=[$PG_VOLUME], redis=[$REDIS_VOLUME]"

# === Gera docker-stack.yml ===
# ---------------------- chatwoot_admin.yml ----------------------
cat > "chatwoot_admin.yml" <<EOF
version: "3.8"

x-base: &base
  image: $CHATWOOT_IMAGE
  environment:
      RAILS_ENV: production
      NODE_ENV: production
      INSTALLATION_ENV: docker
      SECRET_KEY_BASE: "-------------SUAKEYAQUI-----------------------"
      FRONTEND_URL: https://$FRONTEND_URL
      DEFAULT_LOCALE: "pt_BR"
      FORCE_SSL: "true"
      ENABLE_ACCOUNT_SIGNUP: "false"
      REDIS_URL: redis://redis:6379
      POSTGRES_HOST: postgres
      POSTGRES_USERNAME: $POSTGRES_USERNAME
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DATABASE: $POSTGRES_DATABASE
      ACTIVE_STORAGE_SERVICE: local
      RAILS_LOG_TO_STDOUT: "true"
      USE_INBOX_AVATAR_FOR_BOT: "true"
      SIDEKIQ_CONCURRENCY: 10
      WEB_CONCURRENCY: 2
      RAILS_MAX_THREADS: 5
      RACK_TIMEOUT_SERVICE_TIMEOUT: 0
      ENABLE_RACK_ATTACK: "false"
  volumes:
    - $STORAGE_VOLUME:/app/storage
  networks:
    - $REDE_NETWORK
  deploy:
    mode: replicated
    replicas: 1
    placement:
      constraints:
        - node.role == manager
    resources:
      limits:
        cpus: "1"
        memory: 1G
    restart_policy:
      condition: on-failure

services:
  rails_prepare:
    <<: *base
    deploy:
      replicas: 1
      restart_policy:
        condition: none
    command: /bin/sh -c "until pg_isready -h postgres -p 5432 -U postgres; do echo 'Waiting for Postgres...'; sleep 2; done; echo 'Running db:chatwoot_prepare...'; bundle exec rails db:chatwoot_prepare; echo 'Prepare finished.'"

  rails:
    <<: *base
    depends_on:
      - rails_prepare
    command: ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.rails.rule=Host(`$FRONTEND_URL`)"
        - "traefik.http.routers.rails.entrypoints=websecure"
        - "traefik.http.routers.rails.tls.certresolver=letsencryptresolver"
        - "traefik.http.services.rails.loadbalancer.server.port=3000"
        - "traefik.http.services.rails.loadbalancer.passhostheader=true"
        - "traefik.http.middlewares.sslheader.headers.customrequestheaders.X-Forwarded-Proto=https"
        - "traefik.http.routers.rails.middlewares=sslheader@docker"
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: "2"
          memory: 2G
      restart_policy:
        condition: on-failure
volumes:
  $STORAGE_VOLUME:

networks:
  $REDE_NETWORK:
    external: true
EOF
echo "✅ chatwoot_admin.yml gerado"

cat > "sidekiq.yml" <<EOF
version: "3.8"

services:
  sidekiq:
    image: $CHATWOOT_IMAGE
    environment:
      NODE_ENV: production
      RAILS_ENV: production
      INSTALLATION_ENV: docker
      SECRET_KEY_BASE: "-------------SUAKEYAQUI-----------------------"
      FRONTEND_URL: "https://$FRONTEND_URL"
      DEFAULT_LOCALE: "pt_BR"
      FORCE_SSL: "true"
      ENABLE_ACCOUNT_SIGNUP: "false"
      REDIS_URL: "redis://redis:6379"
      POSTGRES_HOST: postgres
      POSTGRES_USERNAME: $POSTGRES_USERNAME
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DATABASE: $POSTGRES_DATABASE
      ACTIVE_STORAGE_SERVICE: local
      RAILS_LOG_TO_STDOUT: "true"
      USE_INBOX_AVATAR_FOR_BOT: "true"
      SIDEKIQ_CONCURRENCY: 10
      ENABLE_RACK_ATTACK: "false"
      RACK_TIMEOUT_SERVICE_TIMEOUT: 0
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    networks:
      - ${REDE_NETWORK}
    deploy:
      replicas: 1
      update_config:
        parallelism: 1
        delay: 10s
      restart_policy:
        condition: on-failure

networks:
  ${REDE_NETWORK}:
    external: true
EOF

echo "✅ sidekiq.yml gerado"

# ---------------------- postgres.yml ----------------------
cat > "postgres.yml" <<EOF
version: '3.8'
services:
  postgres:
    image: $PG_IMAGE
    ports:
      - '$POSTGRES_PORT:5432'
    volumes:
      - $PG_VOLUME:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=chatwoot
      - POSTGRES_USER=$POSTGRES_USERNAME
      - POSTGRES_PASSWORD=$POSTGRES_PASSWORD
    networks:
      - $REDE_NETWORK
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure

volumes:
  $PG_VOLUME:
    external: true

networks:
  $REDE_NETWORK:
    external: true
EOF
echo "✅ postgres.yml gerado"
# ---------------------- redis.yml ----------------------
cat > "redis.yml" <<EOF
version: '3.8'

services:
  redis:
    image: $REDIS_IMAGE
    volumes:
      - $REDIS_VOLUME:/data
    ports:
      - '6379:6379'
    networks:
      - $REDE_NETWORK
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
    command: [
      "redis-server",
      "--appendonly", "yes",
      "--port", "6379",
      "--maxmemory", "800mb",
      "--maxmemory-policy", "allkeys-lru"
    ]

volumes:
  $REDIS_VOLUME:
    external: true

networks:
  $REDE_NETWORK:
    external: true
EOF
echo "✅ redis.yml gerado"

echo "✅ Arquivos separados gerados chatwoot_admin.yml, postgres.yml, redis.yml"
