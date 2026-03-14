# Workspace Docker Environment

Unified Docker development environment that automatically serves **any project** in the workspace — no per-project configuration needed.

Clone any project into your workspace folder and it's instantly accessible via `http://<folder>.<repo-name>.test:81`. Powered by wildcard nginx + dnsmasq.

## Services

| Service    | Container      | Port          | Image             |
|------------|----------------|---------------|--------------------|
| Nginx      | dj_nginx       | 81 → 80      | nginx:latest       |
| PHP        | dj_php         | (internal)    | php:8.4-fpm        |
| MySQL      | dj_mysql       | 3307 → 3306  | mysql:8.0          |
| PostgreSQL | dj_postgres    | 5432          | postgres:16-alpine |
| Redis      | dj_redis       | 6379          | redis:latest       |
| Memcached  | dj_memcached   | 11211         | memcached:latest   |
| RabbitMQ   | dj_rabbitmq    | 5672 / 15672  | rabbitmq:3-mgmt    |
| phpMyAdmin | dj_phpmyadmin  | 8080 → 80    | phpmyadmin:latest  |

## Requirements

- [Docker Desktop](https://docker.com/products/docker-desktop/)
- [Homebrew](https://brew.sh) (for dnsmasq on macOS)

## Quick Start

```bash
# 1. Clone into your workspace
cd ~/Workspace
git clone https://github.com/jupaygon/docker.git

# 2. Configure DNS (one-time macOS setup)
./docker/scripts/setup-dnsmasq.sh

# 3. Start services
cd docker
cp .env.dist .env
docker compose up -d --build
```

## How It Works

### Wildcard Nginx + dnsmasq

1. **dnsmasq** resolves all `*.test` domains to `127.0.0.1`
2. **Nginx** captures the first subdomain segment as the folder name:
   ```
   server_name ~^(?<folder>[^.]+)\.;
   root /var/www/html/$folder/public;
   ```
3. The entire workspace is mounted as a single volume

### URL Format

```
http://<folder>.<repo-name>.test:81
```

Only the **first segment** (`<folder>`) determines which folder is served. The second segment (`<repo-name>`) is for DNS routing.

### Main checkout (master)

For a regular clone, `<folder>` and `<repo-name>` are the same:

```bash
cd ~/Workspace
git clone https://github.com/org/my-project.git
# → http://my-project.my-project.test:81
```

### Worktrees (parallel branches)

If you use [git worktrees](https://git-scm.com/docs/git-worktree) to work on multiple branches simultaneously, each worktree gets its own folder — and its own URL:

```bash
cd ~/Workspace/my-project
git worktree add ../wt-my-project-fix-login feature/fix-login
# → http://wt-my-project-fix-login.my-project.test:81
```

No nginx config, no hosts file, no restart. It just works.

## PHP Extensions

The PHP container includes everything you'd need for a modern Symfony/Laravel stack:

`redis` · `amqp` · `imagick` · `zip` · `xml` · `mbstring` · `bcmath` · `soap` · `intl` · `gd` · `xsl` · `opcache` · `pdo_mysql` · `pdo_pgsql` · `memcached` · `xdebug`

Plus Composer and Deployer pre-installed.

## Shell Aliases

Add to your `.zshrc`:

```bash
export DJ_HOME="$HOME/Workspace"

# Login into containers
alias dj-docker-php="docker exec -ti dj_php bash"
alias dj-docker-mysql="docker exec -ti dj_mysql bash"
alias dj-docker-nginx="docker exec -ti dj_nginx bash"
alias dj-docker-redis="docker exec -ti dj_redis redis-cli"

# Docker compose shortcut
alias dj-docker="docker compose -f $DJ_HOME/docker/docker-compose.yml"

# Start / stop
alias dj-docker-up="$DJ_HOME/docker/scripts/docker-up.sh"
alias dj-docker-build="dj-docker up --build -d"
alias dj-docker-down="$DJ_HOME/docker/scripts/docker-down.sh"

# Service UIs
alias dj-docker-rabbit="open http://localhost:15672"
alias dj-docker-pma="open http://localhost:8080"

# Monitoring
alias dj-docker-ps="docker ps | grep dj_"
alias dj-docker-images="docker images | grep dj_"
```

| Command            | Description                           |
|--------------------|---------------------------------------|
| `dj-docker-php`    | Shell into PHP container              |
| `dj-docker-mysql`  | Shell into MySQL container            |
| `dj-docker-redis`  | Redis CLI                             |
| `dj-docker`        | Docker compose shortcut               |
| `dj-docker-up`     | Start containers                      |
| `dj-docker-down`   | Stop containers (backs up databases)  |
| `dj-docker-build`  | Rebuild and start containers          |
| `dj-docker-rabbit` | Open RabbitMQ Management UI           |
| `dj-docker-pma`    | Open phpMyAdmin                       |

## Scripts

| Script                        | Description                                        |
|-------------------------------|----------------------------------------------------|
| `scripts/setup-dnsmasq.sh`    | One-time DNS setup (installs and configures dnsmasq)|
| `scripts/docker-up.sh`        | Start containers with credentials support          |
| `scripts/docker-down.sh`      | Stop containers with automatic database backup     |
| `scripts/db-sync.sh`          | Interactive database sync from remote servers      |

## Troubleshooting

### DNS not resolving *.test

```bash
# Verify dnsmasq
brew services list | grep dnsmasq

# Test resolution
dig test-project.test @127.0.0.1

# Re-run setup
./scripts/setup-dnsmasq.sh
```

### Site returns 404

- Ensure the project has a `public/` directory with an `index.php`
- Check the folder name matches the first subdomain segment exactly

### MySQL connection from PHP

```
Host: dj_mysql
Port: 3306
User: root | dev
Password: password
```

### PostgreSQL connection from PHP

```
Host: dj_postgres
Port: 5432
User: app
Password: password
Database: app
```

## License

MIT
