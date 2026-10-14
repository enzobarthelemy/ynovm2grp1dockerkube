FROM wordpress:7.1.3-php8.3-apache

RUN apt-get update && apt-get install -y --no-install-recommends \
        libzip-dev \
        libicu-dev \
        less \
    && docker-php-ext-install zip intl \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && rm -rf /var/lib/apt/lists/*

RUN curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp

COPY php/custom.ini /usr/local/etc/php/conf.d/custom.ini

COPY --chown=www-data:www-data wp-content/themes/ /var/www/html/wp-content/themes/
COPY --chown=www-data:www-data wp-content/plugins/ /var/www/html/wp-content/plugins/
COPY --chown=www-data:www-data wp-content/mu-plugins/ /var/www/html/wp-content/mu-plugins/

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost/wp-login.php || exit 1
