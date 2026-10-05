module JevSDK

using HTTP
using JSON
using ScopedValues

const API_BASE_URL = "https://api.typesafe.ai"
const DEFAULT_MODEL = "jev-latest"
const Content = Union{AbstractString,AbstractDict,NamedTuple,AbstractVector}
const Object = Union{AbstractDict,NamedTuple}

abstract type Question end

"""
    Noul(; instructions, criteria=nothing)

Ask a yes/no question. Optional criteria map `"true"` and `"false"` to descriptions.
"""
@kwarg struct Noul <: Question
    instructions::Content
    criteria::Union{Nothing,Object} = nothing
end

"""
    Choice(; instructions, criteria)

Select a named option. Criteria map labels to text, objects, arrays, or `nothing`.
"""
@kwarg struct Choice <: Question
    instructions::Content
    criteria::Object
end

"""
    Score(; instructions, criteria)

Rate against an ordered vector of at least two descriptions. API levels start at zero.
"""
@kwarg struct Score <: Question
    instructions::Content
    criteria::AbstractVector
end

# Omit only the optional Noul field. Nulls inside state and criteria are meaningful.
JSON.lower(q::Noul) = q.criteria === nothing ?
    (type="noul", instructions=q.instructions) :
    (type="noul", instructions=q.instructions, criteria=q.criteria)
JSON.lower(q::Choice) = (type="choice", instructions=q.instructions, criteria=q.criteria)
JSON.lower(q::Score) = (type="score", instructions=q.instructions, criteria=q.criteria)

"""A state and a dictionary or named tuple of typed questions, evaluated together."""
@kwarg struct SystemOneRequest
    state::Content
    questions::Object
    model::String = DEFAULT_MODEL
end

abstract type Answer end

# Bool is numeric in Julia; reject it before the JSON decoder converts field values.
_reject_boolean(value) = value isa Bool ?
    throw(ArgumentError("Boolean JSON tokens are not valid numeric response values")) : nothing
_numeric_type(type, x) = (_reject_boolean(x[]); type)
function _probabilities_type(x)
    JSON.StructUtils.applyeach(x) do _, value
        _reject_boolean(value[])
    end
    return Dict{String,Float64}
end

"""A yes/no probability in `noul`, from zero to one."""
@tags struct NoulAnswer <: Answer
    noul::Float64 &(choosetype=x -> _numeric_type(Float64, x),)
end

"""The selected label, its confidence, and probabilities for all labels."""
@tags struct ChoiceAnswer <: Answer
    choice::String
    confidence::Float64 &(choosetype=x -> _numeric_type(Float64, x),)
    probabilities::Dict{String,Float64} &(choosetype=_probabilities_type,)
end

"""A weighted score, confidence, and rubric/probabilities keyed by zero-based strings."""
@tags struct ScoreAnswer <: Answer
    score::Float64 &(choosetype=x -> _numeric_type(Float64, x),)
    confidence::Float64 &(choosetype=x -> _numeric_type(Float64, x),)
    probabilities::Dict{String,Float64} &(choosetype=_probabilities_type,)
    legend::Dict{String,Any}
end

function _answer_type(type)
    type == "noul" && return NoulAnswer
    type == "choice" && return ChoiceAnswer
    type == "score" && return ScoreAnswer
    throw(ArgumentError("Unknown TypeSafe answer type: $(repr(type))"))
end
JSON.@choosetype Answer x -> _answer_type(x.type[])

"""Token counts, or `nothing` if the API does not report them."""
@kwarg struct Usage
    input_tokens::Union{Int,Nothing} = nothing &(choosetype=x -> _numeric_type(Union{Int,Nothing}, x),)
    output_tokens::Union{Int,Nothing} = nothing &(choosetype=x -> _numeric_type(Union{Int,Nothing}, x),)
end

"""Typed answers keyed by question ID, with model and token usage."""
struct SystemOneResponse
    model::String
    answers::Dict{String,Answer}
    usage::Usage
end

"""An available model's name, description, and release date."""
struct Model
    name::String
    description::String
    release_date::String
end

struct ListModelsResponse
    models::Vector{Model}
end

"""
    Client(api_key=ENV["TYPESAFE_API_KEY"]; base_url=API_BASE_URL,
           connect_timeout=10, request_timeout=60)

Credentials and request settings. Timeouts are positive seconds. Display hides the key.
"""
struct Client
    api_key::String
    base_url::String
    connect_timeout::Float64
    request_timeout::Float64

    function Client(api_key::AbstractString=get(ENV, "TYPESAFE_API_KEY", "");
                    base_url::AbstractString=API_BASE_URL,
                    connect_timeout::Real=10, request_timeout::Real=60)
        isempty(strip(api_key)) && throw(ArgumentError("Set TYPESAFE_API_KEY or pass an API key"))
        any(iscntrl, api_key) && throw(ArgumentError("API key must not contain control characters"))
        for timeout in (connect_timeout, request_timeout)
            isfinite(timeout) && timeout > 0 || throw(ArgumentError("Timeouts must be positive and finite"))
        end
        new(String(api_key), rstrip(String(base_url), '/'), connect_timeout, request_timeout)
    end
