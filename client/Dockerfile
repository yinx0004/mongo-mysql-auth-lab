# Client box: mongosh (from the mongo image) plus the mysql command-line client.
FROM mongo:8.0.4
RUN apt-get update \
 && apt-get install -y --no-install-recommends mysql-client \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["sleep", "infinity"]
