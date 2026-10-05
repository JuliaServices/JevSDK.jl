# JevSDK.jl

A Julia SDK for Jev and the [TypeSafe AI API](https://docs.typesafe.ai/api).
Supports Choice, Score, and Noul questions, typed answers, and model discovery.
This community package is maintained by JuliaServices.
All APIs use the `JevSDK` namespace. Nothing is exported.

## Installation

Requires Julia 1.10 or later. While the initial General registration is pending:

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaServices/JevSDK.jl", rev="v1.0.0")
```

After registration, install with:

```julia
Pkg.add("JevSDK")
```

Set `TYPESAFE_API_KEY` in your process environment. The package does not load `.env` files.

## Ask several questions

```julia
using JevSDK

client = JevSDK.Client() # reads TYPESAFE_API_KEY
result = JevSDK.system_one(client;
    state="I was charged twice. Please fix this today.",
    questions=(
        urgent=JevSDK.Noul(; instructions="Is this time-sensitive?"),
        team=JevSDK.Choice(;
            instructions="Which team should handle this?",
            criteria=Dict("billing"=>nothing, "technical"=>nothing, "sales"=>nothing)),
        severity=JevSDK.Score(;
            instructions="How severe is this issue?",
            criteria=["Minor", "Disruptive", "Blocking"]),
    ))

result.answers["urgent"].noul
result.answers["team"].choice
result.answers["team"].probabilities
result.answers["severity"].score
result.answers["severity"].confidence
result.usage.input_tokens
JevSDK.list_models(client)
```

`model` defaults to `"jev-latest"`. Set it per request to use a different model.
Score levels start at **zero**, as in the HTTP API. Scores can fall between levels.
Score `legend` and `probabilities` keep the API's string keys (`"0"`, `"1"`, ...).

## Scoped credentials

```julia
JevSDK.with_typesafe(client) do
    JevSDK.system_one(;
        state="The delivery arrived.",
        questions=Dict("delivered" => JevSDK.Noul(; instructions="Has delivery occurred?")))
end
```

`with_typesafe` also accepts a `Client`. Nested scopes restore the previous client,
including when a call throws. Child tasks inherit the current scope.
Without a scope, pass the client explicitly.
The helper and environment variable retain the provider's TypeSafe name.

Use `SystemOneRequest(; state, questions, model)` when you want to keep a request object.
State and instructions accept strings, dictionaries, named tuples, or vectors.
Choice descriptions accept those forms plus `nothing`. Score descriptions accept
text, objects, or arrays. Noul optionally accepts `criteria=Dict("true"=>"...", "false"=>"...")`.
Nulls inside your state and criteria are preserved.

## Errors and timeouts

```julia
client = JevSDK.Client(; connect_timeout=10, request_timeout=60)
```

Timeouts are positive seconds. Requests do not follow redirects or retry automatically.
On a non-2xx response, `JevSDK.APIError` retains `status`, raw response `body`,
`request_id`, and `retry_after`. This includes authentication failures (401), validation
errors (422), rate limits (429), and overload (529). The caller can use those fields
to implement backoff. HTTP transport errors propagate unchanged.
Boolean JSON tokens in numeric answer or token-count fields raise `ArgumentError`.

Client display hides the API key. Error display omits response bodies; inspect
`err.body` explicitly when needed. Never log client fields or authorization headers.
Only send state that you intend to share with the configured API provider.

## Tests

The default suite uses a local HTTP server and needs no API key:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

The separate live check lists models and makes **two billable evaluation requests**.
Run it only with a test key in `TYPESAFE_API_KEY`:

```sh
julia --project=. test/live.jl
```

It checks all three question types, mixed batches, null Choice options, structured
state/instructions/criteria, probabilities, and token usage. Live model decisions
can vary. No credential is stored in the package.

## License and development

MIT licensed. Codex assisted with the Julia wrapper, tests, documentation, and
release preparation.
