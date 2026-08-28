# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/powershell:latest

ARG SALMON_RUN_VERSION=0.1.3

LABEL org.opencontainers.image.title="salmon-run" \
      org.opencontainers.image.description="File-based Kanban control plane with pond dispatch and model routing" \
      org.opencontainers.image.version="${SALMON_RUN_VERSION}" \
      org.opencontainers.image.source="https://github.com/victorsalmon/salmon-run" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Salmon Run"

WORKDIR /salmon-run

# Copy the package into the image. The source repo contains no credentials,
# queue state, or private hostnames; runtime state lives in ~/.salmon.
COPY . /salmon-run/

# Install modules to a persistent location and validate the PondEngine loads.
# The image entry point is the public Start-SalmonRun.ps1 script.
RUN pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File /salmon-run/install.ps1

ENV SALMON_RUN_HOME=/salmon-home
VOLUME ["/salmon-home"]

ENTRYPOINT ["pwsh", "-NoProfile", "-NonInteractive", "-Command", "/salmon-run/Start-SalmonRun.ps1"]
CMD ["-DryRun"]
