# ============================================================================
# A N I M A — Learning (anima_learning.jl)
#
# Власна внутрішня мовна модель ANIMA. Малий decoder-only Transformer,
# byte-level (без словника, що росте) — вчиться безперервно, щофлешу,
# на власному досвіді: парі (user_message, llm_reply) поточного флешу.
#
# Ключовий принцип з дизайн-документа (мініЛЛМ.txt): ваги — НЕ пам'ять.
# SQLite (causal_trace.llm_reply) зберігає сирий досвід. models/anima_inner/
# зберігає лише те, що з цього досвіду узагальнилось. Видалити ваги й
# перетренувати з нуля на тій самій історії — свідомо можливий і легкий
# контрольний експеримент (просто видали models/anima_inner/, InnerLM
# ініціалізується заново при наступному запуску).
#
# Перевірено на живому лозі (флеші 456-457, 24.08.2026): [LM] loss=5.613→5.41,
# без падінь. Два реальні багі знайдено й виправлено в процесі — обидва
# одного класу (in-place мутація масиву всередині forward-проходу, який
# диференціює Zygote): цикл `out[:,h,:,b] = ...` в attention (замінено на
# NNlib.batched_mul) і типізована comprehension для causal-маски (замінено
# на маску, пораховану один раз у конструкторі й лише читану у forward).
# `@functor` замінено на сучасний, не-deprecated `Flux.@layer ... trainable=(...)`.
# ============================================================================

using Flux
using Flux.Losses: logitcrossentropy
using BSON
using Random
using JSON3
using Statistics

# --- GPU (за наявності) ------------------------------------------------------
# `using CUDA`+`using cuDNN` — у try/catch: якщо пакет ще не додано
# (`] add CUDA`, `] add cuDNN`) або драйвер несумісний, InnerLM просто
# тренується на CPU, як і раніше. Обидва потрібні РАЗОМ: сам `Flux.gpu()`
# усередині йде через MLDataDevices.jl, а той визнає NVIDIA-бекенд
# "робочим" лише коли завантажені (не просто встановлені — саме `using`)
# і CUDA, і cuDNN одразу; з самою лише CUDA `CUDA.functional()` каже
# правду ("є"), а `MLDataDevices`/`gpu()` мовчки все одно падає на CPU —
# це реально трапилось на живому запуску (25.08.2026), лог брехав.
# Функціональність GPU перевіряється РАЗ, при завантаженні файлу.
const _LM_HAS_CUDA = try
    using CUDA
    using cuDNN
    CUDA.functional()
catch e
    @warn "[LM] CUDA/cuDNN недоступні — внутрішня модель тренуватиметься на CPU" exception=e
    false
end
if _LM_HAS_CUDA
    println("  [LM] GPU виявлено: $(CUDA.name(CUDA.device())). Внутрішня модель тренуватиметься на GPU.")
else
    println("  [LM] GPU не використовується — тренування на CPU.")
end

# Переносить модель/тензор на GPU, якщо є; інакше — без змін (no-op).
_to_device(x) = _LM_HAS_CUDA ? gpu(x) : x

const LM_VOCAB_SIZE = 256   # byte-level: кожен байт UTF-8 — токен; словник фіксований назавжди, ніколи не росте і не потребує переробки

# --- Конфігурація архітектури ----------------------------------------------

struct LMConfig
    d_model::Int
    n_layer::Int
    n_head::Int
    d_ff::Int
    block_size::Int
end
LMConfig(; d_model::Int=384, n_layer::Int=6, n_head::Int=6, d_ff::Int=1536, block_size::Int=512) =
    LMConfig(d_model, n_layer, n_head, d_ff, block_size)

lmconfig_to_dict(c::LMConfig) = Dict(
    "d_model" => c.d_model, "n_layer" => c.n_layer, "n_head" => c.n_head,
    "d_ff" => c.d_ff, "block_size" => c.block_size, "vocab_size" => LM_VOCAB_SIZE,
)
lmconfig_from_dict(d) = LMConfig(
    d_model    = Int(get(d, "d_model", 384)),
    n_layer    = Int(get(d, "n_layer", 6)),
    n_head     = Int(get(d, "n_head", 6)),
    d_ff       = Int(get(d, "d_ff", 1536)),
    block_size = Int(get(d, "block_size", 512)),
)

# --- Byte-level "токенізатор" -----------------------------------------------
# Немає зростаючого словника: кожен байт рядка (UTF-8) — токен 1..256
# (Flux/Julia індексують з 1). Українська, англійська, розділові знаки,
# емодзі — все просто послідовність байтів. Кодек ніколи не потребує
# переробки, скільки б нових символів не з'явилось у майбутньому.

encode_bytes(s::AbstractString)::Vector{Int} = Int.(Vector{UInt8}(s)) .+ 1
decode_bytes(ids::AbstractVector{<:Integer})::String =
    String(UInt8.(clamp.(ids .- 1, 0, 255)))

