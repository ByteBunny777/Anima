# A N I M A  —  Input LLM
#
# The input LLM translates the user's text into a JSON stimulus for the core.
# It does NOT reply to the user. It has NO voice in the dialogue.
#
# If the input LLM is unavailable or confidence < threshold:
#   fallback to text_to_stimulus.

# Requires: HTTP, JSON3 (already available in anima_interface.jl)

# --- Constants ------------------------------------------------------------

const INPUT_LLM_CONFIDENCE_THRESHOLD = 0.60
const INPUT_LLM_MAX_DELTA = 0.7
const INPUT_LLM_TIMEOUT = 15

# --- Async Call ---------------------------------------------------------

function input_llm_async(
    user_msg::String;
    api_url::String = "https://openrouter.ai/api/v1/chat/completions",
    model::String = "openai/gpt-oss-120b:free",
    api_key::String = "",
    prompt_path::String = joinpath(@__DIR__, "llm", "input_prompt.txt"),
)::Channel{Dict{String,Any}}

    ch = Channel{Dict{String,Any}}(1)

    sys_text = try
        read(prompt_path, String)
    catch
        "Return ONLY a JSON with keys: tension, arousal, satisfaction, cohesion, valence, subtext, confidence. Values -1.0 to 1.0."
    end

    messages = [
        Dict("role"=>"system", "content"=>sys_text),
        Dict("role"=>"user", "content"=>user_msg),
    ]

    Threads.@spawn begin
        result = Dict{String,Any}()
        try
            is_ollama = contains(api_url, "11434") || contains(api_url, "ollama")
            headers = ["Content-Type"=>"application/json"]
            !isempty(api_key) && push!(headers, "Authorization"=>"Bearer $api_key")

            body =
                is_ollama ?
                JSON3.write(
                    Dict(
                        "model"=>model,
                        "messages"=>messages,
                        "stream"=>false,
                        "format"=>"json",
                    ),
                ) :
                JSON3.write(
                    Dict(
                        "model"=>model,
                        "messages"=>messages,
                        "max_tokens"=>200,
                        "response_format"=>Dict("type"=>"json_object"),
                    ),
                )

            resp = HTTP.post(api_url, headers, body; readtimeout = INPUT_LLM_TIMEOUT)
            text =
                is_ollama ? String(resp.body |> JSON3.read |> x->x["message"]["content"]) :
                String(resp.body |> JSON3.read |> x->x["choices"][1]["message"]["content"])
            clean = replace(text, r"```json|```" => "")
            parsed = JSON3.read(clean)
            result = Dict{String,Any}(String(k)=>v for (k, v) in parsed)
        catch e
            @debug "input_llm error: $e"
        finally
            put!(ch, result)
        end
    end

    ch
end

# --- Validation and Normalization --------------------------------------------

function validate_input_signal(raw::Dict{String,Any})::Dict{String,Float64}
    isempty(raw) && return Dict{String,Float64}()

    conf = get(raw, "confidence", 0.0)
    try
        conf = Float64(conf)
    catch
        ;
        return Dict{String,Float64}()
    end
    conf < INPUT_LLM_CONFIDENCE_THRESHOLD && return Dict{String,Float64}()

    result = Dict{String,Float64}()
    signal_keys = ("tension", "arousal", "satisfaction", "cohesion")

    for k in signal_keys
        !haskey(raw, k) && return Dict{String,Float64}()
        v = try
            Float64(raw[k])
        catch
            ;
            return Dict{String,Float64}()
        end
        (isnan(v) || isinf(v)) && return Dict{String,Float64}()
        result[k] = clamp(v, -INPUT_LLM_MAX_DELTA, INPUT_LLM_MAX_DELTA)
    end

    result
end

# --- Main Function -------------------------------------------------------

function process_input(
    user_msg::String,
    text_to_stimulus_fn;
    input_model::String = "openai/gpt-oss-120b:free",
    api_url::String = "https://openrouter.ai/api/v1/chat/completions",
    api_key::String = "",
    prompt_path::String = joinpath(@__DIR__, "llm", "input_prompt.txt"),
)::Tuple{Dict{String,Float64},String,String}

    fallback_stim = text_to_stimulus_fn(user_msg)

    (isempty(api_key) || isempty(strip(user_msg))) && return (fallback_stim, "fallback", "")

    ch = input_llm_async(
        user_msg;
        api_url = api_url,
        model = input_model,
        api_key = api_key,
        prompt_path = prompt_path,
    )

    raw = Dict{String,Any}()
    try
        raw = take!(ch)
    catch
    end

    validated = validate_input_signal(raw)
    isempty(validated) && return (fallback_stim, "fallback", "")

    want = String(get(raw, "want", ""))
    (validated, "llm", want)
end

# --- Snapshot for the Log ----------------------------------------------------

input_source_label(source::String) = source == "llm" ? "🧠" : "📝"
