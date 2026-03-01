# Build stage
FROM golang:1.22-alpine AS builder
ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /workspace

# Copy go module files first for better layer caching.
COPY go.mod go.sum ./
RUN go mod download

# Copy source
COPY api/ api/
COPY cmd/ cmd/
COPY internal/ internal/

# Build the manager binary.
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -a -o manager ./cmd/main.go

# Runtime stage – use distroless for minimal attack surface.
FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /workspace/manager .
USER 65532:65532

ENTRYPOINT ["/manager"]
