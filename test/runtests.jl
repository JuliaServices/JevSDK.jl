using Test
using HTTP
using JSON
using JevSDK

const TS = JevSDK

const RESPONSE = """
{"model":"jev-test","answers":{
 "urgent":{"type":"noul","noul":0.95},
 "team":{"type":"choice","choice":"billing","confidence":0.8,
         "probabilities":{"billing":0.9,"other":0.1}},
 "severity":{"type":"score","score":1.6,"confidence":0.78,
             "probabilities":{"0":0.05,"1":0.3,"2":0.65},
             "legend":{"0":"Low","1":{"label":"Medium"},"2":["High"]}}
 },"usage":{"input_tokens":312,"output_tokens":48}}
"""

const QUESTIONS = (
    urgent=TS.Noul(; instructions="Is this urgent?"),
    team=TS.Choice(; instructions=(task="Choose a team",),
        criteria=Dict("billing" => nothing, "other" => ["Everything else"])),
    severity=TS.Score(; instructions=["Rate severity"], criteria=["Low", "Medium", "High"]),
)

@testset "JevSDK" begin
    @test names(JevSDK) == [:JevSDK]
    @testset "Wire types" begin
        request = TS.SystemOneRequest(; state=(message="Refund please", optional=nothing), questions=QUESTIONS)
        wire = JSON.parse(JSON.json(request))
        @test wire["model"] == "jev-latest"
        @test wire["state"]["optional"] === nothing
        @test !haskey(wire["questions"]["urgent"], "criteria")
        @test haskey(wire["questions"]["team"]["criteria"], "billing")
        @test wire["questions"]["team"]["criteria"]["billing"] === nothing
        @test wire["questions"]["team"]["instructions"]["task"] == "Choose a team"
        @test wire["questions"]["severity"]["type"] == "score"
        result = JSON.parse(RESPONSE, TS.SystemOneResponse)
        @test result.answers["urgent"] isa TS.NoulAnswer
        @test result.answers["urgent"].noul == 0.95
        @test result.answers["team"] isa TS.ChoiceAnswer
        @test result.answers["team"].choice == "billing"
        @test result.answers["severity"] isa TS.ScoreAnswer
        @test result.answers["severity"].score == 1.6
        @test result.answers["severity"].legend["1"]["label"] == "Medium"
        @test result.usage.input_tokens == 312
        @test JSON.parse("{}", TS.Usage).input_tokens === nothing
        @test_throws ArgumentError JSON.parse(replace(RESPONSE, "\"noul\"" => "\"unknown\""), TS.SystemOneResponse)
        @test_throws Exception JSON.parse(replace(RESPONSE, "\"noul\":0.95" => "\"missing\":0.95"), TS.SystemOneResponse)
    end

    @testset "Numeric response fields" begin
        numeric_fields = (
            ("urgent", TS.NoulAnswer, ("noul",)),
            ("team", TS.ChoiceAnswer, ("confidence",)),
            ("team", TS.ChoiceAnswer, ("probabilities", "billing")),
            ("severity", TS.ScoreAnswer, ("score",)),
            ("severity", TS.ScoreAnswer, ("confidence",)),
            ("severity", TS.ScoreAnswer, ("probabilities", "0")),
            (nothing, TS.Usage, ("input_tokens",)),
            (nothing, TS.Usage, ("output_tokens",)),
        )
        for value in (false, true, 0, 1), (id, T, path) in numeric_fields
            response = JSON.parse(RESPONSE)
            object = id === nothing ? response["usage"] : response["answers"][id]
            target = length(path) == 1 ? object : object[first(path)]
            target[last(path)] = value
            wire = JSON.json(object)
            if value isa Bool
                @test_throws ArgumentError JSON.parse(wire, T)
                @test_throws ArgumentError JSON.parse(JSON.json(response), TS.SystemOneResponse)
                id === nothing || @test_throws ArgumentError JSON.parse(wire, TS.Answer)
            else
                parsed = JSON.parse(wire, T)
                field = getproperty(parsed, Symbol(first(path)))
                @test (length(path) == 1 ? field : field[last(path)]) == value
            end
        end
        @test_throws ArgumentError JSON.parse(
            raw"""{"type":"choice","choice":"a","confidence":1,"probabilities":{"a":false,"a":1}}""",
            TS.Answer)
        response = JSON.parse(RESPONSE)
        response["answers"]["severity"]["legend"]["0"] = Dict("enabled" => false)
        result = JSON.parse(JSON.json(response), TS.SystemOneResponse)
        @test result.answers["severity"].legend["0"]["enabled"] === false
        request = TS.SystemOneRequest(;
            state=(enabled=true,),
            questions=(q=TS.Choice(; instructions=(enabled=false,),
                criteria=Dict("yes" => Dict("enabled" => true))),))
        wire = JSON.parse(JSON.json(request))
        @test wire["state"]["enabled"] === true
        @test wire["questions"]["q"]["instructions"]["enabled"] === false
        @test wire["questions"]["q"]["criteria"]["yes"]["enabled"] === true
    end

    @testset "Validation and scopes" begin
        @test_throws ArgumentError TS.Client("")
        @test_throws ArgumentError TS.Client("key\ninvalid")
        @test_throws ArgumentError TS.Client("key"; request_timeout=0)
        @test_throws ArgumentError TS.Client("key"; connect_timeout=Inf)
        client = TS.Client("never-print-this")
        @test !occursin("never-print-this", repr(client))
        @test !occursin("never-print-this", sprint(show, MIME"text/plain"(), client))
        @test_throws ErrorException TS.list_models()
        TS.with_typesafe(client) do
            @test TS._get_client() === client
            @test fetch(@async TS._get_client()) === client
            @test_throws ErrorException TS.with_typesafe("inner-key") do
                @test TS._get_client().api_key == "inner-key"
                error("unwind scope")
            end
            @test TS._get_client() === client
        end
        @test_throws ErrorException TS._get_client()
        @test_throws ArgumentError TS.system_one(client; state="x", questions=Dict())
        @test_throws ArgumentError TS.system_one(client; state="x", questions=QUESTIONS, model=" ")
        @test_throws ArgumentError TS.system_one(client; state="x", questions=(bad="raw",))
        @test_throws ArgumentError TS.system_one(client; state="x", questions=(bad=TS.Score(; instructions="?", criteria=["only"]),))
        @test_throws ArgumentError TS.system_one(client; state="x", questions=(bad=TS.Choice(; instructions="?", criteria=Dict()),))
        @test_throws ArgumentError TS.system_one(client; state="x", questions=(bad=TS.Noul(; instructions="?", criteria=Dict("maybe"=>"yes")),))
        @test_throws ArgumentError TS.system_one(client; state="x", questions=(bad=TS.Score(; instructions="?", criteria=[1, 2]),))
    end

    @testset "HTTP contract" begin
        requests = Channel{HTTP.Request}(32)
        status = Ref(200)
        response_body = Ref(RESPONSE)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
            put!(requests, req)
            if status[] != 200
                return HTTP.Response(status[], ["x-typesafe-request-id"=>"test-id", "Retry-After"=>"3",
                    "Location"=>"http://127.0.0.1:1/must-not-follow"], "provider error")
            elseif req.target == "/v1/models"
                return HTTP.Response(200, """{"models":[{"name":"jev-test","description":"Test model","release_date":"2026-09-16"}]}""")
            end
            return HTTP.Response(200, response_body[])
        end
        client = TS.Client("test-key"; base_url="http://$(HTTP.server_addr(server))/")
        try
            models = TS.list_models(client)
            @test only(models).name == "jev-test"
            req = take!(requests)
            @test req.method == "GET"
            @test req.target == "/v1/models"
            @test req.body isa HTTP.EmptyBody
            @test HTTP.header(req, "Authorization") == "Bearer test-key"
            result = TS.with_typesafe(client) do
                TS.system_one(; state=[(text="Please help",)], questions=QUESTIONS)
            end
            @test result.answers["urgent"].noul == 0.95
            req = take!(requests)
            @test req.method == "POST"
            @test req.target == "/v1/systemone"
            @test HTTP.header(req, "Content-Type") == "application/json"
            @test JSON.parse(String(req.body))["state"][1]["text"] == "Please help"
            @test length(JSON.parse(String(req.body))["questions"]) == 3

            @testset "README example" begin
                readme = read(joinpath(@__DIR__, "..", "README.md"), String)
                example = match(r"```julia\r?\n(using JevSDK.*?)\r?\n```"s, readme).captures[1]
                example = replace(example, "JevSDK.Client()" =>
                    "JevSDK.Client(\"test-key\"; base_url=$(repr(client.base_url)))")
                example_module = Module(:ReadmeExample)
                models = Base.include_string(example_module, example, "README.md")
                @test only(models).name == "jev-test"
                @test example_module.result.answers["team"].choice == "billing"
                @test take!(requests).target == "/v1/systemone"
                @test take!(requests).target == "/v1/models"
            end
            response_body[] = replace(RESPONSE,
                "\"noul\":0.95" => "\"noul\":false",
                "jev-test" => "private-fixture-marker")
            err = try
                TS.system_one(client; state="x", questions=QUESTIONS)
            catch ex
                ex
            end
            @test err isa ArgumentError
            @test !occursin("private-fixture-marker", sprint(showerror, err))
            @test take!(requests).target == "/v1/systemone"
            @test !isready(requests)
            response_body[] = RESPONSE
            for code in (401, 422, 429, 529, 302)
                status[] = code
                err = try
                    TS.system_one(client, TS.SystemOneRequest(; state="x", questions=QUESTIONS))
                catch ex
                    ex
                end
                @test err isa TS.APIError
                @test err.status == code
                @test err.body == "provider error"
                @test err.request_id == "test-id"
                @test err.retry_after == "3"
                @test !occursin("test-key", sprint(showerror, err))
                take!(requests)
                @test !isready(requests) # no retries or redirects
            end
        finally
            HTTP.forceclose(server)
            wait(server)
        end
    end
end
