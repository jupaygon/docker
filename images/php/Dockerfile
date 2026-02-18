FROM php:8.4-fpm

# Extensions
RUN apt-get update && apt-get install -y \
    vim \
    git \
    unzip \
    libzip-dev \
    libmemcached-dev \
    libmagickwand-dev \
    librabbitmq-dev \
    librabbitmq4 \
    libicu-dev \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libxslt1-dev \
    libonig-dev \
    libmcrypt-dev \
    libxml2-dev \
    libssl-dev \
    graphviz \
    procps \
    libpq-dev \
    libsqlite3-dev \
    telnet \
    default-mysql-client \
    openssh-client \
    entr \
    && pecl install xdebug redis amqp imagick \
    && docker-php-ext-enable xdebug redis amqp imagick \
    && docker-php-ext-install mysqli pdo pdo_mysql zip xml mbstring bcmath soap intl gd xsl opcache \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Xdebug configuration
RUN echo "xdebug.mode=coverage" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.mode=off" >> /usr/local/etc/php/conf.d/20-xdebug.ini

# Make PHP.ini file
RUN mv "/usr/local/etc/php/php.ini-development" "/usr/local/etc/php/php.ini"

# Update the PHP.ini file
RUN sed -i "s/memory_limit = 128M/memory_limit = 6G/" /usr/local/etc/php/php.ini
RUN sed -i "s/;date.timezone =/date.timezone = UTC/" /usr/local/etc/php/php.ini
RUN sed -i "s/max_execution_time = 30/max_execution_time = 300/" /usr/local/etc/php/php.ini
RUN sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 256M/" /usr/local/etc/php/php.ini
RUN sed -i "s/post_max_size = 8M/post_max_size = 256M/" /usr/local/etc/php/php.ini

# Install Memcached extension
RUN apt-get update && apt-get install -y libmemcached-dev zlib1g-dev \
    && pecl install memcached \
    && docker-php-ext-enable memcached \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Composer
RUN \
    curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer && \
    composer self-update

# Install Deployer
RUN composer global require deployer/deployer
ENV PATH="/root/.composer/vendor/bin:${PATH}"

# Make a global script to run Deployer
RUN echo '#!/bin/bash\n'\
'if [ -f ./vendor/deployer/deployer/bin/dep ]; then\n'\
'  ./vendor/deployer/deployer/bin/dep "$@"\n'\
'else\n'\
'  echo "Error: Deployer not found in $(pwd)"\n'\
'  exit 1\n'\
'fi' > /usr/local/bin/dep && chmod +x /usr/local/bin/dep
