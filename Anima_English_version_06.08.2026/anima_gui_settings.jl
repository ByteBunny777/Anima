# anima_gui_settings.jl
# Settings from the web interface (language, input/output models & tokens).
# An empty value in each field means "use what came from .env/kwargs" —

const GUI_SETTINGS_PATH = anima_state_path("gui_settings.json")

mutable struct GuiSettings
    language::String
    output_model::String
    output_token::String
    input_model::String
    input_token::String
end

function load_gui_settings()::GuiSettings
    if isfile(GUI_SETTINGS_PATH)
        try
            d = JSON3.read(read(GUI_SETTINGS_PATH, String), Dict{String,Any})
            return GuiSettings(
                String(get(d, "language", "en")),
                String(get(d, "output_model", "")),
                String(get(d, "output_token", "")),
                String(get(d, "input_model", "")),
                String(get(d, "input_token", "")),
            )
        catch
        end
    end
    GuiSettings("en", "", "", "", "")
end

const GUI_SETTINGS = Ref(load_gui_settings())

function gui_settings_to_dict(s::GuiSettings)
    Dict(
        "language" => s.language,
        "output_model" => s.output_model, "output_token" => s.output_token,
        "input_model" => s.input_model, "input_token" => s.input_token,
    )
end

function save_gui_settings!(d::Dict)
    s = GuiSettings(
        String(get(d, "language", GUI_SETTINGS[].language)),
        String(get(d, "output_model", GUI_SETTINGS[].output_model)),
        String(get(d, "output_token", GUI_SETTINGS[].output_token)),
        String(get(d, "input_model", GUI_SETTINGS[].input_model)),
        String(get(d, "input_token", GUI_SETTINGS[].input_token)),
    )
    atomic_write(GUI_SETTINGS_PATH, gui_settings_to_dict(s))
    GUI_SETTINGS[] = s
    s
end
