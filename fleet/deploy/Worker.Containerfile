ARG NODE_BASE
FROM ${NODE_BASE}
ARG CODEX_VERSION
ARG CLAUDE_VERSION
RUN test -n "$CODEX_VERSION" && test -n "$CLAUDE_VERSION" \
 && sed -i 's|http://deb.debian.org|https://deb.debian.org|g; s|http://security.debian.org|https://security.debian.org|g' /etc/apt/sources.list.d/*.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends python3 git ca-certificates build-essential \
 && npm install --ignore-scripts --global "@openai/codex@${CODEX_VERSION}" "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
 && codex --version && claude --version \
 && rm -rf /var/lib/apt/lists/* /root/.npm
WORKDIR /work
