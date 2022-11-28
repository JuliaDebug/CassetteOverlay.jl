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
    @assert !mi.def.isva "vararg method is unsupported"
    src = copy(Core.Compiler.retrieve_code_info(mi)::CodeInfo)
    src.edges = MethodInstance[mi]
    transform!(src, length(args), match.sparams)
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

function transform!(src::CodeInfo, nargs::Int, sparams::SimpleVector)
    code = src.code
    src.slotnames = Symbol[Symbol("#self#"), :f, :args, src.slotnames[nargs+1:end]...]
    src.slotflags = UInt8[(0x00 for i = 1:3)..., src.slotflags[nargs+1:end]...]
    # Insert one SSAValue for every argument statement
    prepend!(code, [Expr(:call, getfield, SlotNumber(3), i) for i = 1:nargs])
    prepend!(src.codelocs, [0 for i = 1:nargs])
    prepend!(src.ssaflags, [0x00 for i = 1:nargs])
    src.ssavaluetypes += nargs

    function map_slot_number(slot::Int)
        if slot == 1
            # self in the original function is now `f`
            return SlotNumber(2)
        elseif 2 ≤ slot ≤ nargs+1
            # Arguments get inserted as ssa values at the top of the function
            return SSAValue(slot - 1)
        else
            # The first non-argument slot will be 4
            return SlotNumber(slot - (nargs+1) + 3)
        end
    end
    map_ssa_value(ssa::SSAValue) = SSAValue(ssa.id + nargs)
    for i = (nargs+1:length(code))
        code[i] = transform_stmt(code[i], map_slot_number, map_ssa_value, sparams)
    end

    return src
end

function transform_stmt(@nospecialize(x), map_slot_number, map_ssa_value, sparams::SimpleVector)
    transform(@nospecialize x′) = transform_stmt(x′, map_slot_number, map_ssa_value, sparams)

    if isexpr(x, :call)
        return Expr(:call, SlotNumber(1), map(transform, x.args)...)
    elseif isa(x, GotoIfNot)
        return GotoIfNot(transform(x.cond), map_ssa_value(SSAValue(x.dest)).id)
    elseif isexpr(x, :static_parameter)
        return quoted(sparams[x.args[1]])
    elseif isa(x, ReturnNode)
        return ReturnNode(transform(x.val))
    elseif isa(x, Expr)
        return Expr(x.head, map(transform, x.args)...)
    elseif isa(x, GotoNode)
        return GotoNode(map_ssa_value(SSAValue(x.label)).id)
    elseif isa(x, SlotNumber)
        return map_slot_number(x.id)
    elseif isa(x, SSAValue)
        return map_ssa_value(x)
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
