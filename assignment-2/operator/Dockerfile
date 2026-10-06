# Multi-stage build: compile the operator binary, then ship it in a minimal
# non-root runtime image (same "provided build context" pattern Assignment
# 1 used for the app's three images).
FROM golang:1.26-alpine AS builder
WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download
COPY api/ api/
COPY controllers/ controllers/
COPY cmd/ cmd/
RUN CGO_ENABLED=0 GOOS=linux go build -o /manager ./cmd

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=builder /manager .
USER 65532:65532
ENTRYPOINT ["/manager"]
