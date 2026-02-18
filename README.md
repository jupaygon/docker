# Workspace Docker Environment v2.0.0

Unified Docker development environment that automatically serves any project in the workspace — no per-project configuration needed.

## Changelog (from jupaygon/docker)

- **v2.0.0** — Unified workspace: wildcard nginx, single volume mount, `dj_` prefix, dnsmasq setup, agent docs.

## Services

| Service    | Container      | Port          |
|------------|----------------|---------------|
| Nginx      | dj_nginx       | 81 → 80      |
| PHP 8.4    | dj_php         | (internal)    |
| MySQL 8.0  | dj_mysql       | 3307 → 3306  |
| Redis      | dj_redis       | 6379          |
| Memcached  | dj_memcached   | 11211         |
| RabbitMQ   | dj_rabbitmq    | 5672 / 15672  |
| phpMyAdmin | dj_phpmyadmin  | 8080 → 80    |

## Requirements

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Homebrew](https://brew.sh) (for dnsmasq on macOS)

## Installation

```bash
# 1. Clone this repo inside your workspace
cd ~/Workspace
git clone git@github.com:jupaygon/docker.git

# 2. Configure DNS (one-time setup)
./docker/scripts/setup-dnsmasq.sh

# 3. Copy and configure agent credentials (optional)
cp docker/.github.conf.dist docker/.github.conf
# Edit .github.conf with your agent token

# 4. Start services
cd docker
docker compose up -d --build
```

## How It Works

### Wildcard Nginx + dnsmasq

1. **dnsmasq** resolves all `*.test` domains to `127.0.0.1`
2. **Nginx** uses a regex server block that captures the first subdomain segment as the folder name:
   ```
   server_name ~^(?<folder>[^.]+)\.;
   root /var/www/html/$folder/public;
   ```
3. The entire workspace is mounted as a single volume: `${WORKSPACE_PATH:-..}:/var/www/html`

### URL Format

```
http://<folder>.<project>.test:81
```

- `my-project.my-project.test:81` → `/var/www/html/my-project/public`
- `wt-my-project-zn-123-slug.my-project.test:81` → `/var/www/html/wt-my-project-zn-123-slug/public`

The second segment (`<project>`) is used for DNS routing but **only the first segment** (`<folder>`) determines which folder is served.

## Adding a Project

Just clone it into the workspace. That's it.

```bash
cd ~/Workspace
git clone git@github.com:org/my-project.git
```

Then access it at: `http://my-project.my-project.test:81`

## Shell Aliases (.zshrc)

```bash
# Workspace Docker aliases
export DJ_HOME="$HOME/Workspace"

# Login into containers
alias dj-docker-php="docker exec -ti dj_php bash"
alias dj-docker-mysql="docker exec -ti dj_mysql bash"
alias dj-docker-nginx="docker exec -ti dj_nginx bash"
alias dj-docker-redis="docker exec -ti dj_redis redis-cli"

# See docker containers and images
alias dj-docker-ps="docker ps | grep dj_"
alias dj-docker-images="docker images | grep dj_"

# Docker compose shortcut (e.g. dj-docker logs dj_php)
alias dj-docker="docker compose -f $DJ_HOME/docker/docker-compose.yml"

# Start / build / stop
alias dj-docker-up="$DJ_HOME/docker/scripts/docker-up.sh"
alias dj-docker-build="dj-docker up --build -d"
alias dj-docker-down="$DJ_HOME/docker/scripts/docker-down.sh"

# Quick access to services UI
alias dj-docker-rabbit="open http://localhost:15672"
alias dj-docker-pma="open http://localhost:8080"

# Remove all dj_ containers
dj-docker-rm() {
  docker rm $(docker ps -a | grep 'dj_' | awk '{print $1}')
}
# Remove all dj_ images
dj-docker-rmi() {
  docker rmi $(docker images -a | grep 'dj_' | awk '{print $3}')
}
```

Add to your `.zshrc` (or `.bashrc`) and reload:

```bash
source ~/.zshrc
```

**Commands reference:**

| Command            | Description                                |
|--------------------|--------------------------------------------|
| `dj-docker-php`    | Login into PHP container                   |
| `dj-docker-mysql`  | Login into MySQL container                 |
| `dj-docker-nginx`  | Login into Nginx container                 |
| `dj-docker-redis`  | Login into Redis CLI                       |
| `dj-docker-ps`     | List running dj_ containers               |
| `dj-docker-images` | List dj_ images                            |
| `dj-docker`        | Docker compose shortcut (e.g. `dj-docker logs`) |
| `dj-docker-up`     | Start containers                           |
| `dj-docker-build`  | Build and start containers                 |
| `dj-docker-down`   | Stop containers                            |
| `dj-docker-rm`     | Remove all dj_ containers                  |
| `dj-docker-rmi`    | Remove all dj_ images                      |
| `dj-docker-rabbit` | Open RabbitMQ UI                           |
| `dj-docker-pma`    | Open phpMyAdmin                            |

## Ports & Services

| Port  | Service                      |
|-------|------------------------------|
| 81    | Nginx (HTTP)                 |
| 3307  | MySQL                        |
| 5672  | RabbitMQ (AMQP)              |
| 15672 | RabbitMQ (Management UI)     |
| 6379  | Redis                        |
| 11211 | Memcached                    |
| 8080  | phpMyAdmin                   |

## Troubleshooting

### DNS not resolving *.test

```bash
# Verify dnsmasq is running
brew services list | grep dnsmasq

# Test resolution
dig test-project.test @127.0.0.1

# Re-run setup if needed
./scripts/setup-dnsmasq.sh
```

### Site returns 404 or "directory index of ... is forbidden"

- Ensure the project has a `public/` directory with an `index.php`
- Check the folder name matches the first subdomain segment exactly

### MySQL connection from PHP

```
Host: dj_mysql
Port: 3306
User: root / dev
Password: password
```

### Container names conflict

If you have other Docker environments using the same ports, stop them first:

```bash
docker compose -f ~/path/to/other/docker-compose.yml down
```
