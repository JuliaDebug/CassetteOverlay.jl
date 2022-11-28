module CassetteOverlay

export @MethodTable, @overlay, @OverlayPass

const CC = Core.Compiler

using Core.IR
import Core: MethodInstance, SimpleVector, MethodTable
import Core.Compiler: quoted
import Base.Meta: isexpr
import Base.Experimental: @MethodTable, @overlay

abstract type OverlayPass end
method_table(::Type{<:OverlayPass}) = error("CassetteOverlay is available via the @OverlayPass macro")

function overlay_generator(pass, f, args)
    tt = signature_type′(f, args)
    match = _which(tt; method_table=method_table(pass))

    mi = Core.Compiler.specialize_method(match)::MethodInstance

    src = copy(Core.Compiler.retrieve_code_info(mi)::CodeInfo)
    overlay_transform!(src, mi, length(args))
    return src
end

function signature_type′(@nospecialize(ft), @nospecialize(argtypes))
    argtypes = Base.to_tuple_type(argtypes)
    u = Base.unwrap_unionall(argtypes)::DataType
    return Base.rewrap_unionall(Tuple{ft, u.parameters...}, argtypes)
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

    src.slotnames = Symbol[Symbol("#self#"), :f, :args, src.slotnames[mnargs+1:end]...]
    src.slotflags = UInt8[(0x00 for i = 1:3)..., src.slotflags[mnargs+1:end]...]

    code = src.code
    precode = Any[]
    local ssaid = 0
    for i = 1:(mnargs-1)
        if method.isva && i == (mnargs-1)
            args = map(i:nargs) do j
                push!(precode, Expr(:call, getfield, SlotNumber(3), j))
                ssaid += 1
                return SSAValue(ssaid)
            end
            push!(precode, Expr(:call, tuple, args...))
        else
            push!(precode, Expr(:call, getfield, SlotNumber(3), i))
        end
        ssaid += 1
    end
    prepend!(code, precode)
    prepend!(src.codelocs, [0 for i = 1:ssaid])
    prepend!(src.ssaflags, [0x00 for i = 1:ssaid])
    src.ssavaluetypes += ssaid

    function map_slot_number(slot::Int)
        if slot == 1
            # self in the original function is now `f`
            return SlotNumber(2)
        elseif 2 ≤ slot ≤ mnargs
            if method.isva && slot == mnargs
                return SSAValue(ssaid)
            else
                # Arguments get inserted as ssa values at the top of the function
                return SSAValue(slot-1)
            end
        else
            # The first non-argument slot will be 4
            return SlotNumber(slot - mnargs + 3)
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

    mtf = (@__MODULE__).method_table
    mtdef = :($CassetteOverlay.method_table(::Type{$PassName}) = $(esc(method_table)))

    builtinpass = :(@inline function (::$PassName)(f::Union{Core.Builtin,Core.IntrinsicFunction}, args...)
        return f(args...)
    end)

    overlaypass = :(@generated function (pass::$PassName)(f, args...)
        src = $overlay_generator(pass, f, args)
        return src
    end)

    returnpass = :(return $PassName())

    return Expr(:toplevel, passdef, mtdef, builtinpass, overlaypass, returnpass)
end

end # module CassetteOverlay
