FROM php:8.3-fpm

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl zip unzip \
    libpng-dev libonig-dev libxml2-dev libzip-dev libicu-dev \
    && docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath gd intl zip \
    && pecl install redis && docker-php-ext-enable redis \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# To trust it, add this to your init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

WORKDIR /var/www/html
COPY . .

RUN composer install --no-interaction --prefer-dist --optimize-autoloader 2>/dev/null || true

EXPOSE 9000
CMD ["php-fpm"]
