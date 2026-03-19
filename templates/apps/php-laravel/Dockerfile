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

# Entrypoint that auto-trusts the DevStack CA cert if mounted at /certs/ca.crt
RUN printf '#!/bin/sh\n\
if [ -f /certs/ca.crt ]; then\n\
    cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt\n\
    update-ca-certificates 2>/dev/null\n\
fi\n\
exec "$@"\n' > /usr/local/bin/docker-entrypoint.sh && chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/html
COPY . .

RUN composer install --no-interaction --prefer-dist --optimize-autoloader 2>/dev/null || true

EXPOSE 9000
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