# --- Допоміжне: застосувати Dense до (features, T, B), не покладаючись ------
# на те, підтримує чи ні конкретна версія Flux ND-input для Dense напряму.

function _dense3d(d::Dense, x::AbstractArray{<:Real,3})
    din, T, B = size(x)
    y2 = d(reshape(x, din, T * B))
    reshape(y2, size(y2, 1), T, B)
end

# --- Causal self-attention (написано вручну — Flux не має transformer- ------
# блоку "з коробки") -----------------------------------------------------

mutable struct CausalSelfAttention
    n_head::Int
    d_head::Int
    Wq::Dense
    Wk::Dense
    Wv::Dense
    Wo::Dense
    causal_mask::AbstractMatrix{Float32}  # (block_size, block_size), рахується ОДИН РАЗ при створенні — константа, не вага; forward лише читає зріз [1:T,1:T]. AbstractMatrix (не конкретний Matrix) навмисно: gpu(model) підміняє це на CuMatrix, конкретний тип відхилив би реконструкцію
end

# mask[i,j] = 0, якщо ключ j дозволений запиту i (j <= i, тобто минуле/теперішнє);
# -1e10, якщо j > i (майбутнє) — після softmax це занулює вагу.
# Винесено в окрему функцію й рахується ЗАЗДАЛЕГІДЬ (не у forward!), бо
# array comprehension всередині себе мутує масив через setindex! — а це
# саме те, чого Zygote не диференціює. Друге місце того самого класу бага,
# що й у attention-циклі раніше.
_build_causal_mask(block_size::Int)::Matrix{Float32} =
    Float32[j <= i ? 0f0 : -1f10 for i in 1:block_size, j in 1:block_size]

function CausalSelfAttention(d_model::Int, n_head::Int, block_size::Int)
    @assert d_model % n_head == 0 "d_model має ділитись на n_head без остачі"
    d_head = d_model ÷ n_head
    CausalSelfAttention(
        n_head, d_head,
        Dense(d_model, d_model; bias=false),
        Dense(d_model, d_model; bias=false),
        Dense(d_model, d_model; bias=false),
        Dense(d_model, d_model; bias=false),
        _build_causal_mask(block_size),
    )
end
Flux.@layer CausalSelfAttention trainable=(Wq, Wk, Wv, Wo)

# x: (d_model, T, B) → (d_model, T, B)
function (attn::CausalSelfAttention)(x::AbstractArray{<:Real,3})
    d_model, T, B = size(x)
    nh, dh = attn.n_head, attn.d_head

    q = _dense3d(attn.Wq, x)
    k = _dense3d(attn.Wk, x)
    v = _dense3d(attn.Wv, x)

    # (d_model,T,B) → (dh,nh,T,B) → (dh,T,nh,B) → (dh,T,nh*B): пакуємо
    # "голову" разом із батчем, щоб порахувати всі голови й приклади одним
    # батчованим матричним множенням — БЕЗ ручного циклу і БЕЗ мутації
    # масиву (Zygote не диференціює через in-place setindex!, а старий
    # варіант з `out[:, h, :, b] = ...` у циклі саме це й робив — це і
    # падало на першому ж навчальному кроці).
    q4 = reshape(q, dh, nh, T, B)
    k4 = reshape(k, dh, nh, T, B)
    v4 = reshape(v, dh, nh, T, B)

    qp = reshape(permutedims(q4, (1, 3, 2, 4)), dh, T, nh * B)
    kp = reshape(permutedims(k4, (1, 3, 2, 4)), dh, T, nh * B)
    vp = reshape(permutedims(v4, (1, 3, 2, 4)), dh, T, nh * B)

    scale = Float32(1.0 / sqrt(dh))
    mask = @view attn.causal_mask[1:T, 1:T]  # лише читання зрізу — без мутації

    scores = Flux.NNlib.batched_mul(Flux.NNlib.batched_transpose(qp), kp)  # (T, T, nh*B)
    scores = scores .* scale .+ mask
    weights = Flux.softmax(scores; dims=2)                                  # ймовірності по ключах (j) для кожного запиту

    out = Flux.NNlib.batched_mul(vp, Flux.NNlib.batched_transpose(weights)) # (dh, T, nh*B)

    out4 = permutedims(reshape(out, dh, T, nh, B), (1, 3, 2, 4))  # (dh, nh, T, B)
    out3 = reshape(out4, d_model, T, B)
    _dense3d(attn.Wo, out3)
end

# --- Transformer-блок: attention + feed-forward, з residual та pre-LN -------

mutable struct TransformerBlock
    attn::CausalSelfAttention
    ln1::LayerNorm
    ff1::Dense
    ff2::Dense
    ln2::LayerNorm
