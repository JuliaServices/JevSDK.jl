# Explicit opt-in: this file makes two billable evaluation requests.
using Test
using JevSDK

const TS = JevSDK

@testset "TypeSafe live API" begin
    client = TS.Client()
    models = TS.list_models(client)
    @test !isempty(models)
    println("Available models: ", join(getfield.(models, :name), ", "))
    result = TS.with_typesafe(client) do
        TS.system_one(;
            state="The message is written in English. The customer says: I was charged twice. Please refund the duplicate payment today.",
            questions=(
                english=TS.Noul(; instructions="Is the message written in English?",
                    criteria=Dict("true"=>"English text", "false"=>"Another language")),
                team=TS.Choice(; instructions="Which team should handle this?",
                    criteria=Dict("billing"=>nothing, "technical"=>nothing, "sales"=>nothing)),
                urgency=TS.Score(; instructions="How urgent is this request?",
                    criteria=["No time constraint", "Needs action soon", "Needs action today"]),
            ))
    end
    @test result.answers["english"] isa TS.NoulAnswer
    @test 0 <= result.answers["english"].noul <= 1
    @test result.answers["english"].noul > 0.5
    @test result.answers["team"] isa TS.ChoiceAnswer
    @test result.answers["team"].choice == "billing"
    @test Set(keys(result.answers["team"].probabilities)) == Set(["billing", "technical", "sales"])
    @test result.answers["urgency"] isa TS.ScoreAnswer
    @test 0 <= result.answers["urgency"].score <= 2
    @test Set(keys(result.answers["urgency"].legend)) == Set(["0", "1", "2"])
    for id in ("team", "urgency")
        answer = result.answers[id]
        @test 0 <= answer.confidence <= 1
        @test all(p -> 0 <= p <= 1, values(answer.probabilities))
        @test sum(values(answer.probabilities)) ≈ 1 atol=0.02
    end
    @test result.usage.input_tokens > 0
    @test result.usage.output_tokens > 0
    println("Mixed request: model=", result.model, ", team=", result.answers["team"].choice,
        ", English probability=", result.answers["english"].noul,
        ", urgency=", result.answers["urgency"].score,
        ", tokens=", result.usage.input_tokens, "/", result.usage.output_tokens)

    structured = TS.system_one(client;
        state=(message="Hello, thanks for your help!", metadata=(source="test", extra=nothing)),
        questions=Dict("tone"=>TS.Choice(; instructions=(question="What is the tone?",),
            criteria=Dict("friendly"=>(description="Polite and positive",), "hostile"=>["Angry and insulting"]))))
    @test structured.answers["tone"].choice == "friendly"
    println("Structured request: tone=", structured.answers["tone"].choice,
        ", tokens=", structured.usage.input_tokens, "/", structured.usage.output_tokens)
end
