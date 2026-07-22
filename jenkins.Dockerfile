# ─────────────────────────────────────────────────────────────────────────────
#  jenkins.Dockerfile
#
#  WHY a custom image instead of the official one?
#  The official jenkins/jenkins:lts image is a bare Jenkins server.
#  It cannot run 'mvn', 'npm', or 'docker' commands out of the box.
#  We add those three tools here so the pipeline stages can use them.
# ─────────────────────────────────────────────────────────────────────────────

# WHY lts-jdk21? (ROMS built for 17, terra-api for 21), and 21 was chosen as the shared-server compromise
# The 'lts' tag without jdk21 ships with Java 11, which would break the Maven build.
FROM jenkins/jenkins:lts-jdk21

# WHY switch to root?
# Installing system packages (apt-get, curl) requires root privileges.
# The default Jenkins user does not have them.
USER root

# ─── DOCKER CLI ──────────────────────────────────────────────────────────────
# WHY install Docker CLI inside Jenkins?
# Our pipeline runs 'docker build' to package the app into images.
# Jenkins runs inside a Docker container itself, so we mount the HOST's Docker
# socket (/var/run/docker.sock) into it. The Docker CLI here sends commands
# through that socket to the host's Docker daemon — no Docker-in-Docker needed.
#
# WHY only the CLI and not the full Docker engine?
# Installing the full Docker engine inside a container creates a nested daemon,
# which is complex and fragile. The CLI-only approach is lighter and standard.
#
# WHY gosu?
# The docker-entrypoint.sh script must run as root to fix the docker group GID
# at startup (see the entrypoint for the full explanation). gosu is a minimal
# privilege-drop tool that lets the entrypoint run as root, then exec into
# Jenkins as the jenkins user. 'su' is not safe in containers because it forks
# a shell rather than replacing the current process, which breaks signal handling.
RUN apt-get update -y && \
    apt-get install -y ca-certificates curl gnupg lsb-release wget gosu && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
         | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
         https://download.docker.com/linux/debian \
         $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
         | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update -y && \
    apt-get install -y docker-ce-cli docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# ─── MAVEN ───────────────────────────────────────────────────────────────────
# WHY install Maven manually instead of via apt-get?
# The Debian package manager ships Maven 3.6.x, which is outdated.
# Our Spring Boot backend was built with Maven 3.8.x. Using an older version
# risks incompatibility with plugins declared in pom.xml.
# We download the exact same version used in the backend Dockerfile.
ARG MAVEN_VERSION=3.9.6
RUN wget -q \
    https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
    -O /tmp/maven.tar.gz && \
    tar -xzf /tmp/maven.tar.gz -C /opt && \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn && \
    rm /tmp/maven.tar.gz

# ─── NODE.JS 20 ──────────────────────────────────────────────────────────────
# WHY Node 20?
# Our frontend Dockerfile uses 'node:20-alpine'. We match the major version
# so 'npm ci' and 'npm run build' behave identically in Jenkins as in Docker.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ─── DOCKER GROUP (placeholder) ──────────────────────────────────────────────
# WHY create the docker group here but not set the GID?
# We create the group so the image knows the name 'docker' exists.
# The CORRECT GID is assigned at container startup by docker-entrypoint.sh,
# which reads the actual GID from /var/run/docker.sock on the host at runtime.
# Hardcoding a GID here would break on any host where that GID is different.
RUN groupadd -f docker

# ─── ENTRYPOINT SCRIPT ───────────────────────────────────────────────────────
# WHY an entrypoint script instead of just USER jenkins?
# The script runs as root on startup, reads the socket GID, fixes the docker
# group to match, adds jenkins to it, then drops to jenkins via gosu.
# This happens EVERY container start, so it works regardless of host config.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# WHY stay as root (no USER jenkins)?
# The entrypoint needs root to run groupmod/usermod. It immediately drops
# to jenkins via gosu before starting Jenkins itself — root access is
# scoped only to the startup fix, not to the Jenkins process.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]