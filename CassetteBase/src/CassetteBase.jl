module CassetteBase

export SourceType, cassette_transform!, generate_internalerr_ex, generate_lambda_ex

using Core.IR
using Core: SimpleVector

const SourceType = @static VERSION ≥ v"1.12.0-DEV.1968" ? Method : LineNumberNode

function cassette_transform!(src::CodeInfo, mi::MethodInstance, nargs::Int,
                             selfname::Symbol, fargsname::Symbol)
    method = mi.def::Method
    mnargs = Int(method.nargs)

    src.slotnames = Symbol[selfname, fargsname, src.slotnames[mnargs+1:end]...]
    src.slotflags = UInt8[ 0x00,     0x00,      src.slotflags[mnargs+1:end]...]

    code = src.code
    fargsslot = SlotNumber(2)
    precode = Any[]
    local ssaid = 0
    for i = 1:mnargs
        if method.isva && i == mnargs
            tuplecall = Expr(:call, GlobalRef(Core, :tuple))
            for j = i:nargs
                push!(precode, Expr(:call, GlobalRef(Core, :getfield), fargsslot, j))
                ssaid += 1
                push!(tuplecall.args, SSAValue(ssaid))
            end
            push!(precode, tuplecall)
        else
            push!(precode, Expr(:call, GlobalRef(Core, :getfield), fargsslot, i))
        end
        ssaid += 1
    end
    prepend!(code, precode)
    @static if VERSION < v"1.12.0-DEV.173"
        prepend!(src.codelocs, [0 for i = 1:ssaid])
    else
        di = Core.Compiler.DebugInfoStream(mi, src.debuginfo, length(code))
        src.debuginfo = Core.DebugInfo(di, length(code))
    end
    prepend!(src.ssaflags, [0x00 for i = 1:ssaid])
    src.ssavaluetypes += ssaid
    if @static isdefined(Base, :__has_internal_change) && Base.__has_internal_change(v"1.12-alpha", :codeinfonargs)
        src.nargs = 2
        src.isva = true
    end

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
        code[i] = transform_stmt(code[i], map_slot_number, map_ssa_value, mi.def.sig, mi.sparam_vals)
    end

    src.edges = MethodInstance[mi]
    src.method_for_inference_limit_heuristics = method

    return Core.Compiler.validate_code(mi, src)
end

function transform_stmt(@nospecialize(x), map_slot_number, map_ssa_value, @nospecialize(spsig), sparams::SimpleVector)
    transform(@nospecialize x′) = transform_stmt(x′, map_slot_number, map_ssa_value, spsig, sparams)
    if isa(x, Expr)
        head = x.head
        if head === :call
            arg1 = x.args[1]
            if ((arg1 === Base.cglobal || (arg1 isa GlobalRef && arg1.name === :cglobal)) ||
                (arg1 === Core.tuple || (arg1 isa GlobalRef && arg1.name === :tuple)))
                return Expr(:call, map(transform, x.args)...) # don't cassette this -- we still have non-linearized cglobal
            end
            return Expr(:call, SlotNumber(1), map(transform, x.args)...)
        elseif head === :foreigncall
            arg1 = x.args[1]
            if Meta.isexpr(arg1, :call)
                # first argument of :foreigncall may be a magic tuple call, and it should be preserved
                arg1 = Expr(:call, map(transform, arg1.args)...)
            else
                arg1 = transform(x.args[1])
            end
            arg2 = @ccall jl_instantiate_type_in_env(x.args[2]::Any, spsig::Any, sparams::Ptr{Any})::Any
            arg3 = Core.svec(Any[
                    @ccall jl_instantiate_type_in_env(argt::Any, spsig::Any, sparams::Ptr{Any})::Any
                    for argt in x.args[3]::SimpleVector ]...)
            return Expr(:foreigncall, arg1, arg2, arg3, map(transform, x.args[4:end])...)
        elseif head === :enter
            return Expr(:enter, map_ssa_value(x.args[1]::Int))
        elseif head === :static_parameter
            return sparams[x.args[1]::Int]
        elseif head === :isdefined
            arg1 = x.args[1]
            if Meta.isexpr(arg1, :static_parameter)
                return 1 ≤ arg1.args[1]::Int ≤ length(sparams)
            end
        end
        return Expr(head, map(transform, x.args)...)
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
    elseif @static @isdefined(EnterNode) && isa(x, EnterNode)
        if isdefined(x, :scope)
            return EnterNode(map_ssa_value(x.catch_dest), transform(x.scope))
        else
            return EnterNode(map_ssa_value(x.catch_dest))
        end
    end
    return x
end

struct CassetteInternalError
    err
    bt::Vector
    context::Symbol
    metadata  # allow preserving arbitrary data for debugging
    function CassetteInternalError(err, bt::Vector, context::Symbol, metadata=nothing)
        @nospecialize err metadata
        new(err, bt, context, metadata)
    end
end
function Base.showerror(io::IO, err::CassetteInternalError)
    print(io, "Internal error happened in `$(err.context)`:")
    println(io)
    buf = IOBuffer()
    ioctx = IOContext(buf, IOContext(io))
    Base.showerror(ioctx, err.err)
    Base.show_backtrace(ioctx, err.bt)
    printstyled(io, " ┌", '─'^48, '\n'; color=:red)
    for l in split(String(take!(buf)), '\n')
        printstyled(io, " │ "; color=:red)
        println(io, l)
    end
    printstyled(io, " └", '─'^48; color=:red)
end

function generate_internalerr_ex(err, bt::Vector, context::Symbol,
                                 world::UInt, source::SourceType,
                                 argnames::SimpleVector, spnames::SimpleVector,
                                 metadata=nothing)
    @nospecialize err metadata
    throw_ex = :(throw($CassetteInternalError(
        $(QuoteNode(err)), $bt, $(QuoteNode(context)), $(QuoteNode(metadata)))))
    return generate_lambda_ex(world, source, argnames, spnames, throw_ex)
end

function generate_lambda_ex(world::UInt, source::SourceType,
                            argnames::SimpleVector, spnames::SimpleVector,
                            body::Expr)
    stub = Core.GeneratedFunctionStub(identity, argnames, spnames)
    return stub(world, source, body)
end

end # module CassetteBase
