# anima_gui_server.jl
# HTTP server (via the already-available HTTP.jl) for the full web interface:
# - GET  /            — anima_console.html
# - GET  /api/state    — current gui_state.json
# - GET  /api/events   — gui_events.jsonl, ?since=N (N — how many lines the client already has)
# - GET  /api/chat      — gui_chat.jsonl, same ?since=N
# - POST /api/send      — {"text": "..."} → puts into input_queue, same channel as the terminal
# - GET  /api/history   — persistent trend history (causal_trace + audit_log), ?n=N

function gui_jsonl_since(path::String, since::Int)
    lock(GUI_JSONL_LOCK) do
        lines = isfile(path) ? readlines(path) : String[]
        start = clamp(since + 1, 1, length(lines) + 1)
        items = String[]
        for (idx, line) in enumerate(lines[start:end])
            row = strip(line)
            try
                JSON3.read(row)
                push!(items, row)
            catch
                push!(
                    items,
                    JSON3.write(Dict(
                        "kind" => "jsonl_error",
                        "line" => start + idx - 1,
                    )),
                )
            end
        end
        "[" * join(items, ",") * "]"
    end
end

function gui_query_since(req)
    try
        uri = HTTP.URI(req.target)
        q = HTTP.queryparams(uri)
        parse(Int, get(q, "since", "0"))
    catch
        0
    end
end

function start_gui_server!(input_queue::Channel{String}; port::Int = 8088, dir::String = @__DIR__)
    router = HTTP.Router()

    HTTP.register!(router, "GET", "/", req -> begin
        html_path = joinpath(dir, "anima_console.html")
        if isfile(html_path)
            HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], read(html_path))
        else
            HTTP.Response(404, "anima_console.html not found in $(dir)")
        end
    end)

    HTTP.register!(router, "GET", "/api/state", req -> begin
        body = isfile(GUI_STATE_PATH) ? read(GUI_STATE_PATH) : "{}"
        HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end)

    HTTP.register!(router, "GET", "/api/events", req -> begin
        body = gui_jsonl_since(GUI_EVENTS_PATH, gui_query_since(req))
        HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end)

    HTTP.register!(router, "GET", "/api/chat", req -> begin
        body = gui_jsonl_since(GUI_CHAT_PATH, gui_query_since(req))
        HTTP.Response(200, ["Content-Type" => "application/json"], body)
    end)

    HTTP.register!(router, "POST", "/api/send", req -> begin
        try
            payload = JSON3.read(String(req.body))
            text = String(get(payload, "text", ""))
            isempty(strip(text)) || put!(input_queue, text)
            HTTP.Response(200, ["Content-Type" => "application/json"], "{\"ok\":true}")
        catch e
            HTTP.Response(400, ["Content-Type" => "application/json"], "{\"ok\":false,\"error\":\"$(e)\"}")
        end
    end)

    HTTP.register!(router, "GET", "/api/live", req -> begin
        a = _GUI_ANIMA[]
        if isnothing(a)
            return HTTP.Response(503, ["Content-Type" => "application/json"], "{\"error\":\"not ready\"}")
        end
        try
            state = gui_live_state(a)
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(state))
        catch e
            HTTP.Response(500, ["Content-Type" => "application/json"],
                JSON3.write(Dict("error" => sprint(showerror, e))))
        end
    end)

    # Trends over time: persistent history (survives a console/server restart).
    # ?n= — how many recent flashes-with-reply to return (default 200).
    HTTP.register!(router, "GET", "/api/history", req -> begin
        mem = _GUI_MEM[]
        if isnothing(mem)
            return HTTP.Response(503, ["Content-Type" => "application/json"], "{\"error\":\"mem not ready\"}")
        end
        try
            uri = HTTP.URI(req.target)
            q = HTTP.queryparams(uri)
            n = try parse(Int, get(q, "n", "200")) catch; 200 end
            ct = causal_trace_history(mem.db; n = n)
            au = audit_score_history(mem.db; n = n)
            body = JSON3.write(Dict(
                "causal_trace" => ct,
                "audit_log" => au,
            ))
            HTTP.Response(200, ["Content-Type" => "application/json"], body)
        catch e
            HTTP.Response(500, ["Content-Type" => "application/json"],
                JSON3.write(Dict("error" => sprint(showerror, e))))
        end
    end)

    HTTP.register!(router, "POST", "/api/cmd", req -> begin
        try
            payload = JSON3.read(String(req.body))
            cmd = String(get(payload, "cmd", ""))
            if isempty(strip(cmd))
                return HTTP.Response(400, ["Content-Type" => "application/json"], "{\"ok\":false,\"error\":\"empty cmd\"}")
            end
            result = execute_gui_cmd(cmd)
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], result)
        catch e
            HTTP.Response(500, ["Content-Type" => "application/json"], "{\"ok\":false,\"error\":\"$(e)\"}")
        end
    end)

    HTTP.register!(router, "GET", "/api/settings", req -> begin
        HTTP.Response(200, ["Content-Type" => "application/json"],
            JSON3.write(gui_settings_to_dict(GUI_SETTINGS[])))
    end)

    HTTP.register!(router, "POST", "/api/settings", req -> begin
        try
            payload = JSON3.read(String(req.body), Dict{String,Any})
            s = save_gui_settings!(payload)
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(gui_settings_to_dict(s)))
        catch e
            HTTP.Response(400, ["Content-Type" => "application/json"], "{\"ok\":false,\"error\":\"$(e)\"}")
        end
    end)

    HTTP.serve!(router, "127.0.0.1", port; verbose = false)
end
