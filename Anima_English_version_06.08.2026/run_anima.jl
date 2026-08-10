using Pkg
Pkg.activate(@__DIR__)
isfile(joinpath(@__DIR__, "Manifest.toml")) || Pkg.instantiate()

# Load .env from either the runtime directory or the repository root.
function load_dotenv!(path::String)
    isfile(path) || return
    for line in eachline(path)
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, '#') && continue
        startswith(stripped, "export ") && (stripped = strip(stripped[8:end]))
        m = match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", stripped)
        isnothing(m) && continue
        key = m.captures[1]
        val = strip(m.captures[2])
        if length(val) >= 2 && ((startswith(val, '"') && endswith(val, '"')) ||
                                (startswith(val, '\'') && endswith(val, '\'')))
            val = val[2:end-1]
        end
        haskey(ENV, key) || (ENV[key] = val)
    end
end

load_dotenv!(joinpath(@__DIR__, ".env"))
load_dotenv!(joinpath(dirname(@__DIR__), ".env"))

function anima_state_path(filename::String)
    dir = strip(get(ENV, "ANIMA_STATE_DIR", @__DIR__))
    isempty(dir) && (dir = @__DIR__)
    dir = isabspath(dir) ? dir : joinpath(@__DIR__, dir)
    isdir(dir) || mkpath(dir)
    joinpath(dir, filename)
end

function anima_memory_path()
    path = strip(get(ENV, "ANIMA_MEMORY_DB", ""))
    isempty(path) && return joinpath(@__DIR__, "memory", "anima.db")
    isabspath(path) ? path : joinpath(@__DIR__, path)
end

include("anima_memory_db.jl")
include("anima_narrative.jl")
include("anima_interface.jl")
include("anima_subjectivity.jl")
include("anima_dream.jl")
include("anima_background.jl")
include("anima_gui_bridge.jl")
include("anima_gui_settings.jl")
include("anima_gui_server.jl")

_ablation = ablation_flags_from_env()
println("  [ABLATION] $(ablation_summary(_ablation))")

anima = Anima(
    core_mem_path = anima_state_path("anima_core.json"),
    psyche_mem_path = anima_state_path("anima_psyche.json"),
    ablation = _ablation,
)
mem   = MemoryDB(anima_memory_path())
subj  = SubjectivityEngine(mem)

# Save state on any exit — including Ctrl+C and terminal close
atexit(() -> begin
    try
        save!(anima)
        close_memory!(mem; sbg = anima.sbg, crisis_mode = string(anima.crisis.current_mode), flash = anima.flash_count)
        println("  [EXIT] State saved.")
    catch e
        @warn "[EXIT] Save error: $e"
    end
end)

repl_with_background!(
    anima;
    mem = mem,
    subj = subj,
    use_llm = true,
    llm_url = get(ENV, "ANIMA_LLM_URL", "https://openrouter.ai/api/v1/chat/completions"),
    llm_model = get(ENV, "ANIMA_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    llm_key = get(ENV, "OPENROUTER_API_KEY", ""),
    use_input_llm = true,
    input_llm_model = get(ENV, "ANIMA_INPUT_LLM_MODEL", get(ENV, "ANIMA_LLM_MODEL", "nvidia/nemotron-3-super-120b-a12b:free")),
    input_llm_key = get(ENV, "OPENROUTER_API_KEY_INPUT", get(ENV, "OPENROUTER_API_KEY", "")),
)