end

Base.show(io::IO, client::Client) = print(io, "JevSDK.Client(\"***\"; base_url=", repr(client.base_url), ")")

const TYPESAFE_CLIENT = ScopedValue{Client}()

"""
    with_typesafe(f, client::Client)
    with_typesafe(f, api_key=ENV["TYPESAFE_API_KEY"]; kwargs...)

Run `f` with task-scoped credentials. Supports `do` blocks, nested scopes, and child tasks.
"""
with_typesafe(f::Function, client::Client) = @with TYPESAFE_CLIENT => client f()
with_typesafe(f::Function, api_key::AbstractString=get(ENV, "TYPESAFE_API_KEY", ""); kwargs...) =
    with_typesafe(f, Client(api_key; kwargs...))

function _get_client()
    isassigned(TYPESAFE_CLIENT) || error("No TypeSafe client set. Use with_typesafe or pass a Client.")
    return TYPESAFE_CLIENT[]
end

"""
An unsuccessful HTTP response. Fields: `status`, `body`, `request_id`, `retry_after`.
The body is retained verbatim; display omits it to avoid logging submitted data.
"""
struct APIError <: Exception
    status::Int
    body::String
    request_id::String
    retry_after::String
end
function Base.showerror(io::IO, err::APIError)
    print(io, "TypeSafe API error (HTTP ", err.status, ")")
    isempty(err.request_id) || print(io, "; request ID: ", err.request_id)
end

function _request(::Type{T}, client::Client, method::String, path::String, body=nothing) where {T}
    response = HTTP.request(method, client.base_url * path,
        ["Authorization" => "Bearer $(client.api_key)", "Content-Type" => "application/json",
         "Accept" => "application/json"];
        body=body === nothing ? "" : JSON.json(body),
        connect_timeout=client.connect_timeout, request_timeout=client.request_timeout,
        retry=false, redirect=false, status_exception=false)
    if !(200 <= response.status < 300)
        throw(APIError(response.status, String(response.body),
            HTTP.header(response, "x-typesafe-request-id"), HTTP.header(response, "Retry-After")))
    end
    return JSON.parse(response.body, T)
end

function _validate(req::SystemOneRequest)
    isempty(strip(req.model)) && throw(ArgumentError("model must not be empty"))
    isempty(req.questions) && throw(ArgumentError("questions must not be empty"))
    for (id, question) in pairs(req.questions)
        id isa Union{AbstractString,Symbol} || throw(ArgumentError("Question IDs must be strings or symbols"))
        question isa Question || throw(ArgumentError("Use Noul, Choice, or Score questions"))
        criteria = question.criteria
        if question isa Choice
            1 <= length(criteria) <= 255 || throw(ArgumentError("Choice requires 1 to 255 options"))
        elseif question isa Score
            length(criteria) >= 2 || throw(ArgumentError("Score requires at least two levels"))
        elseif criteria !== nothing
            all(k -> string(k) in ("true", "false"), keys(criteria)) ||
                throw(ArgumentError("Noul criteria keys must be true or false"))
        end
        if criteria !== nothing
            for value in values(criteria)
                (value isa Content || (question isa Choice && value === nothing)) ||
                    throw(ArgumentError("Criteria descriptions must be text, objects, or arrays; Choice also accepts nothing"))
            end
        end
    end
    return nothing
end

"""
    system_one([client], request::SystemOneRequest) -> SystemOneResponse
    system_one([client]; state, questions, model="jev-latest")

Evaluate questions in one POST to `/v1/systemone`. No automatic retries.
Throws `APIError` on non-2xx responses; HTTP transport errors propagate unchanged.
Boolean JSON tokens in numeric response fields throw `ArgumentError` before conversion.
"""
function system_one(client::Client, request::SystemOneRequest)
    _validate(request)
    return _request(SystemOneResponse, client, "POST", "/v1/systemone", request)
end
system_one(request::SystemOneRequest) = system_one(_get_client(), request)
system_one(client::Client; kwargs...) = system_one(client, SystemOneRequest(; kwargs...))
system_one(; kwargs...) = system_one(_get_client(); kwargs...)

"""List available models with an explicit client or the current scoped client."""
list_models(client::Client=_get_client()) = _request(ListModelsResponse, client, "GET", "/v1/models").models

# Compile the HTTP entry points when installing the package, rather than while
# the first interactive request is waiting. This does not send any requests.
precompile(system_one, (Client, SystemOneRequest))
precompile(list_models, (Client,))

end # module
