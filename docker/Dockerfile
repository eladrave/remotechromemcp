FROM node:22-bookworm-slim

ARG PLAYWRIGHT_MCP_VERSION=0.0.78

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      jq \
      supervisor \
      xvfb \
      openbox \
      x11vnc \
      novnc \
      websockify \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg \
    && printf '%s\n' \
      'deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main' \
      > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

RUN test -n "$PLAYWRIGHT_MCP_VERSION" \
    && npm install -g "@playwright/mcp=${PLAYWRIGHT_MCP_VERSION}" \
    && groupadd --system remote-chrome \
    && useradd --system --gid remote-chrome --create-home \
      --home-dir /home/remote-chrome remote-chrome \
    && install -d -o remote-chrome -g remote-chrome \
      /data/chrome-profile /run/remote-chrome /opt/remote-chrome \
    && ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

COPY --chown=remote-chrome:remote-chrome browser-playbook.md /opt/remote-chrome/browser-playbook.md
COPY --chown=remote-chrome:remote-chrome lib/inject-instructions.cjs /opt/remote-chrome/inject-instructions.cjs
COPY --chown=remote-chrome:remote-chrome docker/entrypoint.sh /opt/remote-chrome/entrypoint.sh
COPY --chown=remote-chrome:remote-chrome docker/healthcheck.sh /opt/remote-chrome/healthcheck.sh
COPY --chown=remote-chrome:remote-chrome docker/supervisord.conf /opt/remote-chrome/supervisord.conf

RUN chmod 0755 /opt/remote-chrome/entrypoint.sh /opt/remote-chrome/healthcheck.sh

ENV REMOTE_CHROME_PLAYBOOK=/opt/remote-chrome/browser-playbook.md

USER remote-chrome
WORKDIR /home/remote-chrome

ENTRYPOINT ["/opt/remote-chrome/entrypoint.sh"]