end
function TransformerBlock(d_model::Int, n_head::Int, d_ff::Int, block_size::Int)
    TransformerBlock(
        CausalSelfAttention(d_model, n_head, block_size),
        LayerNorm(d_model),
        Dense(d_model, d_ff, gelu),
        Dense(d_ff, d_model),
        LayerNorm(d_model),
    )
end
Flux.@layer TransformerBlock

function (blk::TransformerBlock)(x::AbstractArray{<:Real,3})
    x = x .+ blk.attn(blk.ln1(x))
    h = _dense3d(blk.ff1, blk.ln2(x))
    h = _dense3d(blk.ff2, h)
    x .+ h
end

# --- TinyTransformer: повна модель ------------------------------------------
# pos_emb і cfg свідомо ВИКЛЮЧЕНІ з trainable= нижче: pos_emb —
# фіксовані позиційні ембединги (не навчаються в цій версії), cfg — просто
# конфіг, не масив ваг.

mutable struct TinyTransformer
    tok_emb::Flux.Embedding
    pos_emb::AbstractMatrix{Float32}  # AbstractMatrix, не конкретний Matrix — та сама причина, що й у causal_mask вище
    blocks::Vector{TransformerBlock}
    ln_f::LayerNorm
    head::Dense
    cfg::LMConfig
end

function TinyTransformer(cfg::LMConfig)
    TinyTransformer(
        Flux.Embedding(LM_VOCAB_SIZE => cfg.d_model),
        Float32.(randn(cfg.d_model, cfg.block_size) .* 0.02f0),
        [TransformerBlock(cfg.d_model, cfg.n_head, cfg.d_ff, cfg.block_size) for _ in 1:cfg.n_layer],
        LayerNorm(cfg.d_model),
        Dense(cfg.d_model, LM_VOCAB_SIZE),
        cfg,
    )
end
Flux.@layer TinyTransformer trainable=(tok_emb, blocks, ln_f, head)

# ids: (T, B) Int-матриця (1-based) → logits (vocab, T, B)
function (m::TinyTransformer)(ids::AbstractMatrix{<:Integer})
    T, B = size(ids)
    x = m.tok_emb(ids)                                      # (d_model, T, B)
    x = x .+ reshape(m.pos_emb[:, 1:T], size(x, 1), T, 1)    # + позиційні
    for blk in m.blocks
        x = blk(x)
    end
    x = m.ln_f(x)
    _dense3d(m.head, x)                                      # (vocab, T, B)
end

# --- InnerLM: обгортка з оптимізатором, персистентністю, метаданими --------

mutable struct LMMetadata
    created_at::String
    total_flashes_trained::Int
    total_bytes_trained::Int
    last_loss::Float64
end
LMMetadata() = LMMetadata(now_str(), 0, 0, 0.0)   # now_str() визначено в anima_core.jl

mutable struct InnerLM
    model::TinyTransformer
    opt_state::Any
    cfg::LMConfig
    meta::LMMetadata
    dir::String
end

_lm_paths(dir::String) = (
    weights = joinpath(dir, "weights.bson"),
    config  = joinpath(dir, "config.json"),
    meta    = joinpath(dir, "metadata.json"),
)

function _lm_param_count(model::TinyTransformer)::Int
    p, _ = Flux.destructure(model)
    length(p)
end

# Правда про пристрій — не здогадка з прапорця (_LM_HAS_CUDA уже раз
# збрехав: CUDA.functional()=true, а gpu() під капотом MLDataDevices все
# одно тихо повернув CPU-масив). Дивимось на РЕАЛЬНИЙ тип масиву ваг.
_lm_device_str(model::TinyTransformer) =
    occursin("CuArray", string(typeof(model.tok_emb.weight))) ? "GPU (CuArray)" : "CPU (Array)"

