# PHP-FPM container for WordPress sites: runs PHP only. Static files, .htaccess rules and keep-alive
# connections are handled by the Apache container (ghcr.io/pjirlip/httpd, built from the php8.2
# repository), which proxies .php requests to this container over 127.0.0.1:9000 inside the same pod.
FROM php:8.4-fpm
LABEL maintainer="Philipp Dippel <philipp.dippel@propeller.de>"
SHELL ["/bin/bash", "-c"]

RUN addgroup --gid 1000 propeller && useradd --system -u 1000 -g propeller propeller

ENV PROVISION_CONTEXT="production"
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin
ENV DOCUMENT_ROOT=/var/www/html
ENV LETSENCRYPT_EMAIL=certbot@propeller.de
# Pool sizing (K1). An empty PHP_FPM_MAX_CHILDREN lets entrypoint.sh derive the value from the container
# memory limit: floor((limit_MiB - BASELINE_MB) / CHILD_MB). Only PHP requests occupy a child.
ENV PHP_FPM_LISTEN=127.0.0.1:9000 \
    PHP_FPM_PM=dynamic \
    PHP_FPM_MAX_CHILDREN="" \
    PHP_FPM_CHILD_MEMORY_MB=64 \
    PHP_FPM_BASELINE_MEMORY_MB=256 \
    PHP_FPM_START_SERVERS=2 \
    PHP_FPM_MIN_SPARE_SERVERS=1 \
    PHP_FPM_MAX_SPARE_SERVERS=4 \
    PHP_FPM_PROCESS_IDLE_TIMEOUT=10s \
    PHP_FPM_MAX_REQUESTS=1000 \
    PHP_FPM_REQUEST_TERMINATE_TIMEOUT=300 \
    PHP_FPM_SLOWLOG_TIMEOUT=0

ENV SMTP_SERVER=example.com
ENV SMTP_PORT=25
ENV SMTP_FROM=mail@example.com
ENV PHP_MEMORY_LIMIT=256M
ENV PHP_MAX_EXEC_TIME=240
ENV PHP_POST_AND_UPLOAD_MAX_SIZE=50M
# PHP runtime tuning (K2, H4)
ENV PHP_OPCACHE_MEMORY=192 \
    PHP_OPCACHE_MAX_FILES=50000 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    PHP_OPCACHE_REVALIDATE_FREQ=60 \
    PHP_MYSQLND_NET_READ_TIMEOUT=300

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY ./config/php.ini /usr/local/etc/php/conf.d/zz-propeller.ini
COPY ./config/php-fpm.conf /usr/local/etc/php-fpm.conf
COPY ./config/locale.gen /etc/locale.gen
COPY ./scripts/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh && \
    # the base image's pool files (www.conf, docker.conf, zz-docker.conf) are replaced by the pool
    # entrypoint.sh writes at startup
    rm -f /usr/local/etc/php-fpm.d/*.conf

RUN mkdir -p /home/propeller/.composer/cache && chown -R propeller:propeller /home/propeller/ && chmod -R 0750 /home/propeller/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        locales \
        libxml2-dev libfreetype6-dev \
        libcurl3-openssl-dev \
        libjpeg62-turbo-dev \
        libmcrypt-dev \
        libpng-dev \
        zlib1g-dev \
        libicu-dev\
        libzip-dev \
        libxslt-dev \
        libmcrypt-dev \
        libonig-dev \
        libldap2-dev \
        wget \
        git \
        msmtp \
        sudo \
        ssh-client \
        vim \
        gpg \
        gcc\ 
        g++\
        apt-transport-https \
        libgraphicsmagick1-dev \
        graphicsmagick \
        ghostscript \
        lsb-release \
        libmagickwand-dev \
        imagemagick \
        libmagickcore-dev \
        mailutils \
    && pecl install redis imagick \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        exif \
        sysvmsg \
        sysvsem \
        mysqli \
        soap \
        gd \
        zip \
        opcache \
        intl \
        bcmath \
        sockets \
        xsl \
        ldap \
    && docker-php-ext-enable redis imagick \
    && apt-get clean \
    # keep the runtime libraries the compiled extensions link against (libzip, libxslt, ...);
    # --auto-remove would otherwise drop them together with the -dev packages
    && ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u | xargs -r dpkg-query --search | cut -d: -f1 | sort -u | xargs -r apt-mark manual \
    && apt-get purge -y --auto-remove \
        libxml2-dev \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        zlib1g-dev \
        libicu-dev \
        libzip-dev \
        libxslt1-dev \
        libonig-dev \
        libldap2-dev \
        libmagickwand-dev \
        libmagickcore-dev \
        gcc \
        g++ \
        make \
        autoconf \
        pkg-config \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/src/*

# Allow ImageMagick (and the imagick extension) to read PDF/PostScript via Ghostscript for PDF thumbnails.
# Debian ships the policy under /etc/ImageMagick-6 (bookworm) or /etc/ImageMagick-7 (trixie); the coder
# entries are switched from rights="none" to rights="read|write" instead of deleting lines by position.
RUN set -eu; \
    for policy in /etc/ImageMagick-*/policy.xml; do \
        sed -i -E '/domain="coder"/ { /pattern="[^"]*(PDF|PS|EPS|XPS)[^"]*"/ s/rights="none"/rights="read|write"/; }' "$policy"; \
        if grep 'domain="coder"' "$policy" | grep 'rights="none"' | grep -qE 'pattern="[^"]*(PDF|PS|EPS|XPS)'; then echo "PDF/PS coders still restricted in $policy"; exit 1; fi; \
        echo "ImageMagick policy adjusted: $policy"; \
    done
ADD https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar /bin/wp-cli
RUN chmod +x /bin/wp-cli

# Add propeller Gitlab to known hosts for composer (non-fatal: hosts are unreachable from public CI runners)
RUN (ssh-keyscan -T 5 -H gitlab.propeller.de atum.propeller.de >> /etc/ssh/ssh_known_hosts || true)

# Generate and set Locale; verified because locale-gen silently skips a last line without newline
RUN locale-gen && locale -a | grep -qi "^en_US.utf8$"
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
# Set Timezone
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Validate pool generation and the complete FPM configuration at build time (H6); every compiled extension
# has to load, a missing runtime library would otherwise only show up as a PHP startup warning
RUN PHP_FPM_MAX_CHILDREN=4 entrypoint.sh php-fpm -t && \
    for ext in gd imagick intl ldap redis soap xsl zip mysqli pdo_mysql; do php -m | grep -qix "$ext" || { echo "extension $ext failed to load"; exit 1; }; done && \
    php --ini | grep -q zz-propeller.ini && \
    wp-cli --version --allow-root

EXPOSE 9000

# SIGQUIT is php-fpm's graceful stop; Kubernetes sends it on pod termination (bounded by process_control_timeout)
STOPSIGNAL SIGQUIT

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm"]
