FROM postgres:17-alpine

# Install cron
RUN apk add --no-cache dcron dos2unix

# Copy backup script
COPY backup.sh /usr/local/bin/backup.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY crontab /etc/crontabs/root

RUN chmod +x /usr/local/bin/backup.sh &&      \
    dos2unix /usr/local/bin/backup.sh &&      \
    chmod +x /usr/local/bin/healthcheck.sh && \
    dos2unix /usr/local/bin/healthcheck.sh && \
    dos2unix /etc/crontabs/root            && \
    mkdir -p /backups

# Start cron daemon
CMD ["crond", "-f", "-d", "8"]
