#!/bin/bash
# WHY this file exists:
# The Docker socket (/var/run/docker.sock) is mounted from the HOST.
# The jenkins user needs to be in the same group as the socket owner to run docker commands.
# The socket's group ID varies by host OS and Docker Desktop version.
#
# On Linux servers: socket is typically owned by a 'docker' group (GID ~998)
# On Docker Desktop for Windows/Mac: socket is owned by root (GID 0)
#
# FIX: at startup, read the socket's actual GID. If it's 0 (root), add jenkins
# to the root group. Otherwise, align the container's docker group GID to match
# the socket and add jenkins to it. This works on any host.

if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

    if [ "$DOCKER_GID" = "0" ]; then
        # Docker Desktop (Windows/Mac): socket owned by root.
        # Can't reassign GID 0 — it belongs to the root group already.
        # Instead, add jenkins to the root group to grant socket access.
        usermod -aG root jenkins
    else
        # Linux server: socket owned by a dedicated docker group.
        # Align the container's docker group GID to match the host's socket GID.
        if getent group docker > /dev/null 2>&1; then
            CURRENT_GID=$(getent group docker | cut -d: -f3)
            if [ "$CURRENT_GID" != "$DOCKER_GID" ]; then
                groupmod -g "$DOCKER_GID" docker
            fi
        else
            groupadd -g "$DOCKER_GID" docker
        fi
        usermod -aG docker jenkins
    fi
fi

# Drop from root to the jenkins user and start Jenkins normally.
# gosu replaces the current process (exec) rather than forking — preserves signal handling.
exec gosu jenkins /usr/bin/tini -- /usr/local/bin/jenkins.sh "$@"
