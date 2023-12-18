FROM php:8.2-fpm

# Extensions
RUN apt-get update && apt-get install -y \
    vim \
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
    libpq-dev \
    libsqlite3-dev \
    telnet \
    && pecl install redis amqp imagick \
    && docker-php-ext-enable redis amqp imagick \
    && docker-php-ext-install mysqli pdo pdo_mysql zip xml mbstring bcmath soap intl gd xsl opcache \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Make PHP.ini file
RUN mv "/usr/local/etc/php/php.ini-development" "/usr/local/etc/php/php.ini"

# Update the PHP.ini file
RUN sed -i "s/memory_limit = 128M/memory_limit = 6G/" /usr/local/etc/php/php.ini
RUN sed -i "s/;date.timezone =/date.timezone = UTC/" /usr/local/etc/php/php.ini
RUN sed -i "s/max_execution_time = 30/max_execution_time = 300/" /usr/local/etc/php/php.ini
RUN sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 256M/" /usr/local/etc/php/php.ini
RUN sed -i "s/post_max_size = 8M/post_max_size = 256M/" /usr/local/etc/php/php.ini

# Composer
RUN \
	curl -sS https://getcomposer.org/installer | php && \
	mv composer.phar /usr/local/bin/composer && \
	composer self-update

