# Participant registration via oracle fails with 400 — both single and batch ALS endpoints affected

## Versions

- Mojaloop Helm chart: **17.2** (HelmRelease currently resolves to 17.1.0 — upgrading)
- account-lookup-service: v17.12.2
- als-msisdn-oracle-svc: v0.0.21
- sdk-scheme-adapter (external DFSP): v24.19.3
- sdk-scheme-adapter (internal sims): v24.10.5

## Summary

Registering participants via the MSISDN oracle fails with HTTP 400 on both ALS code paths — the single-participant endpoint (`POST /participants/{Type}/{ID}`) and the batch endpoint (`POST /participants`). The oracle rejects the request body with `errorCode: 3103 — "must NOT have additional properties"`.

The TTK golden path test for participant registration (`Add-part-ALS`) expects this error (`baggage: errorExpect=ALS.1001`), so it passes — but the participant is never actually registered in the oracle. Participants onboarded via the TTK `new_dfsp.json` collection work because that collection registers directly in central-ledger, bypassing the oracle.

The SDK's `POST /accounts` (the only SDK API for participant registration, per the [outbound OpenAPI spec](https://github.com/mojaloop/api-snippets/blob/main/docs/sdk-scheme-adapter-outbound-v2_1_0-openapi3-snippets.yaml)) surfaces this error to the caller since it has no way to bypass the oracle.

## Side-by-side comparison

| Step | Single endpoint (TTK) | Batch endpoint (SDK `POST /accounts`) |
|------|----------------------|--------------------------------------|
| **1. Client request** | `POST /participants/MSISDN/27713803912` body: `{"fspId":"payeefsp","currency":"XXX"}` | `POST /accounts` body: `[{"idType":"MSISDN","idValue":"10100000001","currency":"XXX"}]` |
| **2. ALS receives** | `POST /participants/MSISDN/27713803912` | `POST /participants` (batch) |
| **3. ALS response to caller** | **202 Accepted** (async) | **200 OK** (async) |
| **4. ALS internal handler** | `postParticipants` → `oracleRequest` | `postParticipantsBatch` → `oracleBatchRequest` |
| **5. ALS → Oracle request** | `POST http://moja-als-msisdn-oracle/participants/MSISDN/27713803912` body: `{"fspId":"payeefsp","currency":"XXX"}` | `POST http://moja-als-msisdn-oracle/participants` body: `{"partyList":[{"fspId":"dfsp-101","partyIdType":"MSISDN","partyIdentifier":"10100000001","currency":"XXX"}]}` |
| **6. Oracle response** | **400** — `oracleRequest` fails | **400** — `3103: /requestBody/partyList/0 must NOT have additional properties` |
| **7. ALS callback to DFSP** | `PUT /participants` with `errorCode: 1001` | `PUT /participants` with `errorCode: 1001` |
| **8. Test result** | **Passes** — TTK expects error (`errorExpect=ALS.1001`) | **Fails** — SDK reports error to caller |

## Question

Both ALS code paths fail at the oracle with 400. Is this a known incompatibility between account-lookup-service v17.12.2 and als-msisdn-oracle-svc v0.0.21? Is there a newer oracle version that accepts these payloads, or is the oracle not meant to handle `POST /participants` registration (only `GET` lookups)?
