# Build stage – uses locally pre-built binary (go build -o manager ./cmd/main.go)
# To build inside Docker, replace this with a golang:1.25-alpine multi-stage build.
FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY manager .
USER 65532:65532

ENTRYPOINT ["/manager"]
