# Changelog

## Unreleased

- Reject Boolean JSON tokens in numeric answer and token-count fields before conversion.
  Numeric zero and one remain valid; Boolean state, criteria, and metadata remain unchanged.

## 1.0.0

Initial public release of JevSDK.jl, based on the local TypeSafeAI prototype.

- Typed Choice, Score, and Noul requests and answers for the System One API.
- Model discovery, task-scoped clients, configurable timeouts, and typed API errors.
- Credentials hidden in client display; no automatic retries or redirects.
- Offline HTTP tests and Julia 1.10 or later support, with ScopedValues 1.6.2 or later.

The package retains the prototype UUID and the provider's `TYPESAFE_API_KEY`
environment variable and `with_typesafe` helper. Import the package as `JevSDK`.
