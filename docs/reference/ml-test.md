# Test Cluster Architecture

[docs](../index.md) / [reference](./) / Test Cluster Architecture

> **Status: Planned** -- This document describes a design that is not yet implemented. The ml-test cluster type and ml-mcm-agent are proposed for future development.

## Overview

The ml-test cluster type is a proposed third cluster role (alongside tooling and env) designed to run automated integration and performance tests against a Mojaloop App Environment with full DFSP mTLS simulation.

The goal is to validate end-to-end transfer flows where simulated DFSPs connect to the Hub using real mTLS certificates enrolled through the standard MCM onboarding process.

## Concept

- **Dedicated cluster (or namespace)** running simulated DFSPs, isolated from the App Environment
- **Each simulated DFSP** has its own mTLS certificates enrolled via MCM, identical to how a real DFSP would onboard
- **TTK (Testing Toolkit)** runs test cases with real mTLS handshakes through the Hub's DFSP partner edge
- **K6** for performance testing at scale, simulating concurrent DFSP traffic across multiple enrolled participants

The test cluster connects to the App Environment's `gw-extapi` gateway, exercising the full inbound mTLS verification and outbound mTLS origination paths.

## ml-mcm-agent

A proposed sidecar or daemon that automates DFSP certificate enrollment:

- **Create DFSP** -- Calls MCM API to register a new DFSP participant
- **Retrieve certificates** -- Fetches issued certificates from Vault (via MCM's Vault PKI integration)
- **Configure TLS context** -- Writes certificates to a local volume or Kubernetes Secret for TTK/K6 consumption
- **Handle renewal** -- Monitors certificate expiry and triggers re-enrollment before TTL expires

The agent eliminates manual certificate management during test runs, enabling fully automated test pipelines.

## Implementation phases

### Phase 1 (MVP)

- Static certificates, manually enrolled via MCM UI
- TTK test cases configured with pre-provisioned DFSP credentials
- Validates that the mTLS path works end-to-end

### Phase 2: MCM integration

- ml-mcm-agent automates DFSP creation and certificate retrieval
- Test pipelines create ephemeral DFSPs per test run
- Certificates managed automatically, no manual steps

### Phase 3: Scale testing

- K6 load tests with multiple simulated DFSPs
- Concurrent mTLS connections at target throughput
- Performance baselines for the DFSP partner edge

## Current status

Not started. The detailed design, including proposed CRDs and agent architecture, lives in `doc/ml-test-architecture.md`.