function InnerLM(dir::String; cfg::LMConfig=LMConfig())
    isdir(dir) || mkpath(dir)
    paths = _lm_paths(dir)

    if isfile(paths.weights) && isfile(paths.config)
        try
            loaded_cfg = lmconfig_from_dict(JSON3.read(read(paths.config, String)))
            model = TinyTransformer(loaded_cfg)
            state = BSON.load(paths.weights)[:model_state]
            Flux.loadmodel!(model, state)   # завантажуємо на CPU-моделі (BSON завжди зберігає CPU-стан), переносимо на пристрій нижче
            model = _to_device(model)
            meta = if isfile(paths.meta)
                d = JSON3.read(read(paths.meta, String))
                LMMetadata(
                    String(get(d, "created_at", now_str())),
                    Int(get(d, "total_flashes_trained", 0)),
                    Int(get(d, "total_bytes_trained", 0)),
                    Float64(get(d, "last_loss", 0.0)),
                )
            else
                LMMetadata()
            end
            opt_state = Flux.setup(Flux.Adam(3.0f-4), model)
            println("  [LM] Внутрішня модель завантажена. Флешів натреновано: $(meta.total_flashes_trained), останній loss: $(round(meta.last_loss, digits=3)). Пристрій: $(_lm_device_str(model)).")
            return InnerLM(model, opt_state, loaded_cfg, meta, dir)
        catch e
            @warn "[LM] Не вдалось завантажити наявну модель, ініціалізується нова" exception=(e, catch_backtrace())
        end
    end

    model = TinyTransformer(cfg)
    n_params = _lm_param_count(model)   # рахуємо ДО переносу на пристрій — destructure на CPU-моделі найпростіше
    model = _to_device(model)
    opt_state = Flux.setup(Flux.Adam(3.0f-4), model)
    println("  [LM] Нова внутрішня мовна модель. Параметрів: $(n_params). Пристрій: $(_lm_device_str(model)).")
    InnerLM(model, opt_state, cfg, LMMetadata(), dir)
end

function lm_save!(lm::InnerLM)
    paths = _lm_paths(lm.dir)
    isdir(lm.dir) || mkpath(lm.dir)

    state = Flux.state(cpu(lm.model))   # BSON не серіалізує CuArray надійно — завжди пишемо CPU-стан, незалежно від того, де тренувались
    tmp = paths.weights * ".tmp"
    BSON.bson(tmp, Dict(:model_state => state))
    mv(tmp, paths.weights; force=true)

    open(paths.config, "w") do f
        JSON3.write(f, lmconfig_to_dict(lm.cfg))
    end
    open(paths.meta, "w") do f
        JSON3.write(f, Dict(
            "created_at" => lm.meta.created_at,
            "total_flashes_trained" => lm.meta.total_flashes_trained,
            "total_bytes_trained" => lm.meta.total_bytes_trained,
            "last_loss" => lm.meta.last_loss,
        ))
    end
    nothing
end

# --- Тренувальний крок -------------------------------------------------------
# Текст цього флешу: "user: <...>\nanima: <...>". Next-byte prediction,
# teacher forcing, один gradient-крок за виклик. Якщо задовге — беремо
# хвіст довжиною block_size (найновіше важливіше за найстаріше в межах
# одного флеш-прикладу).

function build_flash_text(user_message::AbstractString, llm_reply::AbstractString)::String
    um = strip(String(user_message))
    ar = strip(String(llm_reply))
    isempty(um) ? "anima: " * ar : "user: " * um * "\nanima: " * ar
end

function lm_learn!(lm::InnerLM, text::AbstractString)::Union{Float64,Nothing}
    isempty(strip(text)) && return nothing
    ids_full = encode_bytes(text)
    length(ids_full) < 2 && return nothing

    bs = lm.cfg.block_size
    if length(ids_full) > bs + 1
        ids_full = ids_full[(end - bs):end]
    end

    input_ids  = _to_device(reshape(ids_full[1:end-1], :, 1))   # (T, 1)
    target_ids = _to_device(ids_full[2:end])                     # (T,)

    result = Flux.withgradient(lm.model) do m
        logits = m(input_ids)                         # (vocab, T, 1)
        logits2d = dropdims(logits; dims=3)            # (vocab, T)
        target_oh = Flux.onehotbatch(target_ids, 1:LM_VOCAB_SIZE)
        logitcrossentropy(logits2d, target_oh)
    end
    Flux.update!(lm.opt_state, lm.model, result.grad[1])

    lm.meta.total_flashes_trained += 1
    lm.meta.total_bytes_trained += length(ids_full)
    lm.meta.last_loss = Float64(result.val)
    Float64(result.val)
end

# --- Генерація ( заготовка на майбутнє, -----
# коли частина рішень почне делегуватись цій моделі, як описано в
# дизайн-документі) -----------------------------------------------------

function _sample_from_probs(probs::AbstractVector{<:Real})::Int
    r = rand()
    c = 0.0
    for (i, p) in enumerate(probs)
        c += p
        r <= c && return i
    end
    length(probs)
end

function lm_generate(lm::InnerLM, prompt::AbstractString; max_new_bytes::Int=100, temperature::Float64=0.8)::String
    ids = encode_bytes(prompt)
    bs = lm.cfg.block_size
    for _ in 1:max_new_bytes
        ctx = length(ids) > bs ? ids[(end - bs + 1):end] : ids
        input_ids = _to_device(reshape(ctx, :, 1))
        logits = lm.model(input_ids)
        last_logits = Array(logits[:, end, 1]) ./ Float32(temperature)   # назад на CPU: _sample_from_probs скалярно індексує, на GPU це заборонено
        probs = Flux.softmax(last_logits)
        push!(ids, _sample_from_probs(probs))
    end
    decode_bytes(ids)
end
