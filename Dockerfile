FROM php:8.4-apache
LABEL maintainer="Philipp Dippel <philipp.dippel@propeller.de>"
SHELL ["/bin/bash", "-c"]

RUN addgroup --gid 1000 propeller && useradd --system -u 1000 -g propeller propeller 

ENV PROVISION_CONTEXT="production"
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin
ENV APACHE_LOCK_DIR=/var/lock/apache2
ENV APACHE_LOG_DIR=/var/log/apache2
ENV APACHE_PID_FILE=/var/run/apache2/apache2.pid
ENV APACHE_SERVER_NAME=localhost
ENV APACHE_RUN_USER=propeller
ENV APACHE_RUN_GROUP=propeller
ENV APACHE_RUN_DIR=/var/run/apache2
ENV DOCUMENT_ROOT=/var/www/html
ENV LETSENCRYPT_EMAIL=certbot@propeller.de
ENV PORT=80
# Apache runtime tuning (K1, K2, H4). An empty APACHE_MAX_REQUEST_WORKERS lets entrypoint.sh derive the
# value from the container memory limit: floor((limit_MiB - BASELINE_MB) / CHILD_MB)
ENV APACHE_MAX_REQUEST_WORKERS="" \
    APACHE_CHILD_MEMORY_MB=100 \
    APACHE_BASELINE_MEMORY_MB=256 \
    APACHE_MIN_SPARE_SERVERS=2 \
    APACHE_MAX_SPARE_SERVERS=4 \
    APACHE_MAX_CONNECTIONS_PER_CHILD=1000 \
    APACHE_TIMEOUT=120 \
    APACHE_ALLOW_OVERRIDE=All

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
COPY ./config/000-default.conf /etc/apache2/sites-available/000-default.conf
COPY ./config/apache2.conf /etc/apache2/apache2.conf
COPY ./config/mpm_prefork.conf /etc/apache2/mods-available/mpm_prefork.conf
COPY ./config/locale.gen /etc/locale.gen

COPY ./scripts/*.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

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
    && a2enmod rewrite deflate headers mime expires filter setenvif env authz_core auth_basic alias \
    && echo "export PATH=":$PATH"" \
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
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 

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

# Generate and set Locale
RUN locale-gen
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
# Set Timezone
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Logs go straight to the container streams (see apache2.conf). The Debian default would log every
# request a second time into other_vhosts_access.log (H5)
RUN rm -f /etc/apache2/conf-enabled/other-vhosts-access-log.conf

# Static health endpoint for Kubernetes probes (H3) and drop-in directory for per-site Apache rules (K2)
RUN mkdir -p /opt/propeller/healthz /etc/apache2/site.d && echo ok > /opt/propeller/healthz/index.html

RUN rm /usr/src/*

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Validate the complete configuration at build time without starting a daemon (H6)
RUN APACHE_MAX_REQUEST_WORKERS=8 apache2ctl -t

# Every compiled extension has to load; a missing runtime library would otherwise only show up as a PHP startup warning
RUN for ext in gd imagick intl ldap redis soap xsl zip; do php -m | grep -qix "$ext" || { echo "extension $ext failed to load"; exit 1; }; done

EXPOSE $PORT

ENTRYPOINT ["entrypoint.sh"]
