module CassetteOverlay

export @MethodTable, @overlay, @OverlayPass, nooverlay

const CC = Core.Compiler

using Core.IR
using Core: MethodInstance, SimpleVector, MethodTable
using Base.Experimental: @MethodTable, @overlay

abstract type OverlayPass end
function method_table end
function nooverlay end
method_table(::Type{<:OverlayPass}) =
    error("CassetteOverlay is available via the @OverlayPass macro")
nooverlay(@nospecialize args...) =
    error("CassetteOverlay is available via the @OverlayPass macro")

function overlay_generator(passtype, fargtypes)
    tt = Base.to_tuple_type(fargtypes)
    match = _which(tt; method_table=method_table(passtype))
    mi = Core.Compiler.specialize_method(match)::MethodInstance
    src = copy(Core.Compiler.retrieve_code_info(mi)::CodeInfo)
    overlay_transform!(src, mi, length(fargtypes))
    return src
end

function _which(@nospecialize(tt::Type);
    method_table::Union{Nothing,MethodTable}=nothing,
    world::UInt=Base.get_world_counter())
    if method_table === nothing
        table = CC.InternalMethodTable(world)
    else
        table = CC.OverlayMethodTable(world, method_table)
    end
    match, = CC.findsup(tt, table)
    if match === nothing
        error("no unique matching method found for the specified argument types")
    end
    return match
end

function overlay_transform!(src::CodeInfo, mi::MethodInstance, nargs::Int)
    method = mi.def::Method
    mnargs = Int(method.nargs)

    src.slotnames = Symbol[Symbol("#self#"), :fargs, src.slotnames[mnargs+1:end]...]
    src.slotflags = UInt8[(0x00 for i = 1:3)..., src.slotflags[mnargs+1:end]...]

    code = src.code
    fargsslot = SlotNumber(2)
    precode = Any[]
    local ssaid = 0
    for i = 1:mnargs
        if method.isva && i == mnargs
            args = map(i:nargs) do j
                push!(precode, Expr(:call, getfield, fargsslot, j))
                ssaid += 1
                return SSAValue(ssaid)
            end
            push!(precode, Expr(:call, tuple, args...))
        else
            push!(precode, Expr(:call, getfield, fargsslot, i))
        end
        ssaid += 1
    end
    prepend!(code, precode)
    prepend!(src.codelocs, [0 for i = 1:ssaid])
    prepend!(src.ssaflags, [0x00 for i = 1:ssaid])
    src.ssavaluetypes += ssaid

    function map_slot_number(slot::Int)
        @assert slot ≥ 1
        if 1 ≤ slot ≤ mnargs
            if method.isva && slot == mnargs
                return SSAValue(ssaid)
            else
                return SSAValue(slot)
            end
        else
            return SlotNumber(slot - mnargs + 2)
        end
    end
    map_ssa_value(id::Int) = id + ssaid
    for i = (ssaid+1:length(code))
        code[i] = transform_stmt(code[i], map_slot_number, map_ssa_value, mi.sparam_vals)
    end

    src.edges = MethodInstance[mi]
    src.method_for_inference_limit_heuristics = method

    return src
end

function transform_stmt(@nospecialize(x), map_slot_number, map_ssa_value, sparams::SimpleVector)
    transform(@nospecialize x′) = transform_stmt(x′, map_slot_number, map_ssa_value, sparams)

    if isa(x, Expr)
        head = x.head
        if head === :call
            return Expr(:call, SlotNumber(1), map(transform, x.args)...)
        elseif head === :enter
            return Expr(:enter, map_ssa_value(x.args[1]::Int))
        elseif head === :static_parameter
            return sparams[x.args[1]::Int]
        end
        return Expr(x.head, map(transform, x.args)...)
    elseif isa(x, GotoNode)
        return GotoNode(map_ssa_value(x.label))
    elseif isa(x, GotoIfNot)
        return GotoIfNot(transform(x.cond), map_ssa_value(x.dest))
    elseif isa(x, ReturnNode)
        return ReturnNode(transform(x.val))
    elseif isa(x, SlotNumber)
        return map_slot_number(x.id)
    elseif isa(x, SSAValue)
        return SSAValue(map_ssa_value(x.id))
    else
        return x
    end
end

macro OverlayPass(method_table::Symbol)
    PassName = esc(gensym(method_table))

    passdef = :(struct $PassName <: $OverlayPass end)

    mtdef = :($CassetteOverlay.method_table(::Type{$PassName}) = $(esc(method_table)))

    builtinpass = :(@inline function (::$PassName)(f::Union{Core.Builtin,Core.IntrinsicFunction}, args...)
        @nospecialize f args
        return f(args...)
    end)

    overlaypass = :(@generated function (pass::$PassName)(fargs...)
        return $overlay_generator(pass, fargs)
    end)

    nooverlaytype = typeof(CassetteOverlay.nooverlay)
    nooverlaydef = :(@inline function (pass::$PassName)(::$nooverlaytype, f, args...)
        @nospecialize f args
        return f(args...)
    end)

    returnpass = :(return $PassName())

    return Expr(:toplevel, passdef, mtdef, builtinpass, overlaypass, nooverlaydef, returnpass)
end

end # module CassetteOverlay
