# 🐳 Jupaygon Docker

Basic Docker configuration for web projects.

### 🛠 Services

- [Nginx](https://www.nginx.com/) as web server.
- [PHP-FPM](https://www.php.net/manual/en/install.fpm.php) as PHP FastCGI implementation.
- [MariaDB](https://mariadb.org/) as database engine.
- [phpMyAdmin](https://www.phpmyadmin.net/) as database administration tool.
- [RabbitMQ](https://www.rabbitmq.com/) as Message Queue Engine.
    - Includes the [Delayed Message Exchange Plugin](https://github.com/rabbitmq/rabbitmq-delayed-message-exchange).
- [Redis](https://redis.io/) for shared in-memory data store.
- [Memcached](https://memcached.org/) as distributed memory caching system.
- [Memcachedadmin](https://elijaa.org/phpmemcachedadmin-installation-guide.html) as Memcached administration tool.

### 📋 Pre requirements

- [docker](https://docs.docker.com/engine/install/)
- [docker-compose](https://docs.docker.com/compose/install/)

Docker documentation: [https://docs.docker.com/manuals/](https://docs.docker.com/manuals/)

### 🔧 Install

Clone the repository in your projects' folder:

```
git clone git@github.com:jupaygon/docker.git
```

If you want to make your own repository starting from this one, follow the next steps:

- Make your new repository in GitHub, we will asume that the name of your new repo is "docker" but you can change it.
- Clone original one to your new repo with the following commands:

```
git clone --bare git@github.com:jupaygon/docker.git
cd docker.git
git push --mirror git@github.com:your_github_username/docker.git
cd ..
rm -rf docker.git
```

- Now you new repository "docker" is a exact copy of "jupaygon/docker". You can download it executing the following command in your projects' folder:

```
git clone git@github.com:your_github_username/docker.git
```

### ⚙️ Setup

- Create a Nginx configuration file for each domain, in the **images/nginx/conf.d/** folder. See the provided example in **jpg-domain.conf** file.
- Add a volume for each project in nginx and php services of the **docker-compose.yml** file. See the provided example in **volumes** section of both services.
- Add your projects' folders (one by project) in the same level than **docker** folder.
- You have to add the domains to local file /etc/hosts.
- You can change the prefix "jpg_" of the containers in the **docker-compose.yml** file, as well as the bash aliases in the **.bashrc** (or similar file). The use of the prefix is recommended to avoid conflicts with other containers.
- In the same way, feel free to change the ports of the services in the **docker-compose.yml** file.
    - Port 81 is configured for Nginx (default is 80).
    - Port 3307 is configured for MariaDB (default is 3306).
    - Change others service ports if you have some conflict with others containers declared in others docker-compose.yml.

### 🛟 Database backup 🚨

Ensure to save updated backups of your databases as **.sql** files  in the **images/mariadb/dumps/** folder, before to stop the container.

The backups file will be imported automatically when the container starts, and you will lost the changes if you don't do it.

If you do not want this behavior, please comment the line **- ./images/mariadb/dumps:/docker-entrypoint-initdb.d** in the **docker-compose.yml** file.

### 🐳 Main docker commands

Add the following lines to your **.bashrc** (or similar like .zshrc) file:

```
#### Bash alias and functions ####
# Login into php container (repeat for each container if you need it)
alias jpg-docker-php="docker exec -ti jpg_php bash"
# See docker containers
alias jpg-docker-ps="docker ps | grep jpg_"
# See docker images
alias jpg-docker-images="docker images | grep jpg_"
# Set up the containers
alias jpg-docker-up="docker-compose up -d"
# Set up the containers and build the images
alias jpg-docker-build="docker-compose up --build -d"
# Stop the containers
alias jpg-docker-down="docker-compose down"
# Delete all containers
jpg-docker-rm() {
  docker rm $(docker ps -a | grep 'jpg_' | awk '{print $1}')
}
# Delete all images
jpg-docker-rmi() {
  docker rmi $(docker images -a | grep 'jpg_' | awk '{print $3}')
}
```

Execute the following command to reload the **.bashrc** file:

``` 
source ~/.bashrc
```

Use of commands:

| Command                               | Description                                |
|---------------------------------------|--------------------------------------------|
| jpg-docker-php                        | Login into php container                   |
| docker exec -ti {container_name} bash | Login into expecified container            |
| jpg-docker-ps                         | See docker containers                      |
| jpg-docker-images                     | See docker images                          |
| jpg-docker-up                         | Set up the containers                      |
| jpg-docker-build                      | Set up the containers and build the images |
| jpg-docker-down                       | Stop the containers                        |
| jpg-docker-rm                         | Delete all containers                      |
| jpg-docker-rmi                        | Delete all images                          |

### 📡 Access to services


| Service           | Url                               |
|-------------------|-----------------------------------|
| 🌐 Nginx          | [http://jpg-domain.local:81](http://jpg-domain.local:81) |
| 🐇 RabbitMQ       | [http://localhost:15672](http://localhost:15672)     |
| 🐘 phpMyAdmin     | [http://localhost:9080](http://localhost:9080)      |
| 🧠 Memcachedadmin | [http://localhost:9001/](http://localhost:9001/)     |
