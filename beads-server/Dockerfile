FROM dolthub/dolt-sql-server:latest

# Copy configuration
COPY config.yaml /config.yaml
COPY init-db.sh /init-db.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /init-db.sh /entrypoint.sh

# Data directory for Dolt databases
RUN mkdir -p /var/lib/dolt

# SQL port
EXPOSE 3306
# RemotesAPI port (for push/pull)
EXPOSE 50051

ENTRYPOINT ["/entrypoint.sh"]
