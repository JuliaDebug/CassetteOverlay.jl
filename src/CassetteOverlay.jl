module CassetteOverlay

export @MethodTable, @overlay, OverlayPass, method_table, nonoverlay, @nonoverlay

using Core.IR
using Core: MethodInstance, SimpleVector, MethodTable
using Core.Compiler: specialize_method, retrieve_code_info
using Base: destructure_callex, to_tuple_type, get_world_counter
using Base.Experimental: @MethodTable, @overlay

abstract type OverlayPass end
function method_table end
function nonoverlay end

macro nonoverlay(ex)
    @static if VERSION ≥ v"1.10.0-DEV.68"
        topmod = Core.Compiler._topmod(__module__)
        f, args, kwargs = Base.destructure_callex(topmod, ex)
    else
        f, args, kwargs = Base.destructure_callex(ex)
    end
    out = Expr(:call, GlobalRef(@__MODULE__, :nonoverlay))
    isempty(kwargs) || push!(out.args, Expr(:parameters, kwargs...))
    push!(out.args, f)
    append!(out.args, args)
    return esc(out)
end

function overlay_generator(passtype, fargtypes)
    tt = to_tuple_type(fargtypes)
    mt = Base.invoke_in_world(typemax(UInt), method_table, passtype)
    match = _which(tt; method_table=mt, raise=false)
    match === nothing && return nothing
    mi = specialize_method(match)::MethodInstance
    src = copy(retrieve_code_info(mi)::CodeInfo)
    overlay_transform!(src, mi, length(fargtypes))
    return src
end

# @static if VERSION ≥ v"1.10.0-DEV.65"
#     using Base: _which
# else
    function _which(@nospecialize(tt::Type);
        method_table::Union{Nothing,MethodTable}=nothing,
        world::UInt=get_world_counter(),
        raise::Bool=false)
        if method_table === nothing
            table = Core.Compiler.InternalMethodTable(world)
        else
            table = Core.Compiler.OverlayMethodTable(world, method_table)
        end
        match, = Core.Compiler.findsup(tt, table)
        if match === nothing
            raise && error("no unique matching method found for the specified argument types")
            return nothing
        end
        return match
    end
# end

function overlay_transform!(src::CodeInfo, mi::MethodInstance, nargs::Int)
    method = mi.def::Method
    mnargs = Int(method.nargs)

    src.slotnames = Symbol[Symbol("#self#"), :fargs, src.slotnames[mnargs+1:end]...]
    src.slotflags = UInt8[ 0x00,             0x00,   src.slotflags[mnargs+1:end]...]

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
        elseif head === :foreigncall
            # first argument of :foreigncall is a magic tuple and should be preserved
            return Expr(:foreigncall, x.args[1], map(transform, x.args[2:end])...)
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
    elseif isa(x, NewvarNode)
        return NewvarNode(map_slot_number(x.slot.id))
    elseif isa(x, SSAValue)
        return SSAValue(map_ssa_value(x.id))
    else
        return x
    end
end

@static if !isdefined(Core, :kwcall)
    struct NonoverlayKwcall{F}
        NonoverlayKwcall(@nospecialize f) = new{Core.Typeof(f)}(f)
    end
end

@inline function (::OverlayPass)(f::Union{Core.Builtin,Core.IntrinsicFunction}, args...)
    @nospecialize f args
    return f(args...)
end
@inline function (::OverlayPass)(f::typeof(Core.Compiler.return_type), args...)
    @nospecialize args
    return f(args...)
end

@generated function (pass::OverlayPass)(fargs...)
    src = overlay_generator(pass, fargs)
    if src === nothing
        # a code generation failed – make it raise a proper MethodError
        return :(first(fargs)(Base.tail(fargs)...))
    end
    return src
end

@nospecialize
@inline function (::OverlayPass)(::typeof(nonoverlay), f, args...; kwargs...)
    return f(args...; kwargs...)
end
@specialize

@static if isdefined(Core, :kwcall)
    @inline function (::OverlayPass)(::typeof(Core.kwcall), kwargs::Any, ::typeof(nonoverlay), fargs...)
        @nospecialize kwargs fargs
        return Core.kwcall(kwargs, fargs...)
    end
else
    @inline function (::OverlayPass)(::typeof(Core.kwfunc(nonoverlay)), kwargs::Any, ::typeof(nonoverlay), f, args...)
        @nospecialize kwargs fargs
        kwf = Core.kwfunc(f)
        return kwf(kwargs, f, args...)
    end
end

end # module CassetteOverlay
